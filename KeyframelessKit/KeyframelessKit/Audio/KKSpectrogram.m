/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSpectrogram.h"

#import <os/lock.h>
#import <sys/mman.h>
#import <sys/stat.h>

#import "KKLog.h"

const uint32_t KKSpectrogramFormatVersion = 2;

static NSString *const kKKSpectrogramAppGroupID = @"group.com.keyframeless";
// v1: magic, version, numFrames, numBands, hopSeconds, timelineStart.
// v2 appends the dB window. The grid starts after whichever header the file
// declares, so the two sizes are what locate it - not one constant.
static const size_t kKKSpectrogramHeaderSizeV1 = 4 + 4 + 4 + 4 + 8 + 8;
// v2 appends the dB window and a continuous waveform's sample metadata.
static const size_t kKKSpectrogramHeaderSizeV2 =
    kKKSpectrogramHeaderSizeV1 + 8 + 8 + 8 + 8;

// What v1 was always written with, so a file from before the window was stored
// reads back as the loudness it actually encoded.
static const double kKKSpectrogramLegacyFloorDB = -85.0;
static const double kKKSpectrogramLegacyCeilingDB = -15.0;

struct KKSpectrogram {
  void *map;
  size_t mapSize;
  const float *data;
  const float *waveform;
  uint32_t numFrames;
  uint32_t numBands;
  uint64_t numWaveformSamples;
  double hopSeconds;
  double timelineStart;
  double floorDB;
  double ceilingDB;
  double waveformSampleRate;
};

static uint32_t KKReadU32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static uint64_t KKReadU64(const uint8_t *p) {
  uint64_t value = 0;
  for (int i = 0; i < 8; i++) {
    value |= ((uint64_t)p[i]) << (8 * i);
  }
  return value;
}

/// Appends `v` little-endian, to match `KKReadF64`.
///
/// NOT `CFConvertDoubleHostToSwapped`: that produces CoreFoundation's canonical
/// BIG-endian form, so pairing it with `CFSwapInt32HostToLittle` (as the first
/// version here did) writes a mixed-endian file. The reader then read hop as a
/// denormal ~1e-226 - positive, so it passed the `<= 0` guard - which made
/// every time but zero fall outside the spectrogram.
static void KKAppendF64LE(NSMutableData *out, double v) {
  uint64_t bits;
  memcpy(&bits, &v, sizeof(bits));
  bits = CFSwapInt64HostToLittle(bits);
  [out appendBytes:&bits length:sizeof(bits)];
}

static double KKReadF64(const uint8_t *p) {
  uint64_t bits = 0;
  for (int i = 0; i < 8; i++) {
    bits |= ((uint64_t)p[i]) << (8 * i);
  }
  double value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

KKSpectrogramRef KKSpectrogramOpen(NSURL *url) {
  if (!url.isFileURL) {
    return NULL;
  }
  int fd = open(url.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) {
    KKLogWarn(@"KKSpectrogram: can't open %@ (errno %d)", url.lastPathComponent,
              errno);
    return NULL;
  }
  struct stat st;
  if (fstat(fd, &st) != 0 || (size_t)st.st_size < kKKSpectrogramHeaderSizeV1) {
    close(fd);
    KKLogWarn(@"KKSpectrogram: %@ is too small to be a spectrogram",
              url.lastPathComponent);
    return NULL;
  }
  size_t size = (size_t)st.st_size;
  // Mapped, not read: the grid is megabytes and the render path wants a
  // pointer, not a copy. The fd can close - the mapping keeps the file alive.
  void *map = mmap(NULL, size, PROT_READ, MAP_FILE | MAP_PRIVATE, fd, 0);
  close(fd);
  if (map == MAP_FAILED) {
    KKLogWarn(@"KKSpectrogram: mmap failed for %@", url.lastPathComponent);
    return NULL;
  }

  const uint8_t *bytes = (const uint8_t *)map;
  if (memcmp(bytes, "KKSG", 4) != 0) {
    munmap(map, size);
    KKLogWarn(@"KKSpectrogram: %@ is not a KKSG file", url.lastPathComponent);
    return NULL;
  }
  uint32_t version = KKReadU32(bytes + 4);
  if (version > KKSpectrogramFormatVersion) {
    munmap(map, size);
    KKLogWarn(@"KKSpectrogram: %@ is version %u, this build reads %u",
              url.lastPathComponent, version, KKSpectrogramFormatVersion);
    return NULL;
  }
  uint32_t numFrames = KKReadU32(bytes + 8);
  uint32_t numBands = KKReadU32(bytes + 12);
  double hopSeconds = KKReadF64(bytes + 16);
  double timelineStart = KKReadF64(bytes + 24);

  size_t headerSize =
      version >= 2 ? kKKSpectrogramHeaderSizeV2 : kKKSpectrogramHeaderSizeV1;
  double floorDB = kKKSpectrogramLegacyFloorDB;
  double ceilingDB = kKKSpectrogramLegacyCeilingDB;
  double waveformSampleRate = 0;
  uint64_t numWaveformSamples = 0;
  if (version >= 2) {
    if (size < kKKSpectrogramHeaderSizeV2) {
      munmap(map, size);
      KKLogWarn(@"KKSpectrogram: %@ claims v%u but has an incomplete header",
                url.lastPathComponent, version);
      return NULL;
    }
    floorDB = KKReadF64(bytes + 32);
    ceilingDB = KKReadF64(bytes + 40);
    waveformSampleRate = KKReadF64(bytes + 48);
    numWaveformSamples = KKReadU64(bytes + 56);
    // An inverted or collapsed window would make every dB map to the same band
    // value, so treat it as corrupt rather than dividing by ~0 later.
    if (!(ceilingDB > floorDB)) {
      munmap(map, size);
      KKLogWarn(@"KKSpectrogram: %@ has a bad dB window (%.1f..%.1f)",
                url.lastPathComponent, floorDB, ceilingDB);
      return NULL;
    }
    if ((numWaveformSamples > 0 && waveformSampleRate <= 0) ||
        (numWaveformSamples == 0 && waveformSampleRate != 0)) {
      munmap(map, size);
      KKLogWarn(@"KKSpectrogram: %@ has inconsistent waveform metadata",
                url.lastPathComponent);
      return NULL;
    }
  }

  // Trust nothing: a truncated or corrupt file must fail here, not by reading
  // off the end of the mapping on the render thread.
  if (numFrames == 0 || numBands == 0 || hopSeconds <= 0 ||
      (size_t)numFrames > SIZE_MAX / (size_t)numBands ||
      (size_t)numFrames * numBands > SIZE_MAX / sizeof(float) ||
      numWaveformSamples > SIZE_MAX / sizeof(float)) {
    munmap(map, size);
    KKLogWarn(@"KKSpectrogram: %@ header doesn't match its size",
              url.lastPathComponent);
    return NULL;
  }
  size_t gridBytes = (size_t)numFrames * numBands * sizeof(float);
  size_t waveformBytes = (size_t)numWaveformSamples * sizeof(float);
  if (headerSize > SIZE_MAX - gridBytes ||
      headerSize + gridBytes > SIZE_MAX - waveformBytes ||
      size < headerSize + gridBytes + waveformBytes) {
    munmap(map, size);
    KKLogWarn(@"KKSpectrogram: %@ header doesn't match its size",
              url.lastPathComponent);
    return NULL;
  }

  KKSpectrogramRef spectrogram = calloc(1, sizeof(struct KKSpectrogram));
  if (!spectrogram) {
    munmap(map, size);
    return NULL;
  }
  spectrogram->map = map;
  spectrogram->mapSize = size;
  spectrogram->data = (const float *)(bytes + headerSize);
  spectrogram->waveform = numWaveformSamples
                              ? (const float *)(bytes + headerSize + gridBytes)
                              : NULL;
  spectrogram->numFrames = numFrames;
  spectrogram->numBands = numBands;
  spectrogram->numWaveformSamples = numWaveformSamples;
  spectrogram->hopSeconds = hopSeconds;
  spectrogram->timelineStart = timelineStart;
  spectrogram->floorDB = floorDB;
  spectrogram->ceilingDB = ceilingDB;
  spectrogram->waveformSampleRate = waveformSampleRate;
  return spectrogram;
}

void KKSpectrogramClose(KKSpectrogramRef spectrogram) {
  if (!spectrogram) {
    return;
  }
  if (spectrogram->map) {
    munmap(spectrogram->map, spectrogram->mapSize);
  }
  free(spectrogram);
}

uint32_t KKSpectrogramNumFrames(KKSpectrogramRef s) {
  return s ? s->numFrames : 0;
}
uint32_t KKSpectrogramNumBands(KKSpectrogramRef s) {
  return s ? s->numBands : 0;
}
double KKSpectrogramHopSeconds(KKSpectrogramRef s) {
  return s ? s->hopSeconds : 0;
}
double KKSpectrogramTimelineStart(KKSpectrogramRef s) {
  return s ? s->timelineStart : 0;
}

double KKSpectrogramDuration(KKSpectrogramRef s) {
  return s ? (double)s->numFrames * s->hopSeconds : 0;
}
double KKSpectrogramWaveformSampleRate(KKSpectrogramRef s) {
  return s ? s->waveformSampleRate : 0;
}
uint64_t KKSpectrogramNumWaveformSamples(KKSpectrogramRef s) {
  return s ? s->numWaveformSamples : 0;
}

double KKSpectrogramFloorDB(KKSpectrogramRef s) {
  return s ? s->floorDB : kKKSpectrogramLegacyFloorDB;
}
double KKSpectrogramCeilingDB(KKSpectrogramRef s) {
  return s ? s->ceilingDB : kKKSpectrogramLegacyCeilingDB;
}

double KKSpectrogramNormalizedForDB(KKSpectrogramRef s, double db) {
  double floorDB = KKSpectrogramFloorDB(s);
  double ceilingDB = KKSpectrogramCeilingDB(s);
  double span = ceilingDB - floorDB;
  if (span <= 0)
    return 0;
  double n = (db - floorDB) / span;
  return n < 0 ? 0 : (n > 1 ? 1 : n);
}

BOOL KKSpectrogramSampleAtTime(KKSpectrogramRef s, double timelineSeconds,
                               float *outBands, size_t maxBands) {
  if (!s || !outBands || maxBands == 0) {
    return NO;
  }
  size_t count = maxBands < s->numBands ? maxBands : s->numBands;

  double frame = (timelineSeconds - s->timelineStart) / s->hopSeconds;
  if (frame < 0 || frame > (double)(s->numFrames - 1)) {
    // Zeroes, not the nearest edge frame: outside the published range there
    // is no audio, and holding the last frame would smear it forever.
    memset(outBands, 0, count * sizeof(float));
    return NO;
  }

  // Interpolated: the grid is a 60Hz hop, so at any other frame rate an exact
  // row rarely lines up and nearest-frame visibly stair-steps.
  uint32_t f0 = (uint32_t)frame;
  uint32_t f1 = f0 + 1 < s->numFrames ? f0 + 1 : f0;
  float t = (float)(frame - (double)f0);
  const float *row0 = s->data + (size_t)f0 * s->numBands;
  const float *row1 = s->data + (size_t)f1 * s->numBands;
  for (size_t b = 0; b < count; b++) {
    outBands[b] = row0[b] + (row1[b] - row0[b]) * t;
  }
  return YES;
}

BOOL KKSpectrogramWaveformWindowAtTime(KKSpectrogramRef s,
                                       double timelineSeconds,
                                       double windowSeconds, float *outSamples,
                                       size_t maxSamples) {
  if (!outSamples || maxSamples == 0) {
    return NO;
  }
  memset(outSamples, 0, maxSamples * sizeof(float));
  if (!s || !s->waveform || s->numWaveformSamples == 0 ||
      s->waveformSampleRate <= 0 || windowSeconds <= 0) {
    return NO;
  }

  BOOL hit = NO;
  double halfWindow = 0.5 * windowSeconds;
  for (size_t i = 0; i < maxSamples; i++) {
    double u = maxSamples > 1 ? (double)i / (double)(maxSamples - 1) : 0.5;
    double sampleTime = timelineSeconds + (u - 0.5) * (2.0 * halfWindow);
    double position = (sampleTime - s->timelineStart) * s->waveformSampleRate;
    if (position < 0 || position > (double)(s->numWaveformSamples - 1)) {
      continue;
    }
    uint64_t i0 = (uint64_t)position;
    uint64_t i1 = i0 + 1 < s->numWaveformSamples ? i0 + 1 : i0;
    float t = (float)(position - (double)i0);
    float a = s->waveform[i0];
    float b = s->waveform[i1];
    outSamples[i] = a + (b - a) * t;
    hit = YES;
  }
  return hit;
}

double KKSpectrogramFlowAtTime(KKSpectrogramRef s, double timelineSeconds,
                               uint32_t loBand, uint32_t hiBand,
                               double gate01) {
  if (!s) {
    return 0;
  }
  uint32_t nb = s->numBands;
  if (hiBand > nb) {
    hiBand = nb;
  }
  // A degenerate range reacts to the full mix rather than reporting nothing, so
  // a mis-specified lo/hi still drives the effect instead of freezing it.
  if (loBand >= hiBand) {
    loBand = 0;
    hiBand = nb;
  }

  double frame = (timelineSeconds - s->timelineStart) / s->hopSeconds;
  if (frame <= 0) {
    return 0; // before the analysis begins - nothing has accumulated yet
  }
  uint32_t last;
  double frac; // fraction of the frame straddling `timelineSeconds` to count
  if (frame >= (double)(s->numFrames - 1)) {
    last = s->numFrames - 1;
    frac = 1.0; // at or past the end - the whole analysis is behind us
  } else {
    last = (uint32_t)frame;
    frac = frame - (double)last; // continuous, rather than stepping per hop
  }

  float gate = (float)(gate01 < 0 ? 0 : gate01);
  double sum = 0;
  for (uint32_t f = 0; f <= last; f++) {
    const float *row = s->data + (size_t)f * nb;
    float peak = 0;
    for (uint32_t b = loBand; b < hiBand; b++) {
      if (row[b] > peak) {
        peak = row[b];
      }
    }
    float v = peak - gate;
    if (v <= 0) {
      continue; // under the gate this frame - the noise floor adds nothing
    }
    sum += (f == last) ? (double)v * frac : (double)v;
  }
  return sum * s->hopSeconds;
}

BOOL KKSpectrogramWrite(NSURL *url, const float *data, uint32_t numFrames,
                        uint32_t numBands, double hopSeconds,
                        double timelineStart, double floorDB, double ceilingDB,
                        NSError **error) {
  return KKSpectrogramWriteWithWaveform(url, data, numFrames, numBands,
                                        hopSeconds, timelineStart, floorDB,
                                        ceilingDB, NULL, 0, 0, error);
}

BOOL KKSpectrogramWriteWithWaveform(
    NSURL *url, const float *data, uint32_t numFrames, uint32_t numBands,
    double hopSeconds, double timelineStart, double floorDB, double ceilingDB,
    const float *waveform, uint64_t numWaveformSamples,
    double waveformSampleRate, NSError **error) {
  if (!data || numFrames == 0 || numBands == 0) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"KKSpectrogram"
                     code:1
                 userInfo:@{NSLocalizedDescriptionKey : @"Empty spectrogram"}];
    }
    return NO;
  }
  if (!(ceilingDB > floorDB)) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"KKSpectrogram"
                     code:2
                 userInfo:@{NSLocalizedDescriptionKey : @"Bad dB window"}];
    }
    return NO;
  }
  if ((numWaveformSamples > 0 && (!waveform || waveformSampleRate <= 0)) ||
      (numWaveformSamples == 0 && waveformSampleRate != 0)) {
    if (error) {
      *error =
          [NSError errorWithDomain:@"KKSpectrogram"
                              code:3
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"Bad waveform metadata"
                          }];
    }
    return NO;
  }
  if ((size_t)numFrames > SIZE_MAX / (size_t)numBands ||
      (size_t)numFrames * numBands > SIZE_MAX / sizeof(float) ||
      numWaveformSamples > SIZE_MAX / sizeof(float)) {
    if (error) {
      *error =
          [NSError errorWithDomain:@"KKSpectrogram"
                              code:4
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"Analysis is too large"
                          }];
    }
    return NO;
  }
  size_t gridBytes = (size_t)numFrames * numBands * sizeof(float);
  size_t waveformBytes = (size_t)numWaveformSamples * sizeof(float);
  if (kKKSpectrogramHeaderSizeV2 > SIZE_MAX - gridBytes ||
      kKKSpectrogramHeaderSizeV2 + gridBytes > SIZE_MAX - waveformBytes) {
    if (error) {
      *error =
          [NSError errorWithDomain:@"KKSpectrogram"
                              code:4
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"Analysis is too large"
                          }];
    }
    return NO;
  }
  NSMutableData *out = [NSMutableData
      dataWithCapacity:kKKSpectrogramHeaderSizeV2 + gridBytes + waveformBytes];
  [out appendBytes:"KKSG" length:4];
  uint32_t version = CFSwapInt32HostToLittle(KKSpectrogramFormatVersion);
  [out appendBytes:&version length:4];
  uint32_t frames = CFSwapInt32HostToLittle(numFrames);
  [out appendBytes:&frames length:4];
  uint32_t bands = CFSwapInt32HostToLittle(numBands);
  [out appendBytes:&bands length:4];
  KKAppendF64LE(out, hopSeconds);
  KKAppendF64LE(out, timelineStart);
  KKAppendF64LE(out, floorDB);
  KKAppendF64LE(out, ceilingDB);
  KKAppendF64LE(out, waveformSampleRate);
  uint64_t waveformCount = CFSwapInt64HostToLittle(numWaveformSamples);
  [out appendBytes:&waveformCount length:sizeof(waveformCount)];
  [out appendBytes:data length:gridBytes];
  if (waveformBytes) {
    [out appendBytes:waveform length:waveformBytes];
  }
  return [out writeToURL:url options:NSDataWritingAtomic error:error];
}

NSURL *KKSpectrogramSourcesDirectory(void) {
  // Resolved once: the container lookup is a sandbox round-trip, and this is
  // reached from the render path. The answer can't change while the process
  // lives - an entitlement isn't granted at runtime - so caching nil is right
  // too, and a plugin without the app group doesn't retry the lookup every
  // frame just to be told no again.
  static NSURL *cached = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURL *container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:
            kKKSpectrogramAppGroupID];
    if (container) {
      cached = [[container URLByAppendingPathComponent:@"Sonar" isDirectory:YES]
          URLByAppendingPathComponent:@"Sources"
                          isDirectory:YES];
    }
  });
  return cached;
}

/// The last parse, and the identity of the file it came from.
///
/// A static cache is right here and NOT the usual XPC mistake: every plugin
/// instance is its own process, so this shares nothing between instances - it
/// just stops a render that resolves a source by id re-reading and re-parsing
/// the manifest every frame. Locked because FCP renders on several threads.
static NSArray<NSDictionary<NSString *, id> *> *gPublishedCache = nil;
static ino_t gManifestInode = 0;
static time_t gManifestMtime = 0;
static off_t gManifestSize = 0;
static os_unfair_lock gPublishedLock = OS_UNFAIR_LOCK_INIT;

NSArray<NSDictionary<NSString *, id> *> *KKSpectrogramPublishedSources(void) {
  NSURL *dir = KKSpectrogramSourcesDirectory();
  if (!dir) {
    return @[];
  }
  NSURL *manifest = [dir URLByAppendingPathComponent:@"manifest.json"];

  // Cheap (a metadata read, no I/O) and the only way to notice a Publish:
  // caching on the path alone would pin whatever was there when the shader was
  // first rendered, so a newly published source would stay invisible until FCP
  // restarted. Publishing rewrites the manifest atomically, which swaps in a
  // NEW inode - the same signal the spectrogram mapping keys on.
  struct stat st;
  if (stat(manifest.fileSystemRepresentation, &st) != 0) {
    return @[]; // nothing published yet
  }

  os_unfair_lock_lock(&gPublishedLock);
  if (gPublishedCache && gManifestInode == st.st_ino &&
      gManifestMtime == st.st_mtime && gManifestSize == st.st_size) {
    NSArray *hit = gPublishedCache;
    os_unfair_lock_unlock(&gPublishedLock);
    return hit;
  }
  os_unfair_lock_unlock(&gPublishedLock);

  // Read and parsed outside the lock: this is the slow path, and holding a
  // render-path lock across file I/O would stall every other thread.
  NSData *data = [NSData dataWithContentsOfURL:manifest];
  if (!data) {
    return @[];
  }
  id parsed = [NSJSONSerialization JSONObjectWithData:data
                                              options:0
                                                error:NULL];
  if (![parsed isKindOfClass:NSArray.class]) {
    return @[];
  }
  NSArray *entries = parsed;
  NSSortDescriptor *newestFirst =
      [NSSortDescriptor sortDescriptorWithKey:@"publishedAt" ascending:NO];
  NSArray *sorted = [entries sortedArrayUsingDescriptors:@[ newestFirst ]];

  os_unfair_lock_lock(&gPublishedLock);
  gPublishedCache = sorted;
  gManifestInode = st.st_ino;
  gManifestMtime = st.st_mtime;
  gManifestSize = st.st_size;
  os_unfair_lock_unlock(&gPublishedLock);
  return sorted;
}

NSURL *KKSpectrogramURLForSourceID(NSString *sourceID) {
  NSURL *dir = KKSpectrogramSourcesDirectory();
  if (!dir || sourceID.length == 0) {
    return nil;
  }
  return [dir
      URLByAppendingPathComponent:[sourceID
                                      stringByAppendingPathExtension:@"kksg"]];
}
