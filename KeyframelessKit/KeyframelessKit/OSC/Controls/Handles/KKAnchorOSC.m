/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKAnchorOSC.h"
#import "KKResizeCursor.h"
#import "KKSnapEngine.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

@interface KKAnchorOSC ()
@property(nonatomic, readwrite) KKSquarePointOSC *square;
@property(nonatomic, readwrite) double evalFraction;
@property(nonatomic) KKSnapEngine *snap;
@property(nonatomic) BOOL hovered;
// Press state for the delta drag: the anchor value of the grabbed keypose and
// the anchor value under the cursor at mouseDown. The drag moves the value by
// the cursor's offset in anchor space from that press point.
@property(nonatomic) double grabValX;
@property(nonatomic) double grabValY;
@property(nonatomic) double pressAnchorX;
@property(nonatomic) double pressAnchorY;
@end

@implementation KKAnchorOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         laneLabel:(NSString *)laneLabel {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _laneLabel = [laneLabel copy];
    _positionLaneLabel = @"Position";
    _anchorActivePart = 5;
    // Composed under a host OSC that clears the destination once at the start of
    // its drawOSC tick, so it must not clear again.
    self.clearsOnDraw = NO;
    _square = [[KKSquarePointOSC alloc] initWithAPIManager:apiManager];
    _square.clearsOnDraw = NO;
    _snap = [[KKSnapEngine alloc] init];
    _parentObjectTransform = matrix_identity_float3x3;
  }
  return self;
}

- (nullable KKLane *)_anchorLane {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:self.laneLabel])
      return lane;
  return nil;
}

- (BOOL)_anchorVisibleAtFraction:(double)frac {
  return KKLaneVisibleAtFraction([self _anchorLane], frac,
                                 KKProcessFrameDurationSeconds());
}

// (anchorX, anchorY) in normalized content space (0.5,0.5 = centre), defaulting
// to centre when the lane is absent or present-but-empty (an untouched Anchor on
// a cold-boot snapshot - without the keypose-count guard the evaluator returns
// [0,0] and the square jumps to the corner).
- (NSArray<NSNumber *> *)_anchorValuesAtFraction:(double)frac {
  KKLane *lane = [self _anchorLane];
  if (!lane || lane.keyposes.count == 0)
    return @[ @0.5, @0.5 ];
  NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
  return v.count >= 2 ? v : @[ @0.5, @0.5 ];
}

// The sibling content-centre lane (Position) at `frac`, default centre. Used by
// the default clip-space pivot geometry.
- (NSArray<NSNumber *> *)_positionValuesAtFraction:(double)frac {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:self.positionLaneLabel]) {
      NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
      return v.count >= 2 ? v : @[ @0.5, @0.5 ];
    }
  return @[ @0.5, @0.5 ];
}

// Anchor value -> canvas pivot point. Host override wins; else the default
// clip-space pivot: content centre (sibling Position) + Anchor offset, mapped
// OBJECT -> CANVAS through the OSC API.
- (CGPoint)_anchorToCanvasX:(double)ax y:(double)ay {
  if (self.anchorToCanvas)
    return self.anchorToCanvas(ax, ay);
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  NSArray<NSNumber *> *pv = [self _positionValuesAtFraction:self.evalFraction];
  // Pivot in the anchor's own clip space, then through the parent transform.
  simd_float3 p = simd_mul(
      self.parentObjectTransform,
      simd_make_float3((float)(pv[0].doubleValue + ax - 0.5),
                       (float)(pv[1].doubleValue + ay - 0.5), 1.0f));
  double objX = (p.z != 0.0f) ? p.x / p.z : p.x;
  double objY = (p.z != 0.0f) ? p.y / p.z : p.y;
  CGPoint c = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:objX
                          fromY:objY
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c.x
                            toY:&c.y];
  return c;
}

// Inverse: canvas point -> anchor value (host override wins; else default).
- (void)_canvasToAnchor:(CGPoint)p outAX:(double *)outAX outAY:(double *)outAY {
  if (self.canvasToAnchor) {
    self.canvasToAnchor(p, outAX, outAY);
    return;
  }
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double qx = 0.0, qy = 0.0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:p.x
                          fromY:p.y
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&qx
                            toY:&qy];
  // Map the cursor back through the parent transform into the anchor's own clip
  // space, so a drag follows the cursor under a rotated/scaled parent.
  simd_float3 l = simd_mul(simd_inverse(self.parentObjectTransform),
                           simd_make_float3((float)qx, (float)qy, 1.0f));
  double objX = (l.z != 0.0f) ? l.x / l.z : l.x;
  double objY = (l.z != 0.0f) ? l.y / l.z : l.y;
  NSArray<NSNumber *> *pv = [self _positionValuesAtFraction:self.evalFraction];
  if (outAX)
    *outAX = objX - pv[0].doubleValue + 0.5;
  if (outAY)
    *outAY = objY - pv[1].doubleValue + 0.5;
}

- (void)drawInDestination:(FxImageTile *)destinationImage
                   atTime:(CMTime)time
               activePart:(NSInteger)activePart {
  double frac = [self fractionAtTime:time];
  self.evalFraction = frac;
  // Shown where the Anchor lane is visible (keypose times / constant), same as
  // the other transform controls; opt-hold reveals a hidden one as a ghost.
  BOOL shownHere = [self _anchorVisibleAtFraction:frac];
  BOOL enabled = [self kkOSCElementVisible:self.laneLabel];
  BOOL anchorDragging = self.dragging && activePart == self.anchorActivePart;
  BOOL visible = anchorDragging || (enabled && shownHere);
  BOOL ghost = !visible && self.optRevealActive &&
               [self kkOSCRevealEligible:self.laneLabel] && shownHere;
  if (!visible && !ghost)
    return;

  NSArray<NSNumber *> *av = [self _anchorValuesAtFraction:frac];
  CGPoint pivot = [self _anchorToCanvasX:av[0].doubleValue y:av[1].doubleValue];
  self.square.ghostAlpha = ghost ? [self kkRevealGhostAlpha] : 1.0f;
  [self.square drawAtCanvasPosition:pivot
                          isHovered:self.hovered
                           isActive:anchorDragging
                   destinationImage:destinationImage
                             atTime:time];

  [self.snap drawSnapGuidesWithOSC:self
                     isObjectSpace:NO
                  destinationImage:destinationImage];
}

- (NSInteger)hitTestAtX:(double)x y:(double)y atTime:(CMTime)time {
  self.hovered = NO;
  double frac = [self fractionAtTime:time];
  self.evalFraction = frac;
  BOOL reachable =
      ([self kkOSCElementVisible:self.laneLabel] ||
       (self.optRevealActive && [self kkOSCRevealEligible:self.laneLabel])) &&
      [self _anchorVisibleAtFraction:frac];
  if (!reachable)
    return -1;

  NSArray<NSNumber *> *av = [self _anchorValuesAtFraction:frac];
  CGPoint pivot = [self _anchorToCanvasX:av[0].doubleValue y:av[1].doubleValue];
  if (hypot(x - pivot.x, y - pivot.y) > [self.square hitRadius])
    return -1;

  self.hovered = YES;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:([self kkVisibilityCursorForLabel:self.laneLabel]
                         ?: KKPointMoveCursor())];
  return self.anchorActivePart;
}

- (void)mouseDownAtX:(double)x
                   y:(double)y
           modifiers:(NSUInteger)modifiers
         forceUpdate:(BOOL *)forceUpdate
              atTime:(CMTime)time {
  self.evalFraction = [self fractionAtTime:time];
  NSArray<NSNumber *> *av = [self _anchorValuesAtFraction:self.evalFraction];
  self.grabValX = av[0].doubleValue;
  self.grabValY = av[1].doubleValue;
  // The anchor value under the cursor at press, so the drag is a pure delta.
  double pax = 0.5, pay = 0.5;
  [self _canvasToAnchor:CGPointMake(x, y) outAX:&pax outAY:&pay];
  self.pressAnchorX = pax;
  self.pressAnchorY = pay;
  self.hovered = YES;
}

- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(NSUInteger)modifiers
            forceUpdate:(BOOL *)forceUpdate
                 atTime:(CMTime)time {
  self.evalFraction = [self fractionAtTime:time];
  // Delta drag: the anchor value moves by the cursor's offset in anchor space
  // from the grab point (1 anchor unit per content unit), so grabbing off-centre
  // doesn't jump the pivot to the cursor.
  double curAX = 0.5, curAY = 0.5;
  [self _canvasToAnchor:CGPointMake(x, y) outAX:&curAX outAY:&curAY];
  double newX = self.grabValX + (curAX - self.pressAnchorX);
  double newY = self.grabValY + (curAY - self.pressAnchorY);

  // Snap is OFF by default (free, pixel-precise) and engaged by holding Cmd -
  // same as the Position / Rotation OSCs. Snap in CANVAS space against the
  // content's own features (centre / corners / edge-midpoints / thirds) so it
  // works under any host geometry (including rotation) and the guides land on
  // screen, then convert the snapped point back to the anchor value.
  BOOL snapActive = (modifiers & kFxModifierKey_COMMAND) != 0;
  if (snapActive) {
    static const double tg[] = {0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0};
    CGPoint targets[25];
    NSUInteger n = 0;
    for (int i = 0; i < 5; i++)
      for (int j = 0; j < 5; j++)
        targets[n++] = [self _anchorToCanvasX:tg[i] y:tg[j]];
    CGPoint cand = [self _anchorToCanvasX:newX y:newY];
    CGPoint snapped = [self.snap snapCanvasPoint:cand toTargets:targets count:n];
    [self _canvasToAnchor:snapped outAX:&newX outAY:&newY];
  } else {
    [self.snap reset];
  }

  [self _writeAnchorValues:@[ @(newX), @(newY) ]
                    atTime:time
               forceUpdate:forceUpdate];
}

- (void)_writeAnchorValues:(NSArray<NSNumber *> *)newValues
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
    KKLane *anchorLane =
        [self.templateLane copy] ?: [KKLane laneWithLabel:self.laneLabel];
    anchorLane.enabled = NO;
    anchorLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:anchorLane];
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
  [self.snap reset];
}

- (NSArray<NSString *> *)oscElementKeys {
  return @[ self.laneLabel ];
}

@end
