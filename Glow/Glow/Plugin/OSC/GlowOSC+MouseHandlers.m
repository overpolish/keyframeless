/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "GlowOSCRadiusMath.h"
#import "OSC_Internal.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KeyframelessKit.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

@implementation GlowOSC (MouseHandlers)

// Hover carries the modifier bit reliably: track opt-reveal here (and reset the
// per-press opt-hide arming). Shared machinery on KKOnScreenControl.
- (void)mouseMovedAtPositionX:(double)positionX
                    positionY:(double)positionY
                   activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers
                  forceUpdate:(BOOL *)forceUpdate
                       atTime:(CMTime)time {
  [self kkUpdateOptRevealWithModifiers:modifiers forceUpdate:forceUpdate];
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Opt-click an on-screen control to hide it (shared machinery on
  // KKOnScreenControl). Bails before any drag routing.
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers]) {
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  if (activePart != kOSCRadiusPart)
    return;

  _ringDragging = YES;
  CGPoint center = [self canvasCenter];
  _ringDragStartDx = positionX - center.x;
  _ringDragStartDy = positionY - center.y;
  _ringDragStartDist = sqrt(_ringDragStartDx * _ringDragStartDx +
                            _ringDragStartDy * _ringDragStartDy);

  NSArray<NSNumber *> *v =
      GlowOSCRadiusValuesAtFraction([self fractionAtTime:time]);
  _ringDragStartValX = v[0].doubleValue;
  _ringDragStartValY = v.count > 1 ? v[1].doubleValue : _ringDragStartValX;

  [self.radiusRing updateCursorForMouseX:positionX positionY:positionY];

  // OSC guide: grabbing the real viewer ring advances the drag step (the guide
  // panel's spotlight passes the press through to FCP, so this is where the
  // user's drag of the actual handle is seen).
  if (GlowSharedOSCGuideBridge().guideStep == 1)
    GlowSharedOSCGuideBridge().guideStep = 2;

  if (forceUpdate)
    *forceUpdate = YES;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  // First drag tick decides: opt held => hide-click (handled, no drag).
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers]) {
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  if (activePart != kOSCRadiusPart || !_ringDragging || _ringDragStartDist <= 0)
    return;

  CGPoint center = [self canvasCenter];
  double dx = positionX - center.x;
  double dy = positionY - center.y;

  // Link is global per-lane; Shift temporarily inverts it for this drag (same
  // semantics as the scale bounding-box OSC).
  BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
  BOOL effLinked = GlowOSCRadiusAspectLinked() ^ shift;

  // Invert the ring's radius mapping (R = minDim * 0.012 * sqrt(val)) so the
  // ring edge tracks the cursor 1:1 (sticks to the mouse, like the box OSC)
  // rather than lagging behind a distance ratio.
  double c = [self canvasMinDimension] * 0.012;
  if (c <= 0.0)
    c = 1.0;

  double newX, newY;
  if (effLinked) {
    // Uniform: the ring edge follows the cursor's radial distance.
    double r = sqrt(dx * dx + dy * dy) / c;
    newX = newY = CLAMP(r * r, 0.0, 500.0);
  } else {
    // Per-axis: each radius follows its own cursor component, so a horizontal
    // drag grows X and a vertical drag grows Y. An axis grabbed near its
    // cardinal (start component small vs the grab radius) is held, like a box
    // edge handle. The threshold is proportional so it behaves the same at any
    // ring size.
    static const double kCardinalFrac = 0.25;
    double minComp = kCardinalFrac * _ringDragStartDist;
    double rx = fabs(dx) / c, ry = fabs(dy) / c;
    newX = (fabs(_ringDragStartDx) > minComp) ? CLAMP(rx * rx, 0.0, 500.0)
                                              : _ringDragStartValX;
    newY = (fabs(_ringDragStartDy) > minComp) ? CLAMP(ry * ry, 0.0, 500.0)
                                              : _ringDragStartValY;
  }

  // OSC guide: snap a linked drag onto the glowing target when close, so the
  // user lands the ring exactly (mirrors the strategy's snapValue).
  if (GlowSharedOSCGuideBridge().guideStep == 2 && effLinked &&
      fabs(newX - kGlowOSCGuideTargetRadius) < 30.0)
    newX = newY = kGlowOSCGuideTargetRadius;

  [self.radiusRing updateCursorForMouseX:positionX positionY:positionY];
  [self _writeRadiusValues:@[ @(newX), @(newY) ]
                    atTime:time
               forceUpdate:forceUpdate];
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self kkResetOptHideArming];
  BOOL wasDragging = _ringDragging;
  _ringDragging = NO;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:[NSCursor arrowCursor]];

  // OSC guide: releasing the real ring after a drag completes the drag step
  // (the segment's observer advances the joyride when guideStep hits 3).
  if (wasDragging && GlowSharedOSCGuideBridge().guideStep == 2)
    GlowSharedOSCGuideBridge().guideStep = 3;

  if (forceUpdate)
    *forceUpdate = NO;
}

// Set the Radius keypose nearest the playhead, preserving In/Hold/Out structure
// + hold-links (see KKTimelineSettingValuesNearestFraction). The blob is read
// from the parameterChanged-driven snapshot - KKReadCustomParamString returns
// empty for kKKParamTimelineData inside the OSC mouse-drag action scope.
- (void)_writeRadiusValues:(NSArray<NSNumber *> *)newValues
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
                              snap, @"Radius", frac, newValues)
                        : nil;
  if (!tl) {
    // No snapshot, or no Radius lane yet: seed one keypose at t=0, mirroring
    // availableLanes (aspect-linked px).
    tl = snap ? [snap copy] : [KKTimeline timeline];
    NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    KKLane *radiusLane = [KKLane laneWithLabel:@"Radius"];
    radiusLane.valueType = KKLaneValueTypeFloat;
    radiusLane.componentMin = @[ @0.0, @0.0 ];
    radiusLane.componentMax = @[ @500.0, @500.0 ];
    radiusLane.componentUnits = @[ @"px", @"px" ];
    radiusLane.componentLabels = @[ @"X", @"Y" ];
    radiusLane.aspectLinkable = YES;
    radiusLane.aspectLinked = YES;
    radiusLane.enabled = NO;
    radiusLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:radiusLane];
    tl.lanes = lanes;
  }

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
    *forceUpdate = YES;
}

@end
