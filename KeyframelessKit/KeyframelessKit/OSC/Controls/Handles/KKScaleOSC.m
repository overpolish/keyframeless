/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKScaleOSC.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Scale drag is absolute: the grabbed handle tracks the cursor (deterministic,
// in sync), mapping cursor distance to centre back through the gizmo curve.
// Holding Cmd engages a fine mode that scales cursor movement down for precise
// adjustment (essential at high scale, where the compressed box is otherwise
// hyper-sensitive).
static const double kScaleFineFactor = 0.2;

@interface KKScaleOSC ()
@property(nonatomic, readwrite) KKBoxOSC *box;
// Last hit-tested handle (-1 none) and the one currently grabbed for a drag.
@property(nonatomic) NSInteger scaleHitHandle;
@property(nonatomic) NSInteger scaleGrabHandle;
// Press state captured at mouseDown: the box centre (= Position) and the scale
// percents, so the drag preserves ratio / inverts the gizmo curve from a known
// baseline. The effective cursor starts at the grabbed handle and advances by
// the raw cursor delta (scaled down while Cmd-fine is held).
@property(nonatomic) CGPoint scalePressCenter;
@property(nonatomic) double scalePressSclX;
@property(nonatomic) double scalePressSclY;
@property(nonatomic) CGPoint scaleEffCursor;
@property(nonatomic) CGPoint scaleLastCursor;
@end

@implementation KKScaleOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         laneLabel:(NSString *)laneLabel {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _laneLabel = [laneLabel copy];
    _scaleActivePart = 4;
    _scaleHitHandle = -1;
    _scaleGrabHandle = -1;
    // The box is composed under a host OSC that clears the destination once at
    // the start of its drawOSC tick, so it must not clear again.
    self.clearsOnDraw = NO;
    _box = [[KKBoxOSC alloc] initWithAPIManager:apiManager];
    _box.hitPadding = 6.0;
  }
  return self;
}

- (nullable KKLane *)_scaleLane {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:self.laneLabel])
      return lane;
  return nil;
}

// Aspect-link for a drag: the live snapshot lane if present, else the template.
// The viewer's snapshot is normally seeded so the live lane wins, but a host
// with a sparse snapshot (no Scale lane - e.g. an untouched default constant)
// would otherwise read 0/unlinked. Mirrors KKScaleMiniController.
- (BOOL)_aspectLinked {
  KKLane *lane = [self _scaleLane];
  return (lane ? lane.aspectLinked : self.templateLane.aspectLinked) != 0;
}

- (BOOL)_scaleVisibleAtFraction:(double)frac {
  return KKLaneVisibleAtFraction([self _scaleLane], frac,
                                 KKProcessFrameDurationSeconds());
}

// (scaleX, scaleY) in PERCENT (100 = identity). Floored at 0 so overshoot
// easing never shows the box / readout a negative (flipped) scale.
- (NSArray<NSNumber *> *)_scaleValuesAtFraction:(double)frac {
  KKLane *lane = [self _scaleLane];
  if (!lane)
    return @[ @100.0, @100.0 ];
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithArray:v ?: @[]];
  while (out.count < 2)
    [out addObject:@100.0];
  out[0] = @(fmax(0.0, out[0].doubleValue));
  out[1] = @(fmax(0.0, out[1].doubleValue));
  return out;
}

- (void)_e0:(double *)outE0 span:(double *)outSpan {
  *outE0 = self.frameMin * KKScaleGizmoE0Frac;
  *outSpan = self.frameMin * KKScaleGizmoSpanFrac;
}

- (void)drawInDestination:(FxImageTile *)destinationImage
                   atTime:(CMTime)time
               activePart:(NSInteger)activePart {
  double frac = [self fractionAtTime:time];
  // On screen where the Scale lane is visible (keypose times / constant), same
  // as the other transform controls. Opt-hold reveals a hidden box as a ghost.
  BOOL scaleShownHere = [self _scaleVisibleAtFraction:frac];
  BOOL scaleEnabled = [self kkOSCElementVisible:self.laneLabel];
  BOOL scaleDragging = self.dragging && activePart == self.scaleActivePart;
  BOOL scaleVisible = scaleDragging || (scaleEnabled && scaleShownHere);
  BOOL scaleGhost = !scaleVisible && self.optRevealActive &&
                    [self kkOSCRevealEligible:self.laneLabel] && scaleShownHere;
  if (!scaleVisible && !scaleGhost)
    return;

  NSArray<NSNumber *> *sv = [self _scaleValuesAtFraction:frac];
  double sclX = sv.count > 0 ? sv[0].doubleValue : 100.0;
  double sclY = sv.count > 1 ? sv[1].doubleValue : 100.0;
  double e0 = 0, span = 0;
  [self _e0:&e0 span:&span];
  CGPoint handles[8];
  KKScaleHandlePositions(self.center, sclX, sclY, e0, span, handles);

  self.box.ghostAlpha = scaleGhost ? [self kkRevealGhostAlpha] : 1.0f;
  NSInteger activeHandle = scaleDragging ? self.scaleGrabHandle : -1;
  NSString *readout =
      [NSString stringWithFormat:@"%.0f%% x %.0f%%", sclX, sclY];
  [self.box drawWithTopRight:handles[2]
                  bottomLeft:handles[0]
                     readout:readout
                activeHandle:activeHandle
            destinationImage:destinationImage
                      atTime:time];
}

- (NSInteger)hitTestHandleAtX:(double)x y:(double)y atTime:(CMTime)time {
  double frac = [self fractionAtTime:time];
  self.scaleHitHandle = -1;
  // Reachable only where the box is shown (or opt-reveal exposes a hidden one).
  BOOL reachable =
      ([self kkOSCElementVisible:self.laneLabel] ||
       (self.optRevealActive && [self kkOSCRevealEligible:self.laneLabel])) &&
      [self _scaleVisibleAtFraction:frac];
  if (!reachable)
    return -1;
  // Opt-hover hide/show affordance on the handles (eye/eye.slash when an
  // Opt-click would toggle the box, i.e. master on - not peek mode).
  BOOL toggle = self.optRevealActive && ![self kkOSCMasterOff];
  BOOL revealOnly = ![self kkOSCElementVisible:self.laneLabel] &&
                    self.optRevealActive &&
                    [self kkOSCRevealEligible:self.laneLabel];
  self.box.visibilityHint = toggle ? (revealOnly ? 2 : 1) : 0;

  NSArray<NSNumber *> *sv = [self _scaleValuesAtFraction:frac];
  double sclX = sv.count > 0 ? sv[0].doubleValue : 100.0;
  double sclY = sv.count > 1 ? sv[1].doubleValue : 100.0;
  double e0 = 0, span = 0;
  [self _e0:&e0 span:&span];
  CGPoint handles[8];
  KKScaleHandlePositions(self.center, sclX, sclY, e0, span, handles);
  NSInteger part = [self.box hitTestAtX:x
                                      y:y
                               topRight:handles[2]
                             bottomLeft:handles[0]];
  self.scaleHitHandle =
      part >= KKBoxPartHandleBase ? part - KKBoxPartHandleBase : -1;
  return self.scaleHitHandle;
}

- (void)mouseDownAtX:(double)x
                   y:(double)y
           modifiers:(NSUInteger)modifiers
         forceUpdate:(BOOL *)forceUpdate
              atTime:(CMTime)time {
  self.scaleGrabHandle = self.scaleHitHandle;
  self.scalePressCenter = self.center;
  NSArray<NSNumber *> *sv =
      [self _scaleValuesAtFraction:[self fractionAtTime:time]];
  self.scalePressSclX = sv.count > 0 ? sv[0].doubleValue : 100.0;
  self.scalePressSclY = sv.count > 1 ? sv[1].doubleValue : 100.0;
  // Effective cursor starts at the grabbed handle (not the raw click point), so
  // the value begins exactly where it is - no press snap.
  double e0 = 0, span = 0;
  [self _e0:&e0 span:&span];
  CGPoint hp[8];
  KKScaleHandlePositions(self.scalePressCenter, self.scalePressSclX,
                         self.scalePressSclY, e0, span, hp);
  self.scaleEffCursor = (self.scaleGrabHandle >= 0 && self.scaleGrabHandle < 8)
                            ? hp[self.scaleGrabHandle]
                            : CGPointMake(x, y);
  self.scaleLastCursor = CGPointMake(x, y);
}

- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(NSUInteger)modifiers
            forceUpdate:(BOOL *)forceUpdate
                 atTime:(CMTime)time {
  NSInteger h = self.scaleGrabHandle;
  if (h < 0)
    return;
  // Advance the effective cursor by the raw movement (scaled down for
  // Cmd-fine). The value comes from its distance to centre through the gizmo
  // curve, so the grabbed handle tracks the cursor 1:1 in normal mode.
  double rawDx = x - self.scaleLastCursor.x;
  double rawDy = y - self.scaleLastCursor.y;
  self.scaleLastCursor = CGPointMake(x, y);
  double fine = (modifiers & kFxModifierKey_COMMAND) ? kScaleFineFactor : 1.0;
  CGPoint eff = self.scaleEffCursor;
  eff.x += rawDx * fine;
  eff.y += rawDy * fine;
  self.scaleEffCursor = eff;

  CGPoint c = self.scalePressCenter;
  double pX = self.scalePressSclX, pY = self.scalePressSclY;
  double e0 = 0, span = 0;
  [self _e0:&e0 span:&span];
  // Candidate per-axis percents from the effective cursor's distance to centre.
  double tX = KKScaleGizmoPercentForExtent(fabs(eff.x - c.x), e0, span);
  double tY = KKScaleGizmoPercentForExtent(fabs(eff.y - c.y), e0, span);
  // Link is global per-lane; Shift temporarily inverts it for this drag. The
  // corner/edge coupling itself is the shared kit rule.
  BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
  BOOL effLinked = [self _aspectLinked] ^ shift;
  double newX = 0, newY = 0;
  KKScaleValuesForHandleDrag(h, pX, pY, tX, tY, effLinked, &newX, &newY);
  [self _writeScaleValues:@[ @(newX), @(newY) ]
                   atTime:time
              forceUpdate:forceUpdate];
}

- (void)_writeScaleValues:(NSArray<NSNumber *> *)newValues
                   atTime:(CMTime)time
              forceUpdate:(BOOL *)forceUpdate {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    [actionAPI endAction:self];
    return;
  }

  double frac = [self fractionAtTime:time];
  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? KKTimelineSettingValuesNearestFraction(
                              snap, self.laneLabel, frac, newValues)
                        : nil;
  if (!tl) {
    tl = snap ? [snap copy] : [KKTimeline timeline];
    NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    KKLane *scaleLane =
        [self.templateLane copy] ?: [KKLane laneWithLabel:self.laneLabel];
    scaleLane.enabled = NO;
    scaleLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:scaleLane];
    tl.lanes = lanes;
  }

  if (self.onTimelinePersist)
    self.onTimelinePersist(tl);
  else
    KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                             kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
    *forceUpdate = YES;
}

- (void)mouseUp {
  self.scaleGrabHandle = -1;
}

- (NSArray<NSString *> *)oscElementKeys {
  return @[ self.laneLabel ];
}

@end
