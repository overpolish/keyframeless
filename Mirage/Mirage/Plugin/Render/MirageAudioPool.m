/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageAudioPool.h"

#import <KeyframelessKit/KKSonarTicket.h>
#import <KeyframelessKit/KKSpectrogram.h>
#import <os/lock.h>
#import <os/log.h>
#import <sys/stat.h>

#import "MirageDirectives.h"

/// Open spectrograms, keyed by source id.
///
/// A static cache is right here and NOT the usual XPC mistake: every plugin
/// instance is its own process, so this shares nothing between instances - it
/// just stops the render path reopening and re-mmapping a file every frame.
/// Locked because FCP renders on several threads.
#define KK_SHADER_AUDIO_CACHE 2
typedef struct {
  char sourceID[128];
  KKSpectrogramRef spectrogram;
  /// Identity of the FILE that was mapped. Publishing writes atomically, which
  /// swaps in a NEW inode - the old mapping stays valid and stays stale, so a
  /// re-publish would never reach a plugin that had already opened the source.
  ino_t inode;
  time_t mtime;
  off_t size;
} MirageAudioCacheEntry;

static MirageAudioCacheEntry gAudioCache[KK_SHADER_AUDIO_CACHE];
static os_unfair_lock gAudioCacheLock = OS_UNFAIR_LOCK_INIT;

/// The open spectrogram for `sourceID`, opening it on first use. Returns NULL
/// if the file is gone (deleted in Sonar since the shader was bound).
static KKSpectrogramRef MirageAudioSpectrogramFor(NSString *sourceID) {
  if (sourceID.length == 0 || sourceID.length >= 128) {
    return NULL;
  }
  NSURL *url = KKSpectrogramURLForSourceID(sourceID);
  if (!url) {
    return NULL;
  }
  // Cheap (a metadata read, no I/O) and the only way to notice a re-publish:
  // matching the id alone would hand back a mapping of the file that USED to be
  // there.
  struct stat st;
  if (stat(url.fileSystemRepresentation, &st) != 0) {
    return NULL; // deleted in Sonar since the shader was bound
  }

  const char *want = sourceID.UTF8String;
  os_unfair_lock_lock(&gAudioCacheLock);
  for (int i = 0; i < KK_SHADER_AUDIO_CACHE; i++) {
    if (gAudioCache[i].spectrogram &&
        strcmp(gAudioCache[i].sourceID, want) == 0 &&
        gAudioCache[i].inode == st.st_ino &&
        gAudioCache[i].mtime == st.st_mtime &&
        gAudioCache[i].size == st.st_size) {
      KKSpectrogramRef hit = gAudioCache[i].spectrogram;
      os_unfair_lock_unlock(&gAudioCacheLock);
      return hit;
    }
  }
  os_unfair_lock_unlock(&gAudioCacheLock);

  // Opened outside the lock: mmap can block, and holding a render-path lock
  // across it would stall every other thread.
  KKSpectrogramRef opened = KKSpectrogramOpen(url);
  if (!opened) {
    return NULL;
  }

  os_unfair_lock_lock(&gAudioCacheLock);
  int slot = -1;
  for (int i = 0; i < KK_SHADER_AUDIO_CACHE; i++) {
    if (!gAudioCache[i].spectrogram) {
      slot = i;
      break;
    }
    // Same source, older file: this entry is the stale one to replace.
    if (strcmp(gAudioCache[i].sourceID, want) == 0) {
      slot = i;
      break;
    }
  }
  if (slot < 0) {
    slot = 0; // full and nothing matches - evict the oldest
  }
  // The outgoing mapping is deliberately NOT closed: another thread may be
  // mid-sample on it, and there's no refcount to know. It's bounded by how many
  // times one session re-publishes a bound source, and the pages are
  // file-backed (reclaimable), so the cost is address space rather than memory.
  strncpy(gAudioCache[slot].sourceID, want,
          sizeof(gAudioCache[slot].sourceID) - 1);
  gAudioCache[slot].spectrogram = opened;
  gAudioCache[slot].inode = st.st_ino;
  gAudioCache[slot].mtime = st.st_mtime;
  gAudioCache[slot].size = st.st_size;
  os_unfair_lock_unlock(&gAudioCacheLock);
  return opened;
}

/// The published source whose stable key is `key`, or nil.
///
/// Resolves by identity, not position: the lane stores the key (0 = None), and
/// a key matching nothing means the source is gone - deleted here, or never
/// published on this Mac. Silence either way, rather than whatever now sits
/// where it used to.
static NSString *
MirageAudioSourceIDForKey(long key,
                          NSArray<NSDictionary<NSString *, id> *> *published) {
  NSDictionary<NSString *, id> *source =
      KKSonarSourceForKey((double)key, published);
  NSString *sourceID = source[@"id"];
  return [sourceID isKindOfClass:NSString.class] && sourceID.length ? sourceID
                                                                    : nil;
}

/// Samples `have` bands at `timelineSeconds`, averaged over a `smoothSeconds`
/// window centred on it. NO if the time lies outside the analysis.
///
/// Raw 60Hz bands are violently transient, so a shader mapping them straight to
/// geometry judders; the window calms it without the shader having to.
///
/// A window rather than a running filter because renders are random-access -
/// scrubbing, motion-blur sub-frames, out-of-order pre-render. A stateful
/// filter would answer differently depending on how you reached a frame, so the
/// same frame would look different scrubbed than played.
static BOOL MirageAudioSampleSmoothed(KKSpectrogramRef spectrogram,
                                      double timelineSeconds,
                                      double smoothSeconds, float *bands,
                                      uint32_t have) {
  double hop = KKSpectrogramHopSeconds(spectrogram);
  int taps = 1;
  if (smoothSeconds > 0 && hop > 0) {
    taps = (int)lround(smoothSeconds / hop);
    taps = taps < 1 ? 1 : (taps > 15 ? 15 : taps);
  }
  if (taps <= 1) {
    return KKSpectrogramSampleAtTime(spectrogram, timelineSeconds, bands, have);
  }
  float acc[256] = {0};
  float tap[256];
  int hits = 0;
  for (int k = 0; k < taps; k++) {
    // Centred on `timelineSeconds`, so the value tracks the audio rather than
    // lagging it the way a trailing window would.
    double offset = ((double)k / (double)(taps - 1) - 0.5) * smoothSeconds;
    if (!KKSpectrogramSampleAtTime(spectrogram, timelineSeconds + offset, tap,
                                   have)) {
      continue; // past an edge - just don't count it
    }
    for (uint32_t b = 0; b < have; b++) {
      acc[b] += tap[b];
    }
    hits++;
  }
  if (hits == 0) {
    return NO; // wholly outside the published range - silence
  }
  for (uint32_t b = 0; b < have; b++) {
    bands[b] = acc[b] / (float)hits;
  }
  return YES;
}

/// Applies the gate to `bands` in place: a band under `gateDB` falls to zero
/// over `releaseSeconds`, and snaps back the moment signal returns.
///
/// Per band, so each bar dies and revives on its own. Without the release this
/// is a switch, and a bar at full height one frame and gone the next reads as a
/// glitch rather than as a sound stopping.
///
/// Computed by looking BACKWARD for when a band last cleared the gate, rather
/// than by decaying a remembered value. FCP renders frames out of order (scrub,
/// motion blur, pre-render), so a remembered envelope would make a frame depend
/// on how you reached it and wouldn't survive an export. A lookback answers
/// identically however the frame is reached.
static void MirageAudioApplyGate(KKSpectrogramRef spectrogram,
                                 double timelineSeconds, double gateDB,
                                 double releaseSeconds, float *bands,
                                 uint32_t have) {
  double hop = KKSpectrogramHopSeconds(spectrogram);
  // At or below the analysis floor the gate normalises to 0, and no band is
  // quieter than that - so the bottom of the lane's range IS "off", and says so
  // by doing nothing rather than by being a special case.
  float gate = isnan(gateDB)
                   ? 0.0f
                   : (float)KKSpectrogramNormalizedForDB(spectrogram, gateDB);
  if (gate <= 0.0f || hop <= 0) {
    return;
  }
  double rel = releaseSeconds < 0 ? 0 : releaseSeconds;
  if (rel > kMirageAudioReleaseMaxSec) {
    rel = kMirageAudioReleaseMaxSec;
  }
  // How many hops back the envelope can still be above zero. rel = 0 leaves
  // only the current frame, which IS a hard gate - one code path.
  int maxK = (int)ceil(rel / hop);
  int cap = (int)ceil(kMirageAudioReleaseMaxSec / hop);
  if (maxK > cap) {
    maxK = cap;
  }

  // Hops since each band last cleared the gate; -1 = not within the window.
  int16_t sinceK[256];
  for (uint32_t b = 0; b < have; b++) {
    sinceK[b] = -1;
  }
  uint32_t unresolved = have;
  float row[256];
  for (int k = 0; k <= maxK && unresolved > 0; k++) {
    // Raw rows, not smoothed ones: re-smoothing every step back would cost the
    // window again per hop, and the threshold crossing is a property of the
    // audio rather than of the display smoothing.
    if (!KKSpectrogramSampleAtTime(spectrogram, timelineSeconds - k * hop, row,
                                   have)) {
      break; // past the start of the analysis - nothing earlier to find
    }
    for (uint32_t b = 0; b < have; b++) {
      if (sinceK[b] < 0 && row[b] >= gate) {
        sinceK[b] = (int16_t)k;
        unresolved--;
      }
    }
  }

  for (uint32_t b = 0; b < have; b++) {
    if (sinceK[b] == 0) {
      continue; // open right now: full level, instant attack
    }
    if (sinceK[b] < 0) {
      bands[b] = 0.0f; // silent for longer than the release
      continue;
    }
    float env = 1.0f - (float)(sinceK[b] * hop / rel);
    bands[b] *= env < 0 ? 0 : env;
  }
}

/// Folds `have` analysis bands down to the shader's `p->bands`, packed 4 per
/// vec4. Takes the MAX of each group so a transient survives being squeezed
/// into fewer bands - the same reason Sonar's own picture buckets by max.
static void MirageAudioFoldToPool(const float *bands, uint32_t have,
                                  const MirageAudioProp *p,
                                  vector_float4 *pool) {
  int want = p->bands;
  for (int b = 0; b < want; b++) {
    int lo = (int)((int64_t)have * b / want);
    int hi = (int)((int64_t)have * (b + 1) / want);
    if (hi <= lo) {
      hi = lo + 1;
    }
    float peak = 0;
    for (int k = lo; k < hi && k < (int)have; k++) {
      if (bands[k] > peak) {
        peak = bands[k];
      }
    }
    pool[p->poolOffset + (b >> 2)][b & 3] = peak;
  }
}

/// The lane value for `label`, or `fallback` when the lane is absent. The
/// directive's attributes only seeded these lanes' defaults, so by render time
/// the lane is the authority.
static double
MirageAudioLaneValue(NSArray<NSNumber *> * (^valuesForLabel)(NSString *),
                     NSString *label, double fallback) {
  NSArray<NSNumber *> *v = valuesForLabel(label);
  return v.count ? v[0].doubleValue : fallback;
}

int MirageFillAudioPool(
    NSString *source, vector_float4 *pool, int startOffset,
    double timelineSeconds,
    NSArray<NSNumber *> * (^valuesForLabel)(NSString *label)) {
  MirageAudioProp props[KK_SHADER_MAX_AUDIO_PROPS];
  int used = 0;
  int nProps = MirageParseAudioProps(source, props, KK_SHADER_MAX_AUDIO_PROPS,
                                     startOffset, &used);
  if (nProps == 0) {
    return startOffset;
  }
  NSArray<NSDictionary<NSString *, id> *> *published =
      KKSpectrogramPublishedSources();

  for (int pi = 0; pi < nProps; pi++) {
    MirageAudioProp *p = &props[pi];
    // Zero first: every path below that can't produce audio leaves silence
    // rather than whatever the last frame left in the pool.
    for (int v = 0; v < p->vecCount; v++) {
      pool[p->poolOffset + v] = (vector_float4){0, 0, 0, 0};
    }

    NSString *uniform = @(p->name);
    long key = lround(MirageAudioLaneValue(valuesForLabel, uniform, 0));
    NSString *sourceID = MirageAudioSourceIDForKey(key, published);
    if (!sourceID) {
      continue; // nothing bound, or the bound source is gone
    }
    KKSpectrogramRef spectrogram = MirageAudioSpectrogramFor(sourceID);
    if (!spectrogram) {
      continue;
    }

    uint32_t have = KKSpectrogramNumBands(spectrogram);
    if (have > 256) {
      have = 256;
    }
    float bands[256];
    if (!MirageAudioSampleSmoothed(
            spectrogram, timelineSeconds,
            MirageAudioLaneValue(valuesForLabel,
                                 MirageAudioSmoothLaneLabel(uniform),
                                 p->smoothSeconds),
            bands, have)) {
      continue; // outside the published range - silence
    }
    MirageAudioApplyGate(
        spectrogram, timelineSeconds,
        MirageAudioLaneValue(valuesForLabel, MirageAudioGateLaneLabel(uniform),
                             p->gateDB),
        MirageAudioLaneValue(valuesForLabel,
                             MirageAudioReleaseLaneLabel(uniform),
                             p->releaseSeconds),
        bands, have);
    MirageAudioFoldToPool(bands, have, p, pool);
  }
  return startOffset + used;
}
