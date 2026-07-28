/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLinkBus_Private.h"

#import <os/lock.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <time.h>

#import "KKLog.h"
#import "KKPluginInstanceState.h" // KKInstanceUUIDForAPI
#import "KKTimeline.h"
#import "KKTimingEvaluation.h"
#import <FxPlug/FxPlugSDK.h> // PROAPIAccessing, FxProjectAPI

// Same shared container the Sonar spectrograms use, so the bus works from the
// plugin sandbox and is visible across every plugin that ships the entitlement.
static NSString *const kKKLinkBusAppGroupID =
    @"group.com.keyframeless";

@implementation KKLinkedCurve

- (NSArray<NSNumber *> *)valuesAtTimelineSeconds:(double)tlSec
                                      outOfRange:(KKLinkOutOfRange)outOfRange {
  BOOL outside = tlSec < _timelineStart || tlSec > _timelineEnd;
  if (outside && outOfRange == KKLinkOutOfRangeZero) {
    NSUInteger n = _lane.keyposes.firstObject.values.count;
    if (n == 0)
      return nil;
    NSMutableArray<NSNumber *> *zeros = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
      [zeros addObject:@0.0];
    return zeros;
  }
  double span = _timelineEnd - _timelineStart;
  double frac = span > 0.0 ? (tlSec - _timelineStart) / span : 0.0;
  frac = MAX(0.0, MIN(1.0, frac));
  return KKLaneDisplayValueAtFraction(_lane, frac);
}

@end

// Filename-safe form of a link name: runs of anything outside [A-Za-z0-9._-]
// collapse to a single '_', and a leading dot is prefixed away so the file is
// not hidden. A stable, human-readable id is enough for slice 1 (names are
// unique by authoring convention); a later slice keys on a UUID + display map.
static NSString *KKLinkSafeFilename(NSString *linkID) {
  NSCharacterSet *bad = [[NSCharacterSet
      characterSetWithCharactersInString:
          @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"]
      invertedSet];
  NSString *s = [[linkID componentsSeparatedByCharactersInSet:bad]
      componentsJoinedByString:@"_"];
  if (s.length == 0 || [s hasPrefix:@"."])
    s = [@"_" stringByAppendingString:s];
  return s;
}

// Nanosecond change stamp for a file: mtime seconds are too coarse (a drag can
// rewrite the same-sized file several times within one second), so include the
// nanosecond field. 0 when the file is absent.
static long long KKLinkStatStamp(const struct stat *st) {
  return (long long)st->st_mtimespec.tv_sec * 1000000000LL +
         st->st_mtimespec.tv_nsec;
}

// Cache entry for the parsed-curve cache below (declared at file scope - an
// ObjC class can't be nested inside an @implementation).
@interface _KKLinkLoadEntry : NSObject
@property(nonatomic, nullable) KKLinkedCurve *curve;
@property(nonatomic) long long stamp; // mtime nanoseconds
@property(nonatomic) off_t size;
@property(nonatomic) BOOL existed;
@end
@implementation _KKLinkLoadEntry
@end

@implementation KKLinkLayerSource
@end

@implementation KKLinkManifest
@end

// Per-process record of the last manifest bytes written per uuid, so a render
// loop that rewrites an unchanged manifest every frame does no disk I/O.
static NSMutableDictionary<NSString *, NSData *> *KKLinkLastManifest(void) {
  static NSMutableDictionary<NSString *, NSData *> *dict = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dict = [NSMutableDictionary dictionary];
  });
  return dict;
}
// Monotonic seconds of the last ACTUAL write per uuid, so an unchanged manifest
// is still re-touched periodically (keeps a live clip's file mtime fresh for
// GC).
static NSMutableDictionary<NSString *, NSNumber *> *
KKLinkManifestWriteTime(void) {
  static NSMutableDictionary<NSString *, NSNumber *> *dict = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dict = [NSMutableDictionary dictionary];
  });
  return dict;
}
static os_unfair_lock gLinkManifestLock = OS_UNFAIR_LOCK_INIT;

static double KKLinkMonoSeconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1.0e9;
}

// A live clip re-touches its manifest at least this often (even when unchanged)
// so its file mtime stays recent; a manifest older than the prune window is
// treated as an orphan (its clip was deleted) and removed on the next read.
// Generous, so a clip rendered anytime within the window stays discoverable.
// The touch cadence doubles as a liveness heartbeat: a rendering clip
// re-touches its manifest this often, so a manifest whose mtime is much older
// belongs to a clip that is deleted or idle (the picker warns past ~30s and
// name-collision translation prefers the freshest). Keep well under that
// warning threshold.
static const double kKKManifestTouchSeconds = 10.0;
static const long kKKManifestPruneSeconds = 7 * 24 * 3600; // 7 days

static NSData *KKLinkManifestData(KKLinkManifest *m) {
  // NSJSONSerialization RAISES on a non-finite number rather than returning an
  // error, and an uncaught raise here takes the whole XPC process down. Callers
  // guard their own timing, so this is the backstop: no manifest beats a dead
  // plugin.
  if (!isfinite(m.clipStartSec) || !isfinite(m.clipDurSec))
    return nil;
  NSMutableDictionary *d = [@{
    @"uuid" : m.uuid ?: @"",
    @"name" : m.displayName ?: @"",
    @"effect" : m.effectName ?: @"",
    @"doc" : m.documentID ?: @"",
    @"start" : @(m.clipStartSec),
    @"dur" : @(m.clipDurSec),
    @"params" : m.paramLabels ?: @[],
    @"paramNames" : m.paramDisplayNames ?: m.paramLabels ?: @[],
    @"v" : @1,
  } mutableCopy];
  if (m.layers.count) {
    NSMutableArray<NSDictionary *> *layers =
        [NSMutableArray arrayWithCapacity:m.layers.count];
    for (KKLinkLayerSource *l in m.layers)
      [layers addObject:@{
        @"id" : l.layerID ?: @"",
        @"name" : l.displayName ?: @"",
        @"params" : l.paramLabels ?: @[],
        @"paramNames" : l.paramDisplayNames ?: l.paramLabels ?: @[],
      }];
    d[@"layers"] = layers;
  }
  return [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
}

static KKLinkManifest *KKLinkManifestFromData(NSData *data) {
  NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data
                                                    options:0
                                                      error:nil];
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  NSString *uuid = d[@"uuid"];
  if (![uuid isKindOfClass:[NSString class]] || uuid.length == 0)
    return nil;
  KKLinkManifest *m = [[KKLinkManifest alloc] init];
  m.uuid = uuid;
  m.displayName =
      [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
  m.effectName =
      [d[@"effect"] isKindOfClass:[NSString class]] ? d[@"effect"] : @"";
  m.documentID = [d[@"doc"] isKindOfClass:[NSString class]] ? d[@"doc"] : @"";
  m.clipStartSec = [d[@"start"] doubleValue];
  m.clipDurSec = [d[@"dur"] doubleValue];
  m.paramLabels =
      [d[@"params"] isKindOfClass:[NSArray class]] ? d[@"params"] : @[];
  // Older manifests (no "paramNames") show raw labels; a length mismatch also
  // falls back, so the parallel-array index lookup in the picker stays safe.
  NSArray *names = d[@"paramNames"];
  m.paramDisplayNames = ([names isKindOfClass:[NSArray class]] &&
                         names.count == m.paramLabels.count)
                            ? names
                            : m.paramLabels;
  // Layered sources ("layers" absent on flat / older manifests = empty).
  NSMutableArray<KKLinkLayerSource *> *layers = [NSMutableArray array];
  NSArray *rawLayers = d[@"layers"];
  if ([rawLayers isKindOfClass:[NSArray class]])
    for (NSDictionary *ld in rawLayers) {
      if (![ld isKindOfClass:[NSDictionary class]])
        continue;
      NSString *lid = ld[@"id"];
      if (![lid isKindOfClass:[NSString class]] || lid.length == 0)
        continue;
      KKLinkLayerSource *l = [[KKLinkLayerSource alloc] init];
      l.layerID = lid;
      l.displayName =
          [ld[@"name"] isKindOfClass:[NSString class]] ? ld[@"name"] : lid;
      l.paramLabels =
          [ld[@"params"] isKindOfClass:[NSArray class]] ? ld[@"params"] : @[];
      NSArray *lNames = ld[@"paramNames"];
      l.paramDisplayNames = ([lNames isKindOfClass:[NSArray class]] &&
                             lNames.count == l.paramLabels.count)
                                ? lNames
                                : l.paramLabels;
      [layers addObject:l];
    }
  m.layers = layers;
  return m;
}

@implementation KKLinkBus

+ (NSURL *)linksDirectory {
  static NSURL *cached = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURL *container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:kKKLinkBusAppGroupID];
    if (container) {
      cached = [container URLByAppendingPathComponent:@"Links" isDirectory:YES];
      [[NSFileManager defaultManager] createDirectoryAtURL:cached
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
    }
  });
  return cached;
}

// Resolve the app-group container off the caller's thread. The first
// containerURLForSecurityApplicationGroupIdentifier: in a sandboxed process can
// block ~1-2s while the container is provisioned; without warming, that cost
// lands on the first LINK RESOLVE - which happens on the render thread
// mid-frame
// - and freezes playback (linked clips only; non-linked never touch the bus).
// Each FxPlug plugin instance is its own XPC process, so every process that may
// publish or subscribe should call this at init, well before the render loop.
// Idempotent: dispatch_once inside linksDirectory means later real calls hit
// the warmed cache (or, if the frame beats the warm, block once instead of per
// process-with-cold-cache).
+ (void)warmUp {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    (void)[self linksDirectory];
  });
}

// Per-process record of the last bytes written per link, so a render loop that
// republishes an unchanged curve every frame does no disk I/O. A process-local
// static is correct here (not the usual XPC trap): each publisher instance is
// its own process and wants its own memory. Locked because FCP renders on
// several threads.
static NSMutableDictionary<NSString *, NSData *> *KKLinkLastPublished(void) {
  static NSMutableDictionary<NSString *, NSData *> *dict = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dict = [NSMutableDictionary dictionary];
  });
  return dict;
}
static os_unfair_lock gLinkPublishLock = OS_UNFAIR_LOCK_INIT;

+ (void)publishLane:(KKLane *)lane
             linkID:(NSString *)linkID
      timelineStart:(double)tlStart
        timelineEnd:(double)tlEnd
               unit:(NSString *)unit {
  if (!lane || linkID.length == 0)
    return;
  // Same non-finite raise as KKLinkManifestData, on the same call path (a
  // publish follows every manifest write).
  if (!isfinite(tlStart) || !isfinite(tlEnd))
    return;
  NSURL *dir = [self linksDirectory];
  if (!dir)
    return;

  // No public per-lane JSON exists; wrap the lane in a one-lane timeline and
  // reuse the timeline serializer (keyposes, intervals, easing - the lot).
  KKTimeline *wrapper = [KKTimeline timeline];
  wrapper.lanes = @[ lane ];
  NSString *laneJSON = [KKTimeline jsonFromTimeline:wrapper];
  if (laneJSON.length == 0)
    return;

  NSDictionary *file = @{
    @"v" : @1,
    @"name" : linkID, // the display name, for the subscribe picker to list
    @"unit" : unit ?: @"",
    @"tlStart" : @(tlStart),
    @"tlEnd" : @(tlEnd),
    @"laneTimeline" : laneJSON,
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:file
                                                 options:0
                                                   error:nil];
  if (!data)
    return;

  os_unfair_lock_lock(&gLinkPublishLock);
  NSMutableDictionary<NSString *, NSData *> *last = KKLinkLastPublished();
  BOOL unchanged = [last[linkID] isEqualToData:data];
  if (!unchanged)
    last[linkID] = data;
  os_unfair_lock_unlock(&gLinkPublishLock);
  if (unchanged)
    return;

  NSURL *url = [dir
      URLByAppendingPathComponent:[KKLinkSafeFilename(linkID)
                                      stringByAppendingPathExtension:@"json"]];
  NSError *err = nil;
  if (![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
    KKLogWarn(@"KKLinkBus: publish '%@' failed: %@", linkID, err);
    // Drop the cache entry so the next tick retries rather than assuming the
    // last (failed) write landed.
    os_unfair_lock_lock(&gLinkPublishLock);
    [last removeObjectForKey:linkID];
    os_unfair_lock_unlock(&gLinkPublishLock);
  }
}

+ (NSArray<NSString *> *)publishedLinkNames {
  NSURL *dir = [self linksDirectory];
  if (!dir)
    return @[];
  NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:dir
      includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (NSURL *u in files) {
    if (![u.pathExtension isEqualToString:@"json"])
      continue;
    NSData *d = [NSData dataWithContentsOfURL:u];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d
                                                          options:0
                                                            error:nil]
                        : nil;
    NSString *name = [j isKindOfClass:[NSDictionary class]] ? j[@"name"] : nil;
    if ([name isKindOfClass:[NSString class]] && name.length &&
        ![names containsObject:name])
      [names addObject:name];
  }
  [names sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  return names;
}

+ (long long)changeStampForLink:(NSString *)name {
  NSURL *dir = [self linksDirectory];
  if (!dir || name.length == 0)
    return 0;
  NSURL *url = [dir
      URLByAppendingPathComponent:[KKLinkSafeFilename(name)
                                      stringByAppendingPathExtension:@"json"]];
  struct stat st;
  return stat(url.fileSystemRepresentation, &st) == 0 ? KKLinkStatStamp(&st)
                                                      : 0;
}

static KKLinkedCurve *KKLinkParseCurveData(NSData *data) {
  NSDictionary *file = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:nil];
  if (![file isKindOfClass:[NSDictionary class]])
    return nil;
  NSString *laneJSON = file[@"laneTimeline"];
  if (![laneJSON isKindOfClass:[NSString class]] || laneJSON.length == 0)
    return nil;
  KKTimeline *wrapper = [KKTimeline timelineFromJSON:laneJSON];
  KKLane *lane = wrapper.lanes.firstObject;
  if (!lane)
    return nil;
  KKLinkedCurve *curve = [[KKLinkedCurve alloc] init];
  curve.lane = lane;
  curve.timelineStart = [file[@"tlStart"] doubleValue];
  curve.timelineEnd = [file[@"tlEnd"] doubleValue];
  NSString *unit = file[@"unit"];
  curve.unit =
      [unit isKindOfClass:[NSString class]] && unit.length ? unit : nil;
  return curve;
}

// Parsed-curve cache for the render path: loadCurve is hit per subscribed lane
// per frame. Keyed by linkID and invalidated on the file's mtime/size - an
// atomic republish swaps those, exactly like the spectrogram mapping. A nil
// curve (file absent) is cached too, so a subscriber pointing at an unpublished
// name doesn't stat+miss every frame. Process-local (not shared across
// instances) and locked (FCP renders multi-thread).
static os_unfair_lock gLinkLoadLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, _KKLinkLoadEntry *> *
KKLinkLoadCache(void) {
  static NSMutableDictionary<NSString *, _KKLinkLoadEntry *> *dict = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dict = [NSMutableDictionary dictionary];
  });
  return dict;
}

+ (KKLinkedCurve *)loadCurve:(NSString *)linkID {
  if (linkID.length == 0)
    return nil;
  NSURL *dir = [self linksDirectory];
  if (!dir)
    return nil;
  NSURL *url = [dir
      URLByAppendingPathComponent:[KKLinkSafeFilename(linkID)
                                      stringByAppendingPathExtension:@"json"]];

  struct stat st;
  BOOL exists = stat(url.fileSystemRepresentation, &st) == 0;

  os_unfair_lock_lock(&gLinkLoadLock);
  _KKLinkLoadEntry *e = KKLinkLoadCache()[linkID];
  if (e && e.existed == exists &&
      (!exists || (e.stamp == KKLinkStatStamp(&st) && e.size == st.st_size))) {
    KKLinkedCurve *cached = e.curve;
    os_unfair_lock_unlock(&gLinkLoadLock);
    return cached;
  }
  os_unfair_lock_unlock(&gLinkLoadLock);

  KKLinkedCurve *curve = nil;
  if (exists) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (data)
      curve = KKLinkParseCurveData(data);
  }

  _KKLinkLoadEntry *ne = [[_KKLinkLoadEntry alloc] init];
  ne.curve = curve;
  ne.existed = exists;
  ne.stamp = exists ? KKLinkStatStamp(&st) : 0;
  ne.size = exists ? st.st_size : 0;
  os_unfair_lock_lock(&gLinkLoadLock);
  KKLinkLoadCache()[linkID] = ne;
  os_unfair_lock_unlock(&gLinkLoadLock);
  return curve;
}

+ (NSURL *)manifestsDirectory {
  // Cache only the SLOW part (the app-group container lookup); (re)create the
  // "Manifests" subdir on every call so an externally-deleted folder self-heals
  // instead of leaving the process writing into a dead path forever.
  static NSURL *container = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:kKKLinkBusAppGroupID];
  });
  if (!container)
    return nil;
  NSURL *dir = [container URLByAppendingPathComponent:@"Manifests"
                                          isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
  return dir;
}

+ (void)writeManifest:(KKLinkManifest *)manifest {
  if (manifest.uuid.length == 0)
    return;
  NSData *data = KKLinkManifestData(manifest);
  if (!data)
    return;
  // Skip the write when the bytes match what we last wrote AND we wrote
  // recently (render tick calls this every frame). An unchanged manifest is
  // still re-touched every kKKManifestTouchSeconds so a live clip's file mtime
  // stays fresh for GC. Skip check FIRST so manifestsDirectory's dir-ensure
  // only runs on a real write.
  double now = KKLinkMonoSeconds();
  os_unfair_lock_lock(&gLinkManifestLock);
  NSMutableDictionary<NSString *, NSData *> *last = KKLinkLastManifest();
  NSMutableDictionary<NSString *, NSNumber *> *times =
      KKLinkManifestWriteTime();
  BOOL unchanged = [last[manifest.uuid] isEqualToData:data];
  NSNumber *lastWrite = times[manifest.uuid];
  BOOL stale =
      !lastWrite || (now - lastWrite.doubleValue) > kKKManifestTouchSeconds;
  BOOL doWrite = !unchanged || stale;
  if (doWrite) {
    last[manifest.uuid] = data;
    times[manifest.uuid] = @(now);
  }
  os_unfair_lock_unlock(&gLinkManifestLock);
  if (!doWrite)
    return;
  NSURL *dir = [self manifestsDirectory];
  if (!dir)
    return;
  NSURL *url = [dir URLByAppendingPathComponent:
                        [KKLinkSafeFilename(manifest.uuid)
                            stringByAppendingPathExtension:@"manifest.json"]];
  [data writeToURL:url atomically:YES];
}

// Duplicate PARAM display names are respelled by their KEY (the machine
// label): the first occurrence keeps the friendly name, later twins show the
// key ("uSizeL", not "Size (2)") - meaningful, and it round-trips because the
// display->stored translator resolves display names by first match and
// accepts raw keys. Identity arrays (paramLabels) are never touched.
static NSArray<NSString *> *
KKLinkKeySpelledParamNames(NSArray<NSString *> *names,
                           NSArray<NSString *> *labels) {
  if (names.count < 2)
    return names;
  NSMutableSet<NSString *> *seen = [NSMutableSet setWithCapacity:names.count];
  NSMutableArray<NSString *> *out =
      [NSMutableArray arrayWithCapacity:names.count];
  for (NSUInteger i = 0; i < names.count; i++) {
    NSString *n = names[i];
    if ([seen containsObject:n] && i < labels.count && labels[i].length)
      n = labels[i];
    [seen addObject:n];
    [out addObject:n];
  }
  return out;
}

// Duplicate display names get " (2)", " (3)"... in encounter (array) order -
// deterministic because the underlying order is stable. Used for LAYER and
// CLIP display names, which have no user-recognizable machine key to respell
// by (a layerID/uuid would read as noise).
static NSArray<NSString *> *
KKLinkDisambiguatedNames(NSArray<NSString *> *names) {
  if (names.count < 2)
    return names;
  NSMutableDictionary<NSString *, NSNumber *> *seen =
      [NSMutableDictionary dictionaryWithCapacity:names.count];
  NSMutableArray<NSString *> *outNames =
      [NSMutableArray arrayWithCapacity:names.count];
  for (NSString *n in names) {
    NSNumber *c = seen[n];
    if (!c) {
      seen[n] = @1;
      [outNames addObject:n];
    } else {
      NSInteger k = c.integerValue + 1;
      seen[n] = @(k);
      [outNames addObject:[NSString stringWithFormat:@"%@ (%ld)", n, (long)k]];
    }
  }
  return outNames;
}

+ (NSArray<KKLinkManifest *> *)allManifests {
  NSURL *dir = [self manifestsDirectory];
  if (!dir)
    return @[];
  NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:dir
      includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
  NSMutableArray<KKLinkManifest *> *out = [NSMutableArray array];
  time_t nowWall = time(NULL);
  for (NSURL *url in files) {
    if (![url.lastPathComponent hasSuffix:@".manifest.json"])
      continue;
    // GC orphans: a manifest not touched within the prune window belongs to a
    // clip that stopped rendering (deleted) - a live clip re-touches every
    // kKKManifestTouchSeconds.
    struct stat st;
    BOOL statOK = stat(url.fileSystemRepresentation, &st) == 0;
    if (statOK &&
        (nowWall - st.st_mtimespec.tv_sec) > kKKManifestPruneSeconds) {
      [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
      continue;
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    KKLinkManifest *m = data ? KKLinkManifestFromData(data) : nil;
    if (m) {
      m.lastSeenAgeSec =
          statOK ? MAX(0.0, (double)(nowWall - st.st_mtimespec.tv_sec)) : 0.0;
      [out addObject:m];
    }
  }
  [out sortUsingComparator:^NSComparisonResult(KKLinkManifest *a,
                                               KKLinkManifest *b) {
    if (a.clipStartSec != b.clipStartSec)
      return a.clipStartSec < b.clipStartSec ? NSOrderedAscending
                                             : NSOrderedDescending;
    return [a.displayName ?: @"" compare:b.displayName ?: @""];
  }];
  // READ-side display-name disambiguation, level 2 - PARAMS and LAYERS within
  // each manifest. Params are identified by machine label (Mirage: the GLSL
  // uniform; Canvas: the template key) but PICKED and translated by display
  // name, and duplicate display names are legal (two directives may share
  // label="Size"). Respell duplicate params by their KEY so the picker rows
  // read distinctly and the display->stored translation (indexOfObject: on
  // these arrays) resolves uniquely. Same-named layers inside one clip get
  // the numeric " (2)" treatment instead (no friendly key to respell by).
  for (KKLinkManifest *m in out) {
    m.paramDisplayNames =
        KKLinkKeySpelledParamNames(m.paramDisplayNames, m.paramLabels);
    NSMutableArray<NSString *> *layerNames =
        [NSMutableArray arrayWithCapacity:m.layers.count];
    for (KKLinkLayerSource *ls in m.layers) {
      [layerNames addObject:ls.displayName ?: @""];
      ls.paramDisplayNames =
          KKLinkKeySpelledParamNames(ls.paramDisplayNames, ls.paramLabels);
    }
    NSArray<NSString *> *uniqueLayers = KKLinkDisambiguatedNames(layerNames);
    for (NSUInteger i = 0; i < m.layers.count; i++)
      m.layers[i].displayName = uniqueLayers[i];
  }
  // READ-side display-name disambiguation: refs are STORED uuid-keyed, but the
  // editing surface (picker, expression text, translators) works in display
  // names - two same-named clips ("Canvas @ 0:00" twins) would make the
  // second one unreachable, since name translation can only bind one. Suffix
  // the twins " (2)", " (3)"... so every display name in one loaded list is
  // unique; all consumers (picker, translate, AI sources) share this list, so
  // the suffixed name round-trips display->stored->display cleanly. Ordering
  // within a twin group: live (recently-seen) before stale, then by uuid -
  // stable across menu opens, and a deleted twin's corpse never steals the
  // clean unsuffixed name from the live clip.
  NSMutableDictionary<NSString *, NSMutableArray<KKLinkManifest *> *> *byName =
      [NSMutableDictionary dictionary];
  for (KKLinkManifest *m in out) {
    NSString *name = m.displayName ?: @"";
    NSMutableArray<KKLinkManifest *> *group = byName[name];
    if (!group)
      byName[name] = group = [NSMutableArray array];
    [group addObject:m];
  }
  for (NSString *name in byName) {
    NSMutableArray<KKLinkManifest *> *group = byName[name];
    if (group.count < 2)
      continue;
    [group sortUsingComparator:^NSComparisonResult(KKLinkManifest *a,
                                                   KKLinkManifest *b) {
      BOOL aStale = a.lastSeenAgeSec > 30.0, bStale = b.lastSeenAgeSec > 30.0;
      if (aStale != bStale)
        return aStale ? NSOrderedDescending : NSOrderedAscending;
      return [a.uuid ?: @"" compare:b.uuid ?: @""];
    }];
    for (NSUInteger i = 1; i < group.count; i++)
      group[i].displayName =
          [name stringByAppendingFormat:@" (%lu)", (unsigned long)(i + 1)];
  }
  // Prune orphan thumbnails (a clip whose manifest was GC'd above) while we
  // have the live uuid set - cheap, and this runs on menu-open, not the render
  // path.
  NSMutableSet<NSString *> *liveUUIDs = [NSMutableSet set];
  for (KKLinkManifest *m in out)
    if (m.uuid.length)
      [liveUUIDs addObject:m.uuid];
  [self _pruneThumbnailsKeepingUUIDs:liveUUIDs];
  return out;
}

+ (NSArray<KKLinkManifest *> *)manifestsForDocumentID:(NSString *)documentID {
  NSArray<KKLinkManifest *> *all = [self allManifests];
  if (documentID.length == 0)
    return all; // caller has no document scope - library-wide (legacy
                // behaviour)
  NSMutableArray<KKLinkManifest *> *out = [NSMutableArray array];
  for (KKLinkManifest *m in all)
    // Empty documentID = legacy / host-unknown: matches any project so it never
    // vanishes; otherwise it must be the SAME project as the asking clip.
    if (m.documentID.length == 0 || [m.documentID isEqualToString:documentID])
      [out addObject:m];
  return out;
}

+ (NSURL *)thumbnailsDirectory {
  // Same shape as manifestsDirectory: cache the slow container lookup,
  // re-ensure the subdir each call so an externally-deleted folder self-heals.
  static NSURL *container = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:kKKLinkBusAppGroupID];
  });
  if (!container)
    return nil;
  NSURL *dir = [container URLByAppendingPathComponent:@"Thumbnails"
                                          isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
  return dir;
}

// Effect-level file: `<safe(uuid)>.thumb.jpg`. Layer-level:
// `<safe(uuid)>.<safe(layerID)>.thumb.jpg` - the uuid-dot prefix is what the
// prune/remove sweeps match on.
+ (NSURL *)_thumbnailURLForUUID:(NSString *)uuid layerID:(NSString *)layerID {
  if (uuid.length == 0)
    return nil;
  NSURL *dir = [self thumbnailsDirectory];
  if (!dir)
    return nil;
  NSString *stem =
      layerID.length
          ? [NSString stringWithFormat:@"%@.%@", KKLinkSafeFilename(uuid),
                                       KKLinkSafeFilename(layerID)]
          : KKLinkSafeFilename(uuid);
  return [dir URLByAppendingPathComponent:
                  [stem stringByAppendingPathExtension:@"thumb.jpg"]];
}

+ (void)writeThumbnailJPEG:(NSData *)jpeg
                   forUUID:(NSString *)uuid
                   layerID:(NSString *)layerID {
  if (jpeg.length == 0 || uuid.length == 0)
    return;
  NSURL *url = [self _thumbnailURLForUUID:uuid layerID:layerID];
  if (!url)
    return;
  // Skip a byte-identical rewrite (the inspector re-bakes on a debounce and the
  // frame is often unchanged). One file read per bake, off the render path.
  NSData *existing = [NSData dataWithContentsOfURL:url];
  if ([existing isEqualToData:jpeg])
    return;
  [jpeg writeToURL:url atomically:YES];
}

+ (void)writeThumbnailJPEG:(NSData *)jpeg forUUID:(NSString *)uuid {
  [self writeThumbnailJPEG:jpeg forUUID:uuid layerID:nil];
}

+ (NSString *)thumbnailPathForUUID:(NSString *)uuid
                           layerID:(NSString *)layerID {
  NSURL *url = [self _thumbnailURLForUUID:uuid layerID:layerID];
  if (!url)
    return nil;
  return [[NSFileManager defaultManager] fileExistsAtPath:url.path] ? url.path
                                                                    : nil;
}

+ (NSString *)thumbnailPathForUUID:(NSString *)uuid {
  return [self thumbnailPathForUUID:uuid layerID:nil];
}

+ (void)removeSourceForUUID:(NSString *)uuid {
  if (uuid.length == 0)
    return;
  NSString *safe = KKLinkSafeFilename(uuid);
  NSFileManager *fm = [NSFileManager defaultManager];

  NSURL *md = [self manifestsDirectory];
  if (md)
    [fm removeItemAtURL:
            [md URLByAppendingPathComponent:
                    [safe stringByAppendingPathExtension:@"manifest.json"]]
                  error:nil];
  NSURL *td = [self thumbnailsDirectory];
  if (td) {
    [fm removeItemAtURL:
            [td URLByAppendingPathComponent:
                    [safe stringByAppendingPathExtension:@"thumb.jpg"]]
                  error:nil];
    // Per-layer thumbnails share the uuid-dot prefix.
    NSString *prefix = [safe stringByAppendingString:@"."];
    for (NSURL *f in
         [fm contentsOfDirectoryAtURL:td
             includingPropertiesForKeys:nil
                                options:NSDirectoryEnumerationSkipsHiddenFiles
                                  error:nil])
      if ([f.lastPathComponent hasPrefix:prefix] &&
          [f.lastPathComponent hasSuffix:@".thumb.jpg"])
        [fm removeItemAtURL:f error:nil];
  }
  // Published curves live in Links/ as "<safe>.<label>.json".
  NSURL *ld = [self linksDirectory];
  if (ld) {
    NSString *prefix = [safe stringByAppendingString:@"."];
    for (NSURL *f in
         [fm contentsOfDirectoryAtURL:ld
             includingPropertiesForKeys:nil
                                options:NSDirectoryEnumerationSkipsHiddenFiles
                                  error:nil])
      if ([f.lastPathComponent hasPrefix:prefix])
        [fm removeItemAtURL:f error:nil];
  }
  // Drop the manifest idempotency cache so a re-add (undo) in THIS process
  // isn't skipped as "unchanged".
  os_unfair_lock_lock(&gLinkManifestLock);
  [KKLinkLastManifest() removeObjectForKey:uuid];
  [KKLinkManifestWriteTime() removeObjectForKey:uuid];
  os_unfair_lock_unlock(&gLinkManifestLock);
}

+ (NSArray<NSString *> *)reconcileEffectName:(NSString *)effectName
                                keepingUUIDs:(NSSet<NSString *> *)liveUUIDs {
  NSMutableArray<NSString *> *removed = [NSMutableArray array];
  // allManifests reads every manifest on disk (and parses its uuid + effect).
  for (KKLinkManifest *m in [self allManifests]) {
    if (m.uuid.length == 0)
      continue;
    // Only ever touch THIS effect's manifests. Legacy manifests (no recorded
    // effect name) are treated as ours - they predate multi-plugin use.
    BOOL mine =
        (m.effectName.length == 0) || [m.effectName isEqualToString:effectName];
    if (mine && ![liveUUIDs containsObject:m.uuid]) {
      [removed addObject:m.uuid];
      [self removeSourceForUUID:m.uuid];
    }
  }
  return removed;
}

+ (void)_pruneThumbnailsKeepingUUIDs:(NSSet<NSString *> *)keepUUIDs {
  NSURL *dir = [self thumbnailsDirectory];
  if (!dir)
    return;
  NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:dir
      includingPropertiesForKeys:nil
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
  // Keep the effect-level file (`<safe>.thumb.jpg`) AND any per-layer files
  // (`<safe>.<layer>.thumb.jpg`) of every live uuid.
  NSMutableSet<NSString *> *keepFiles = [NSMutableSet set];
  NSMutableArray<NSString *> *keepPrefixes = [NSMutableArray array];
  for (NSString *uuid in keepUUIDs) {
    NSString *safe = KKLinkSafeFilename(uuid);
    [keepFiles addObject:[safe stringByAppendingPathExtension:@"thumb.jpg"]];
    [keepPrefixes addObject:[safe stringByAppendingString:@"."]];
  }
  for (NSURL *url in files) {
    NSString *name = url.lastPathComponent;
    if (![name hasSuffix:@".thumb.jpg"])
      continue;
    BOOL keep = [keepFiles containsObject:name];
    for (NSString *prefix in keepPrefixes) {
      if (keep)
        break;
      keep = [name hasPrefix:prefix];
    }
    if (!keep)
      [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
  }
}

@end
