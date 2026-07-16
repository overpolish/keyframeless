/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderAudioPool.h"

#import <KeyframelessKit/KKSpectrogram.h>
#import <os/lock.h>
#import <os/log.h>
#import <sys/stat.h>

#import "ShaderDirectives.h"

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
} ShaderAudioCacheEntry;

static ShaderAudioCacheEntry gAudioCache[KK_SHADER_AUDIO_CACHE];
static os_unfair_lock gAudioCacheLock = OS_UNFAIR_LOCK_INIT;

/// The open spectrogram for `sourceID`, opening it on first use. Returns NULL
/// if the file is gone (deleted in Sonar since the shader was bound).
static KKSpectrogramRef ShaderAudioSpectrogramFor(NSString *sourceID) {
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

int ShaderFillAudioPool(
    NSString *source, vector_float4 *pool, int startOffset,
    double timelineSeconds,
    NSArray<NSNumber *> * (^valuesForLabel)(NSString *label)) {
  ShaderAudioProp props[KK_SHADER_MAX_AUDIO_PROPS];
  int used = 0;
  int nProps = ShaderParseAudioProps(source, props, KK_SHADER_MAX_AUDIO_PROPS,
                                     startOffset, &used);
  if (nProps == 0) {
    return startOffset;
  }
  NSArray<NSDictionary<NSString *, id> *> *published =
      KKSpectrogramPublishedSources();

  for (int pi = 0; pi < nProps; pi++) {
    ShaderAudioProp *p = &props[pi];
    // Zero first: every path below that can't produce audio leaves silence
    // rather than whatever the last frame left in the pool.
    for (int v = 0; v < p->vecCount; v++) {
      pool[p->poolOffset + v] = (vector_float4){0, 0, 0, 0};
    }

    // The lane stores the source's stable key (0 = None), not its position, so
    // this resolves by identity. A key that matches nothing means the source
    // was deleted since the shader was bound - silence, rather than whatever
    // now sits where it used to.
    NSArray<NSNumber *> *v = valuesForLabel(@(p->name));
    long key = v.count ? lround(v[0].doubleValue) : 0;
    if (key == 0) {
      continue;
    }
    NSString *sourceID = nil;
    for (NSDictionary *entry in published) {
      NSString *hash = entry[@"contentHash"];
      if (![hash isKindOfClass:NSString.class] || !hash.length) {
        hash = entry[@"id"];
      }
      if (![hash isKindOfClass:NSString.class] || !hash.length) {
        continue;
      }
      if (lround(ShaderAudioSourceKey(hash)) == key) {
        sourceID = entry[@"id"];
        break;
      }
    }
    if (![sourceID isKindOfClass:NSString.class] || !sourceID.length) {
      continue;
    }
    KKSpectrogramRef spectrogram = ShaderAudioSpectrogramFor(sourceID);
    if (!spectrogram) {
      continue;
    }
    float bands[256];
    uint32_t have = KKSpectrogramNumBands(spectrogram);
    if (have > 256) {
      have = 256;
    }

    // Averaged over `smooth=` seconds centred on now. Raw 60Hz bands are
    // violently transient, so a shader mapping them straight to geometry
    // judders; a window calms it without the shader having to.
    //
    // A window rather than a running filter because renders are random-access -
    // scrubbing, motion-blur sub-frames, out-of-order pre-render. A stateful
    // filter would answer differently depending on how you reached a frame, so
    // the same frame would look different scrubbed than played.
    double hop = KKSpectrogramHopSeconds(spectrogram);
    int taps = 1;
    if (p->smoothSeconds > 0 && hop > 0) {
      taps = (int)lround(p->smoothSeconds / hop);
      taps = taps < 1 ? 1 : (taps > 15 ? 15 : taps);
    }
    if (taps <= 1) {
      if (!KKSpectrogramSampleAtTime(spectrogram, timelineSeconds, bands,
                                     have)) {
        continue; // outside the published range - silence
      }
    } else {
      float acc[256] = {0};
      float tap[256];
      int hits = 0;
      for (int k = 0; k < taps; k++) {
        // Centred on `timelineSeconds`, so the value tracks the audio rather
        // than lagging it the way a trailing window would.
        double offset =
            ((double)k / (double)(taps - 1) - 0.5) * p->smoothSeconds;
        if (!KKSpectrogramSampleAtTime(spectrogram, timelineSeconds + offset,
                                       tap, have)) {
          continue; // past an edge - just don't count it
        }
        for (uint32_t b = 0; b < have; b++) {
          acc[b] += tap[b];
        }
        hits++;
      }
      if (hits == 0) {
        continue; // wholly outside the published range - silence
      }
      for (uint32_t b = 0; b < have; b++) {
        bands[b] = acc[b] / (float)hits;
      }
    }

    // Fold the analysis bands down to the shader's, taking the MAX of each
    // group so a transient survives being squeezed into fewer bands (the same
    // reason Sonar's own picture buckets by max).
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
  return startOffset + used;
}
