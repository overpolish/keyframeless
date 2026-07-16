/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSpectrogram.h"

#import <os/lock.h>
#import <sys/mman.h>
#import <sys/stat.h>

#import "KKLog.h"

const uint32_t KKSpectrogramFormatVersion = 1;

static NSString *const kKKSpectrogramAppGroupID =
    @"group.co.overpolish.keyframeless";
static const size_t kKKSpectrogramHeaderSize = 4 + 4 + 4 + 4 + 8 + 8;

struct KKSpectrogram {
  void *map;
  size_t mapSize;
  const float *data;
  uint32_t numFrames;
  uint32_t numBands;
  double hopSeconds;
  double timelineStart;
};

static uint32_t KKReadU32(const uint8_t *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
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
  if (fstat(fd, &st) != 0 || (size_t)st.st_size < kKKSpectrogramHeaderSize) {
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

  // Trust nothing: a truncated or corrupt file must fail here, not by reading
  // off the end of the mapping on the render thread.
  size_t expected =
      kKKSpectrogramHeaderSize + (size_t)numFrames * numBands * sizeof(float);
  if (numFrames == 0 || numBands == 0 || hopSeconds <= 0 || size < expected) {
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
  spectrogram->data = (const float *)(bytes + kKKSpectrogramHeaderSize);
  spectrogram->numFrames = numFrames;
  spectrogram->numBands = numBands;
  spectrogram->hopSeconds = hopSeconds;
  spectrogram->timelineStart = timelineStart;
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

BOOL KKSpectrogramWrite(NSURL *url, const float *data, uint32_t numFrames,
                        uint32_t numBands, double hopSeconds,
                        double timelineStart, NSError **error) {
  if (!data || numFrames == 0 || numBands == 0) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"KKSpectrogram"
                     code:1
                 userInfo:@{NSLocalizedDescriptionKey : @"Empty spectrogram"}];
    }
    return NO;
  }
  size_t gridBytes = (size_t)numFrames * numBands * sizeof(float);
  NSMutableData *out =
      [NSMutableData dataWithCapacity:kKKSpectrogramHeaderSize + gridBytes];
  [out appendBytes:"KKSG" length:4];
  uint32_t version = CFSwapInt32HostToLittle(KKSpectrogramFormatVersion);
  [out appendBytes:&version length:4];
  uint32_t frames = CFSwapInt32HostToLittle(numFrames);
  [out appendBytes:&frames length:4];
  uint32_t bands = CFSwapInt32HostToLittle(numBands);
  [out appendBytes:&bands length:4];
  KKAppendF64LE(out, hopSeconds);
  KKAppendF64LE(out, timelineStart);
  [out appendBytes:data length:gridBytes];
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
