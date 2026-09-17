/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFEffect.h"
#import "KFOSCPlayheadNudge.h"

NSNotificationName const KFInspectorPresentationChanged = @"KFInspectorPresentationChanged";

@interface KFEffect ()
@property(nonatomic, strong) KFInspectorClock *sharedInspectorClock;
@property(nonatomic, strong) KFOSCPlayheadNudge *playheadNudge;
// Relative precision of the measurement inspectorImageSize currently holds.
@property(atomic) double inspectorImageSizeTolerance;
@property(nonatomic, strong) NSTimer *hostTickTimer;
@end

@implementation KFEffect

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)manager {
  if ((self = [super init])) _apiManager = manager;
  return self;
}

- (void)pluginInstanceAddedToDocument {}

- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error { return YES; }

- (void)publishInspectorImageSize:(CGSize)size measuredFrom:(CGSize)deliveredPixels {
  if (size.width <= 0 || size.height <= 0 || deliveredPixels.width <= 0 ||
      deliveredPixels.height <= 0)
    return;
  // The host rounds the bounds it hands over to whole pixels, so scaling them
  // back up can misplace each edge by up to a pixel of the delivered scale.
  double tolerance = fmax(2.0 / deliveredPixels.width, 2.0 / deliveredPixels.height);
  @synchronized(self) {
    CGSize current = self.inspectorImageSize;
    double held = self.inspectorImageSizeTolerance;
    if (current.width > 0 && current.height > 0) {
      double drift = fmax(fabs(size.width - current.width) / current.width,
                          fabs(size.height - current.height) / current.height);
      // Agrees with what is held, to the precision either measurement has: a
      // coarse preview pass then tells us nothing new and must not displace a
      // full-resolution measurement. Disagreeing by more than that is the
      // project itself changing size, which any pass may report.
      if (drift <= tolerance + held && tolerance >= held) return;
    }
    self.inspectorImageSizeTolerance = tolerance;
    self.inspectorImageSize = size;
  }
}

- (void)dealloc { [_hostTickTimer invalidate]; }

- (void)startHostTicks:(void (^)(id<FxCustomParameterActionAPI_v4> action))tick {
  if (!tick) return;
  __weak KFEffect *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    KFEffect *effect = weakSelf;
    if (!effect || effect.hostTickTimer) return;
    effect.hostTickTimer = [NSTimer timerWithTimeInterval:(1.0/30.0) repeats:YES block:^(NSTimer *timer) {
      KFEffect *ticking = weakSelf;
      if (!ticking) { [timer invalidate]; return; }
      id<FxCustomParameterActionAPI_v4> action =
          [ticking.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!action) return;
      [action startAction:ticking];
      @try { tick(action); }
      @finally { [action endAction:ticking]; }
    }];
    [NSRunLoop.mainRunLoop addTimer:effect.hostTickTimer forMode:NSDefaultRunLoopMode];
  });
}

- (KFInspectorClock *)inspectorClock {
  if (!self.sharedInspectorClock) {
    self.sharedInspectorClock = [[KFInspectorClock alloc] initWithManager:self.apiManager];
    // The viewer's controls hide themselves while the playhead moves and
    // cannot ask for the redraw that brings them back; this tick is where that
    // redraw is requested. It rides the clock the inspector already runs.
    self.playheadNudge = [[KFOSCPlayheadNudge alloc] initWithManager:self.apiManager
                                               visibilityParameters:self.onScreenControlVisibilityParameters];
    KFOSCPlayheadNudge *nudge = self.playheadNudge;
    self.sharedInspectorClock.onTick = ^(id<FxCustomParameterActionAPI_v4> action) {
      [nudge tickInAction:action];
    };
  }
  return self.sharedInspectorClock;
}
@end
