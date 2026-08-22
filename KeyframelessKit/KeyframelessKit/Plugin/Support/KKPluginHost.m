/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPluginHost.h"
#import "KKDataBlob.h"
#import "KKHostInfo.h"
#import "KKLinkBus.h"
#import "KKLog.h"
#import "KKMiniViewerRenderer.h"
#import "KKTimelineInspectorView.h"
#import <FxPlug/FxPlugSDK.h>
#import <errno.h>
#import <objc/runtime.h>
#import <signal.h>
#import <sys/stat.h>

@implementation KKRenderCache
- (instancetype)init {
  if ((self = [super init])) {
    _lastPushedClipDuration = -1.0;
    _lastPushedClipProjectStart = -999.0; // sentinel: force first push
    _frameDurSec = 1.0 / 60.0;
  }
  return self;
}
- (double)clipFractionAtSeconds:(double)sec {
  if (_effectDurSec <= 0.0)
    return 0.0;
  return MAX(0.0, MIN(1.0, (sec - _effectStartSec) / _effectDurSec));
}
@end

@interface KKMiniRequestFileCacheEntry : NSObject
@property(nonatomic) struct timespec modified;
@property(nonatomic) off_t size;
@property(nonatomic, copy) NSDictionary *json;
@end

@implementation KKMiniRequestFileCacheEntry
@end

// scheduleInputs can run once per OSC drag tick. The boundary helper and the
// viewer-active helper both consume the same tiny cross-process JSON file; do
// one stat and only touch/read/parse the file when the writer actually replaced
// it. Nanosecond mtime + size preserves immediate popover open/close changes.
static NSDictionary *KKReadMiniViewerRequestJSON(NSString *path) {
  if (path.length == 0)
    return nil;
  struct stat info;
  if (stat(path.fileSystemRepresentation, &info) != 0)
    return nil;
  static NSMutableDictionary<NSString *, KKMiniRequestFileCacheEntry *>
      *cache;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    cache = [NSMutableDictionary dictionary];
  });
  @synchronized(cache) {
    KKMiniRequestFileCacheEntry *entry = cache[path];
    if (entry && entry.size == info.st_size &&
        entry.modified.tv_sec == info.st_mtimespec.tv_sec &&
        entry.modified.tv_nsec == info.st_mtimespec.tv_nsec)
      return entry.json;
  }
  NSData *data = [NSData dataWithContentsOfFile:path];
  NSDictionary *json =
      data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
           : nil;
  if (![json isKindOfClass:NSDictionary.class])
    json = nil;
  KKMiniRequestFileCacheEntry *fresh = [KKMiniRequestFileCacheEntry new];
  fresh.modified = info.st_mtimespec;
  fresh.size = info.st_size;
  fresh.json = json;
  @synchronized(cache) {
    cache[path] = fresh;
  }
  return json;
}

NSArray<NSNumber *> *KKReadBoundaryRequestFracs(NSString *path) {
  if (path.length == 0)
    return nil;
  NSDictionary *j = KKReadMiniViewerRequestJSON(path);
  if (![j isKindOfClass:[NSDictionary class]] || ![j[@"active"] boolValue])
    return nil;
  NSArray *fracs = j[@"fracs"];
  if ([fracs isKindOfClass:[NSArray class]] && fracs.count > 0)
    return fracs;
  NSNumber *frac = j[@"frac"];
  if (frac)
    return @[ frac ];
  return nil;
}

BOOL KKReadMiniViewerFeedActive(NSString *path) {
  if (path.length == 0)
    return NO;
  NSDictionary *json = KKReadMiniViewerRequestJSON(path);
  if (![json isKindOfClass:[NSDictionary class]] ||
      ![json[@"viewerActive"] boolValue])
    return NO;
  pid_t pid = (pid_t)[json[@"viewerProcessID"] intValue];
  if (pid <= 0)
    return NO;
  return kill(pid, 0) == 0 || errno == EPERM;
}

static KKTimeline *sProcessTimelineSnapshot = nil;
static double sProcessFrameDurSec = 1.0 / 60.0;

void KKSetProcessTimelineSnapshot(KKTimeline *timeline) {
  sProcessTimelineSnapshot = timeline;
}

KKTimeline *KKProcessTimelineSnapshot(void) { return sProcessTimelineSnapshot; }

void KKSetProcessFrameDurationSeconds(double frameDurSec) {
  if (frameDurSec > 0.0)
    sProcessFrameDurSec = frameDurSec;
}

double KKProcessFrameDurationSeconds(void) { return sProcessFrameDurSec; }

// Host parameter callbacks can arrive much faster than the inspector can
// project a full timeline into all of its Basic / Advanced / detached views.
// Keep rendering and the process snapshot per-event, but make the decorative
// inspector projection latest-state-wins at 30 Hz. Without this, an OSC drag
// queues hundreds of full AppKit refreshes on the same main queue that must
// receive the next OSC mouse event, producing large periodic stalls.
@interface KKTimelineApplyCoalescer : NSObject
@property(nonatomic, strong) KKTimeline *latest;
@property(nonatomic) BOOL scheduled;
@end

@implementation KKTimelineApplyCoalescer
@end

static const void *kKKTimelineApplyCoalescerKey =
    &kKKTimelineApplyCoalescerKey;

static void KKScheduleInspectorTimelineApply(KKTimelineInspectorView *view,
                                             KKTimeline *timeline) {
  if (!view || !timeline)
    return;
  @synchronized(view) {
    KKTimelineApplyCoalescer *coalescer =
        objc_getAssociatedObject(view, kKKTimelineApplyCoalescerKey);
    if (!coalescer) {
      coalescer = [KKTimelineApplyCoalescer new];
      objc_setAssociatedObject(view, kKKTimelineApplyCoalescerKey, coalescer,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    coalescer.latest = timeline;
    if (coalescer.scheduled)
      return;
    coalescer.scheduled = YES;
  }

  __weak KKTimelineInspectorView *weakView = view;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 30)),
      dispatch_get_main_queue(), ^{
        KKTimelineInspectorView *strongView = weakView;
        if (!strongView)
          return;
        KKTimeline *latest = nil;
        @synchronized(strongView) {
          KKTimelineApplyCoalescer *coalescer = objc_getAssociatedObject(
              strongView, kKKTimelineApplyCoalescerKey);
          latest = coalescer.latest;
          coalescer.latest = nil;
          coalescer.scheduled = NO;
        }
        if (latest)
          [strongView applyTimeline:latest];
      });
}

void KKHandleTimelineParamChanged(id<PROAPIAccessing> apiManager,
                                  UInt32 timelineParamID,
                                  KKTimeline * (^timelineStamper)(KKTimeline *),
                                  KKMiniViewerRenderer *miniViewerRenderer,
                                  KKTimelineInspectorView *inspectorView) {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;
  NSString *json = KKReadCustomParamString(getAPI, timelineParamID);
  KKTimeline *timeline =
      (json.length ? [KKTimeline timelineFromJSON:json] : nil)
          ?: [KKTimeline timeline];
  if (timelineStamper)
    timeline = timelineStamper(timeline) ?: timeline;
  KKSetProcessTimelineSnapshot(timeline);

  miniViewerRenderer.timeline = timeline;
  KKScheduleInspectorTimelineApply(inspectorView, timeline);
}

NSArray *KKBuildSourceRequests(CMTime renderTime, NSString *boundaryRequestPath,
                               KKRenderCache *cache,
                               id (^requestBuilder)(CMTime t)) {
  NSMutableArray *reqs = [NSMutableArray array];
  id cur = requestBuilder(renderTime);
  if (cur)
    [reqs addObject:cur];

  // No motion-blur sub-frame source requests: built-in plugins blur their own
  // animation over a single source frame (see the header). A footage-smear
  // effect would call +[KKMotionBlur appendSourceRequestsForState:...] itself.

  BOOL viewerActive = KKReadMiniViewerFeedActive(boundaryRequestPath);
  cache.miniViewerFeedActive = viewerActive;
  NSArray<NSNumber *> *fracs =
      viewerActive ? KKReadBoundaryRequestFracs(boundaryRequestPath) : nil;
  BOOL boundaryActive = fracs.count > 0;
  cache.boundaryFeedActive = boundaryActive;
  if (boundaryActive) {
    // FxTimingAPI returns 0 inside scheduleInputs; map fractions to seconds
    // using the cached start/duration from the render path.
    double es = cache.effectStartSec;
    double ed = cache.effectDurSec;
    NSMutableArray<NSNumber *> *reqSecs =
        [NSMutableArray arrayWithCapacity:fracs.count];
    if (ed > 0) {
      for (NSNumber *f in fracs) {
        double sec = es + f.doubleValue * ed;
        [reqSecs addObject:@(sec)];
        CMTime bt = CMTimeMakeWithSeconds(sec, 600);
        id br = requestBuilder(bt);
        if (br)
          [reqs addObject:br];
      }
    }
    cache.lastBoundaryReqSec =
        reqSecs.count ? reqSecs.firstObject.doubleValue : 0.0;
    cache.boundaryReqSecs = reqSecs;
    cache.boundaryReqFracs = fracs;
  } else {
    cache.boundaryReqSecs = nil;
    cache.boundaryReqFracs = nil;
  }
  return reqs;
}

double KKMaintainTimingRemappedFraction(double clipFrac, KKRenderCache *cache) {
  if (!cache.maintainTimingEnabled || cache.anchorDurSec <= 0 ||
      cache.effectDurSec <= 0)
    return clipFrac;
  // Frame's absolute media time, then back to the authored fraction relative to
  // the anchor's clip span. Source in-point shifts on head-trim and holds on
  // tail-trim, so this single map covers grow/shrink from either edge (and
  // split, where each half is the same media at a different in-point).
  double mediaT = cache.sourceInSec + clipFrac * cache.effectDurSec;
  double f = (mediaT - cache.anchorSrcInSec) / cache.anchorDurSec;
  return MAX(0.0, MIN(1.0, f));
}

void KKRenderCacheApplyUIState(KKRenderCache *cache, NSDictionary *uiState) {
  if (![uiState isKindOfClass:[NSDictionary class]])
    return;
  cache.loopEnabled = [uiState[@"loopEnabled"] boolValue];
  cache.maintainTimingEnabled = [uiState[@"maintainTiming"] boolValue];
  cache.anchorSrcInSec = [uiState[@"maintainAnchorSrcIn"] doubleValue];
  cache.anchorDurSec = [uiState[@"maintainAnchorDur"] doubleValue];
}

BOOL KKRefreshRenderCache(id<PROAPIAccessing> apiManager,
                          KKTimelineInspectorView *inspectorView,
                          KKRenderCache *cache) {
  id<FxTimingAPI_v4> timingAPI =
      [apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return NO;
  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double durSec = CMTimeGetSeconds(effectDuration);
  if (durSec <= 0)
    return NO;

  cache.effectStartSec = CMTimeGetSeconds(effectStart);
  cache.effectDurSec = durSec;
  CMTime srcStart = kCMTimeZero, tlStart = kCMTimeZero;
  [timingAPI startTimeOfInputToFilter:&srcStart];
  cache.sourceInSec = CMTimeGetSeconds(srcStart);
  [timingAPI timelineTime:&tlStart fromInputTime:srcStart];
  cache.timelineStartSec = CMTimeGetSeconds(tlStart);
  CMTime frameDur = kCMTimeZero;
  [timingAPI frameDuration:&frameDur];
  double frameDurSec = CMTimeGetSeconds(frameDur);
  cache.frameDurSec = frameDurSec;
  KKSetProcessFrameDurationSeconds(frameDurSec);

  // Push clip-duration on change so popovers re-time. No blob write; no undo
  // entry. The render tick is the only place trims surface.
  if (fabs(durSec - cache.lastPushedClipDuration) > 0.001 && inspectorView) {
    cache.lastPushedClipDuration = durSec;
    KKTimelineInspectorView *iv = inspectorView;
    dispatch_async(dispatch_get_main_queue(), ^{
      [iv setClipDurationSeconds:durSec];
      if (frameDurSec > 0)
        [iv setFrameDurationSeconds:frameDurSec];
    });
  }

  // Push this clip's absolute project-start time (fraction 0 in timeline
  // seconds) so the inspector can feed-lock parameter-link resolution in the
  // mini-viewer. Uses timelineTime(effectStart) - the effect's own start mapped
  // to the timeline, NOT the source-in-based timelineStartSec above. Generic
  // for every plugin (the inspector + mini renderer base handle the rest), so a
  // new plugin gets linked-clip playback parity for free with no per-plugin
  // wiring.
  CMTime effStartTL = kCMTimeZero;
  [timingAPI timelineTime:&effStartTL
            fromInputTime:CMTimeMakeWithSeconds(cache.effectStartSec, 600)];
  double clipProjectStart = CMTimeGetSeconds(effStartTL);
  cache.clipProjectStartSec = clipProjectStart;
  if (fabs(clipProjectStart - cache.lastPushedClipProjectStart) > 0.0005 &&
      inspectorView) {
    cache.lastPushedClipProjectStart = clipProjectStart;
    KKTimelineInspectorView *iv = inspectorView;
    dispatch_async(dispatch_get_main_queue(), ^{
      [iv setClipProjectStartSec:clipProjectStart];
    });
  }

  // NB: the FCP document (project) id is resolved during render
  // (KKLinkWriteManifest stamps each manifest with it, sticky per uuid). We do
  // NOT push it to the inspector from here: this runs in the RENDER process
  // where `inspectorView` is nil, so the call wouldn't cross to the
  // ViewBridge-hosted popover. The view side reads the id back off its own
  // manifest instead (KKTimelineLanesView linkSelfUUID -> KKLinkBus).
  return YES;
}
