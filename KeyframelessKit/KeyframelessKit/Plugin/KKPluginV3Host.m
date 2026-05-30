/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPluginV3Host.h"
#import "../Views/KKMiniCanvasRenderer.h"
#import "../Views/KKTimelineInspectorView.h"
#import "KKDataBlob.h"
#import <FxPlug/FxPlugSDK.h>

@implementation KKV3RenderCache
- (instancetype)init {
  if ((self = [super init])) {
    _lastPushedClipDuration = -1.0;
    _frameDurSec = 1.0 / 60.0;
  }
  return self;
}
@end

NSArray<NSNumber *> *KKReadBoundaryRequestFracs(NSString *path) {
  if (path.length == 0)
    return nil;
  NSData *d = [NSData dataWithContentsOfFile:path];
  if (!d)
    return nil;
  NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d
                                                    options:0
                                                      error:nil];
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

void KKHandleTimelineParamChanged(id<PROAPIAccessing> apiManager,
                                  UInt32 timelineParamID,
                                  NSObject *actionTarget,
                                  KKTimeline * (^timelineStamper)(KKTimeline *),
                                  KKMiniCanvasRenderer *miniCanvasRenderer,
                                  KKTimelineInspectorView *inspectorView) {
  id<FxCustomParameterActionAPI_v4> act =
      [apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!act)
    return;
  [act startAction:actionTarget];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *json = KKReadCustomParamString(getAPI, timelineParamID);
  KKTimeline *timeline =
      (json.length ? [KKTimeline timelineFromJSON:json] : nil)
          ?: [KKTimeline timeline];
  if (timelineStamper)
    timeline = timelineStamper(timeline) ?: timeline;
  KKSetProcessTimelineSnapshot(timeline);
  [act endAction:actionTarget];

  miniCanvasRenderer.timeline = timeline;
  if (inspectorView) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [inspectorView applyTimeline:timeline];
    });
  }
}

NSArray *KKBuildV3SourceRequests(CMTime renderTime, KKMotionBlurState mbState,
                                 NSString *boundaryRequestPath,
                                 KKV3RenderCache *cache,
                                 id (^requestBuilder)(CMTime t)) {
  NSMutableArray *reqs = [NSMutableArray array];
  id cur = requestBuilder(renderTime);
  if (cur)
    [reqs addObject:cur];

  if (mbState.enabled) {
    [KKMotionBlur appendSourceRequestsForState:mbState
                                    renderTime:renderTime
                                            to:reqs
                                       builder:requestBuilder];
  }

  NSArray<NSNumber *> *fracs = KKReadBoundaryRequestFracs(boundaryRequestPath);
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

BOOL KKRefreshV3RenderCache(id<PROAPIAccessing> apiManager,
                            KKTimelineInspectorView *inspectorView,
                            KKV3RenderCache *cache) {
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
  return YES;
}
