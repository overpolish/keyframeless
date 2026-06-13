/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerRenderer.h"

#import "KKMiniViewerCropEditor.h"
#import "KKResizeCursor.h"
#import <KeyframelessKit/KKRotationOSCMath.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimingStage.h>

// Map a KKMiniViewerCropEditor handle index (0-7: TL, TC, TR, RC, BR, BC, BL,
// LC) to a resize-cursor kind. Mirrors the crop box's corner/edge layout.
static KKResizeCursorKind KKMiniCropResizeKind(NSInteger cropPtIndex) {
  switch (cropPtIndex) {
  case 0: // TopLeft
  case 4: // BottomRight
    return KKResizeCursorDiagonalNWSE;
  case 2: // TopRight
  case 6: // BottomLeft
    return KKResizeCursorDiagonalNESW;
  case 1: // TopCenter
  case 5: // BottomCenter
    return KKResizeCursorVertical;
  default: // RightCenter (3), LeftCenter (7)
    return KKResizeCursorHorizontal;
  }
}

// 28pt at the 230pt mini-viewer baseline (see project_miniviewer_osc_port).
// Matches the viewer arc:ring outer-extent ratio (~9:34 → 9pt mini arc →
// 34pt rings, rounded to 28 as the inactive ring radius).
static const CGFloat kKKRotationBaselineRadiusPt = 28.0;
static const CGFloat kKKRotationBaselineCanvasH = 230.0;
// Threshold scales with radius so a smaller ring stays grabbable and a
// larger one doesn't over-catch. Mirrors the viewer 10px@90 ratio.
static const double kKKRotationHitThresholdRatio = 10.0 / 90.0;
static const int kKKRotationRingSamples = 192;
// Cmd-snap step in radians (15°).
static const double kKKRotationSnapStep = 15.0 * M_PI / 180.0;

@implementation KKMiniViewerRenderer {
  KKMiniViewerCropEditor *_cropEditor;
  // Live-override store: per-label in-flight drag values. Populated by the
  // popover's onHandleValue during a drag, cleared on drag end. Bound to
  // `_liveFraction` so filmstrip/onion neighbour cells (which run the same
  // renderer with a different editFraction during their encode pass) keep
  // their own keypose values - only the active cell sees the override.
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_liveValues;
  double _liveFraction;
  BOOL _hasLiveFraction;
  BOOL _pointGrabbed;
  BOOL _rotationGrabbed;
  // Rotation drag state (set by the default rotation hooks; mirrored on the
  // viewer side by `KKRotationOSC` / MagicMove OSC.m).
  NSInteger _rotActiveAxis; // -1, 0, 1, 2
  double _rotPressAngle;    // ring t at the press point
  double _rotPressTangentX; // Y-DOWN screen-space tangent, unit
  double _rotPressTangentY;
  CGPoint _rotPressMousePt; // overlay y-up
  double _rotPressRx;       // press Euler, radians
  double _rotPressRy;
  double _rotPressRz;
  double _rotLastWrittenRx; // anchor for decompose-near (prev tick)
  double _rotLastWrittenRy;
  double _rotLastWrittenRz;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _cropEditor = [[KKMiniViewerCropEditor alloc] init];
    _currentSlotCount = 1;
    _rotActiveAxis = -1;
  }
  return self;
}

#pragma mark - Subclass vocabulary (defaults)

- (NSString *)cropLabel {
  return @"Crop";
}
- (NSString *)pointLabel {
  return nil;
}
- (NSString *)rotationLabel {
  return nil;
}
- (NSInteger)valueTypeForLabel:(NSString *)label {
  return KKLaneValueTypeFloat;
}
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  return @[ @0 ];
}
- (KKLane *)templateLaneForLabel:(NSString *)label {
  return nil;
}

#pragma mark - Subclass effect + point handle (defaults)

- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  return NO;
}
- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStylePoint;
}
- (CGFloat)pointHandleSizeScale {
  return 1.0;
}
- (BOOL)pointHandleIsActive {
  return _pointGrabbed;
}
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
           forContentRect:(CGRect)contentRect {
  return NO;
}
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)value
           forContentRect:(CGRect)contentRect {
  return NO;
}
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                forValues:(NSArray<NSNumber *> *)values
           forContentRect:(CGRect)contentRect {
  return NO;
}
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)contentRect {
  return NO;
}
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)contentRect
                       canvas:(KKMiniViewerView *)canvas {
}
- (NSInteger)nearestHandleIndexToPoint:(CGPoint)p
                               centers:(const CGPoint *)centers
                                 count:(NSInteger)count
                             tolerance:(CGFloat)tolerance {
  NSInteger best = NSNotFound;
  double bestD = tolerance;
  for (NSInteger i = 0; i < count; i++) {
    double d = hypot(p.x - centers[i].x, p.y - centers[i].y);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}
- (BOOL)rotationIsActive {
  return _rotationGrabbed;
}

// Default precedence is rotation > point (the ring is the larger target). A
// plugin whose point handle draws ON TOP of the rings (e.g. MagicMove's
// Position arc, matching the viewer's layering) overrides this to YES so the
// hit-test / drag / opt-click all prefer the point where they overlap.
- (BOOL)pointHandleBeatsRotation {
  return NO;
}

#pragma mark - Rotation gizmo: small accessor defaults

- (NSArray<NSNumber *> *)rotationEulerDegrees {
  NSString *label = self.rotationLabel;
  if (!label)
    return @[ @0.0, @0.0, @0.0 ];
  NSArray<NSNumber *> *v = [self valuesForLabel:label];
  if (v.count >= 3)
    return v;
  // Pad short lanes to length 3.
  return @[
    v.count > 0 ? v[0] : @0.0, v.count > 1 ? v[1] : @0.0,
    v.count > 2 ? v[2] : @0.0
  ];
}

- (CGPoint)rotationCenterForContentRect:(CGRect)cr {
  return CGPointMake(CGRectGetMidX(cr), CGRectGetMidY(cr));
}

- (NSArray<NSColor *> *)rotationRingColors {
  return @[
    [NSColor colorWithRed:1.00 green:0.30 blue:0.30 alpha:1.0],
    [NSColor colorWithRed:0.35 green:0.85 blue:0.40 alpha:1.0],
    [NSColor colorWithRed:0.40 green:0.55 blue:1.00 alpha:1.0],
  ];
}

- (simd_double3)rotationAxisSigns {
  return (simd_double3){+1.0, -1.0, +1.0};
}

- (CGFloat)rotationRadiusPxForCanvas:(KKMiniViewerView *)canvas {
  CGFloat h = canvas.bounds.size.height;
  CGFloat scale = (h > 0) ? (h / kKKRotationBaselineCanvasH) : 1.0;
  return kKKRotationBaselineRadiusPt * scale;
}

#pragma mark - Rotation gizmo: state machine (default impls)

// Returns the current world matrix from rotationEulerDegrees.
- (KKRotMatrix3)_currentRotationMatrix {
  NSArray<NSNumber *> *r = [self rotationEulerDegrees];
  double xDeg = r[0].doubleValue;
  double yDeg = r[1].doubleValue;
  double zDeg = r[2].doubleValue;
  return KKBuildRotationMatrix((float)(xDeg * M_PI / 180.0),
                               (float)(yDeg * M_PI / 180.0),
                               (float)(zDeg * M_PI / 180.0));
}

// Converts an NSColor to the simd_float4 the rotation shader wants.
static simd_float4 KKMiniRotationColorToFloat4(NSColor *color) {
  NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  CGFloat r = 1, g = 1, b = 1, a = 1;
  [c getRed:&r green:&g blue:&b alpha:&a];
  return (simd_float4){(float)r, (float)g, (float)b, (float)a};
}

// Reveal mode only bites when the host wired the toggle (so plugins that don't
// support opt-hide are untouched).
- (BOOL)_revealActive {
  return _revealHidden && self.onHandleVisibilityToggled != nil;
}

// "Peek and use" mode: the master is off (handlesHidden) and Opt is held. Every
// control reveals and is interactive, so its ghost draws at FULL alpha (it
// reads as usable, not as a dimmed re-show target). Distinct from a single
// element you individually hid while the master is on - that ghost stays dimmed
// at 0.3.
- (BOOL)_peekActive {
  return _handlesHidden && [self _revealActive];
}

// A handle/element is "user-hidden" (master tick off or its own pill off) -
// eligible to be revealed as a ghost. Boundary-phase suppression is separate.
- (BOOL)_userHiddenLabel:(NSString *)label {
  return _handlesHidden ||
         (label && [_hiddenHandleLabels containsObject:label]);
}

// Hidden by its own pill, independent of the master tick.
- (BOOL)_individuallyHiddenLabel:(NSString *)label {
  return label && [_hiddenHandleLabels containsObject:label];
}

// Whether `label`'s handle should be drawn + hit-tested this frame.
//   master on  : visible unless individually hidden; Opt-hold reveals a hidden
//                one as a dim ghost (so an Opt-click can re-show it).
//   master off : Opt-hold "peek" shows ONLY the controls left enabled - the
//   ones
//                you turned off stay off (peek mirrors a flip back to
//                master-on, so it respects your per-element config rather than
//                flashing everything).
- (BOOL)_shownLabel:(NSString *)label {
  BOOL hidden = [self _individuallyHiddenLabel:label];
  if (_handlesHidden)
    return [self _revealActive] && !hidden;
  return !hidden || [self _revealActive];
}

// A specific rotation ring is user-hidden if the master tick is off, the whole
// Rotation compound is hidden, or that ring's own key is hidden. The popover
// stores ring keys as "<rotationLabel>.X/.Y/.Z" (e.g. @"Rotation.X").
- (BOOL)_ringUserHiddenAtAxis:(int)k {
  if (_handlesHidden)
    return YES;
  return [self _ringIndividuallyHiddenAtAxis:k];
}

// As above but independent of the master tick: the ring's own pill, or its
// parent Rotation compound, turned off.
- (BOOL)_ringIndividuallyHiddenAtAxis:(int)k {
  if (self.rotationLabel &&
      [_hiddenHandleLabels containsObject:self.rotationLabel])
    return YES;
  NSString *axis = (k == 0) ? @"X" : (k == 1) ? @"Y" : @"Z";
  NSString *key =
      [NSString stringWithFormat:@"%@.%@", self.rotationLabel, axis];
  return [_hiddenHandleLabels containsObject:key];
}

// Ring is drawn / hit-tested this frame. Mirrors -_shownLabel: : master-off
// peek shows only the rings left enabled.
- (BOOL)_ringShownAtAxis:(int)k {
  BOOL hidden = [self _ringIndividuallyHiddenAtAxis:k];
  if (_handlesHidden)
    return [self _revealActive] && !hidden;
  return !hidden || [self _revealActive];
}

// Per-ring draw alpha: dim when it's a revealed ghost, full in peek mode.
- (float)_ringAlphaAtAxis:(int)k {
  if ([self _peekActive])
    return 1.0f;
  return [self _ringUserHiddenAtAxis:k] ? 0.3f : 1.0f;
}

- (BOOL)rotationOSCCenter:(out CGPoint *)outCenter
                 radiusPx:(out CGFloat *)outRadiusPx
                   params:(out KKRotationOSCParams *)outParams
           forContentRect:(CGRect)cr {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return NO;
  *outCenter = [self rotationCenterForContentRect:cr];
  *outRadiusPx = [self rotationRadiusPxForCanvas:self.canvas];
  KKRotMatrix3 m = [self _currentRotationMatrix];
  NSArray<NSColor *> *cols = [self rotationRingColors];
  KKRotationOSCParams p = {
      .rotCol0 = m.col0,
      .rotCol1 = m.col1,
      .rotCol2 = m.col2,
      // ringHalfWidth / outlineWidth are fractions of radius; the canvas's
      // encode helper rescales them into the shader's normalized space. The
      // 3.5/90 ratio reads as a chunky grab target on the mini.
      .radius = 1.0f,
      .ringHalfWidth = 3.5f / 90.0f,
      .outlineWidth = 1.0f / 90.0f,
      .backDim = 0.3f,
      .ringColorX = KKMiniRotationColorToFloat4(cols[0]),
      .ringColorY = KKMiniRotationColorToFloat4(cols[1]),
      .ringColorZ = KKMiniRotationColorToFloat4(cols[2]),
      .outlineColor = {0.0f, 0.0f, 0.0f, 0.75f},
      .activeRing = (int)_rotActiveAxis,
      .activeBoost = (_rotActiveAxis >= 0) ? 0.35f : 0.0f,
      .ringVisible =
          {[self _ringShownAtAxis:0] ? [self _ringAlphaAtAxis:0] : 0.0f,
           [self _ringShownAtAxis:1] ? [self _ringAlphaAtAxis:1] : 0.0f,
           [self _ringShownAtAxis:2] ? [self _ringAlphaAtAxis:2] : 0.0f},
  };
  *outParams = p;
  return YES;
}

- (BOOL)rotationHitTestAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  CGPoint center = [self rotationCenterForContentRect:cr];
  CGFloat radius = [self rotationRadiusPxForCanvas:self.canvas];
  double threshold = radius * kKKRotationHitThresholdRatio;
  // Overlay is Y-UP; the rotation math works in Y-DOWN screen space.
  CGPoint local = CGPointMake(p.x - center.x, center.y - p.y);
  KKRotMatrix3 m = [self _currentRotationMatrix];
  double bestFront = 1e9;
  NSInteger bestK = -1;
  double bestT = 0;
  for (int k = 0; k < 3; k++) {
    if (![self _ringShownAtAxis:k])
      continue; // hidden ring is not grabbable
    KKRingHit h =
        KKClosestAngleOnRing(m, k, radius, local, kKKRotationRingSamples);
    if (h.frontDist < bestFront) {
      bestFront = h.frontDist;
      bestK = k;
      bestT = h.frontT;
    }
  }
  if (bestK < 0 || bestFront > threshold) {
    _rotActiveAxis = -1;
    return NO;
  }
  _rotActiveAxis = bestK;
  _rotPressAngle = bestT;
  return YES;
}

- (void)rotationBeginDragAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  if (_rotActiveAxis < 0)
    return;
  _rotPressMousePt = p;
  NSArray<NSNumber *> *r = [self rotationEulerDegrees];
  _rotPressRx = r[0].doubleValue * M_PI / 180.0;
  _rotPressRy = r[1].doubleValue * M_PI / 180.0;
  _rotPressRz = r[2].doubleValue * M_PI / 180.0;
  _rotLastWrittenRx = _rotPressRx;
  _rotLastWrittenRy = _rotPressRy;
  _rotLastWrittenRz = _rotPressRz;
  // Y-DOWN screen tangent at the press ring point.
  KKRotMatrix3 m = [self _currentRotationMatrix];
  simd_float3 U, V;
  KKRingBasis(m, (int)_rotActiveAxis, &U, &V);
  double t = _rotPressAngle;
  double tx = -sin(t) * U.x + cos(t) * V.x;
  double ty = -sin(t) * U.y + cos(t) * V.y;
  double len = sqrt(tx * tx + ty * ty);
  if (len > 1e-6) {
    tx /= len;
    ty /= len;
  }
  _rotPressTangentX = tx;
  _rotPressTangentY = ty;
}

- (void)applyRotationDragToPoint:(CGPoint)p
                     contentRect:(CGRect)cr
                          canvas:(KKMiniViewerView *)canvas
                       modifiers:(NSEventModifierFlags)modifiers {
  if (_rotActiveAxis < 0)
    return;
  NSString *label = self.rotationLabel;
  if (!label)
    return;
  CGFloat radius = [self rotationRadiusPxForCanvas:canvas];
  if (radius <= 0)
    return;
  // Project overlay-space mouse displacement onto the press-time tangent.
  // dy negated to bring overlay Y-UP into the tangent's Y-DOWN convention.
  double dx = p.x - _rotPressMousePt.x;
  double dy = _rotPressMousePt.y - p.y;
  double projected = dx * _rotPressTangentX + dy * _rotPressTangentY;
  simd_double3 signs = [self rotationAxisSigns];
  double sign = (_rotActiveAxis == 0)   ? signs.x
                : (_rotActiveAxis == 1) ? signs.y
                                        : signs.z;
  double dAngle = sign * projected / (double)radius;
  if (modifiers & NSEventModifierFlagCommand)
    dAngle = round(dAngle / kKKRotationSnapStep) * kKKRotationSnapStep;
  double rx = 0, ry = 0, rz = 0;
  KKRotationComposeAxisDelta((int)_rotActiveAxis, dAngle, _rotPressRx,
                             _rotPressRy, _rotPressRz, &_rotLastWrittenRx,
                             &_rotLastWrittenRy, &_rotLastWrittenRz, &rx, &ry,
                             &rz);
  const double kRadToDeg = 180.0 / M_PI;
  NSArray<NSNumber *> *newValues =
      @[ @(rx * kRadToDeg), @(ry * kRadToDeg), @(rz * kRadToDeg) ];
  [self commitValues:newValues forLabel:label canvas:canvas];
}

#pragma mark - Provided to subclasses

// The mini viewer is the *constants* editor: a property's handle shows only
// while it's a constant. Every property always has a lane; `enabled` means
// animatable (dropdown-controlled). Constant == the lane is absent or not
// enabled. Editing a value preserves `enabled`, so the handle stays put
// through a drag - no mid-drag exemption needed.
- (BOOL)isConstantLabel:(NSString *)label {
  for (KKLane *lane in self.timeline.lanes)
    if ([lane.label isEqualToString:label])
      // Constants popover: a constant (disabled) lane shows its handle.
      // Boundary popover: only the *animatable* lanes being edited there
      // show theirs (so a disabled property's handle doesn't intrude).
      return self.boundaryEditing ? lane.enabled : !lane.enabled;
  return !self.boundaryEditing;
}

- (NSArray<NSNumber *> *)valuesForLabel:(NSString *)label {
  if (_hasLiveFraction) {
    NSArray<NSNumber *> *live = _liveValues[label];
    if (live.count > 0 && fabs(self.editFraction - _liveFraction) < 1e-4)
      return live;
  }
  for (KKLane *lane in self.timeline.lanes) {
    if (![lane.label isEqualToString:label])
      continue;
    NSArray<NSNumber *> *v =
        KKTimelineLaneValueAtFraction(lane, self.editFraction);
    if (v.count > 0)
      return v;
  }
  return [self defaultValuesForLabel:label];
}

- (void)setLiveValues:(NSArray<NSNumber *> *)values
             forLabel:(NSString *)label
           atFraction:(double)fraction {
  if (!label.length)
    return;
  if (!_liveValues)
    _liveValues = [NSMutableDictionary dictionary];
  if (values.count == 0) {
    [_liveValues removeObjectForKey:label];
    return;
  }
  _liveValues[label] = [values copy];
  _liveFraction = fraction;
  _hasLiveFraction = YES;
}

- (void)clearLiveValues {
  [_liveValues removeAllObjects];
  _hasLiveFraction = NO;
}

- (CGRect)cropRectForContentRect:(CGRect)cr {
  NSString *label = self.cropLabel;
  if (!label)
    return CGRectZero;
  return [_cropEditor cropRectForValues:[self valuesForLabel:label]
                            contentRect:cr];
}

- (CGPoint)handlePointForContentRect:(CGRect)cr
                            position:(NSArray<NSNumber *> *)pos {
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  return CGPointMake(CGRectGetMinX(cr) + px * cr.size.width,
                     CGRectGetMinY(cr) + py * cr.size.height);
}

- (KKTimeline *)_timelineBySettingValues:(NSArray<NSNumber *> *)values
                                forLabel:(NSString *)label {
  if (self.boundaryEditing) {
    // Replace the keypose nearest editFraction, preserving the lane's
    // structure (times, intervals, enabled).
    // KKLaneBySettingValuesNearestFraction copy-preserves the keypose's
    // per-keypose fields (spatialSmooth, in/out handles) AND propagates
    // hold-links to the linked twin - matching the viewer's drag-write. Without
    // the propagation a linked twin stayed at its old value mid-drag, so the
    // motion-path overlay (which draws every keypose) showed a phantom segment
    // that only collapsed on mouse-up when the host synced it.
    KKTimeline *updated = [self.timeline copy] ?: [KKTimeline timeline];
    NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
      if (![lanes[i].label isEqualToString:label])
        continue;
      if (lanes[i].keyposes.count)
        lanes[i] = KKLaneBySettingValuesNearestFraction(
            lanes[i], self.editFraction, values);
      break;
    }
    updated.lanes = lanes;
    return updated;
  }
  KKTimeline *updated = [self.timeline copy] ?: [KKTimeline timeline];
  NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
  BOOL replaced = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([lanes[i].label isEqualToString:label]) {
      // Copy the existing lane so EVERY property survives a constant value edit
      // - aspectLinked especially. A fresh lane that only carried
      // valueType/enabled/min/max dropped aspectLinked, so the first scale-box
      // drag in the constants editor silently cleared the Scale aspect lock
      // (the next tick then read aspectLinked=0). Just replace the constant
      // keypose.
      KKLane *nl = [lanes[i] copy];
      nl.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
      lanes[i] = nl;
      replaced = YES;
      break;
    }
  }
  if (!replaced) {
    // Build from the plugin template when available so the new lane keeps its
    // metadata (aspect-link, units, bounds) - a bare lane drops those, which on
    // a fresh instance clears e.g. Radius/Scale aspect-lock on the first drag.
    KKLane *tmpl = [self templateLaneForLabel:label];
    KKLane *lane = tmpl ? [tmpl copy] : [KKLane laneWithLabel:label];
    lane.valueType = (KKLaneValueType)[self valueTypeForLabel:label];
    lane.enabled = NO; // a value edit must not opt the property in
    lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
    [lanes addObject:lane];
  }
  updated.lanes = lanes;
  return updated;
}

- (void)commitValues:(NSArray<NSNumber *> *)values
            forLabel:(NSString *)label
              canvas:(KKMiniViewerView *)canvas {
  self.timeline = [self _timelineBySettingValues:values forLabel:label];
  [canvas reportHandleValueForLabel:label values:values];
  [canvas setNeedsDisplay:YES];
  [canvas setHandlesNeedDisplay];
}

#pragma mark - KKMiniViewerDelegate

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    processSourceTexture:(id<MTLTexture>)source
             intoTexture:(id<MTLTexture>)dest
           commandBuffer:(id<MTLCommandBuffer>)cb {
  self.canvas = canvas;
  if (!source || !dest || !cb)
    return NO;
  return [self encodeEffectFromSource:source into:dest commandBuffer:cb];
}

- (BOOL)_labelSuppressed:(NSString *)label {
  return label && ([_suppressedHandleLabels containsObject:label] ||
                   [_hiddenHandleLabels containsObject:label]);
}

- (void)setHandlesHidden:(BOOL)handlesHidden {
  if (_handlesHidden == handlesHidden)
    return;
  _handlesHidden = handlesHidden;
  // Repaint the bound canvas (if a preview/popover is open) so the change
  // shows without a scrub; nil canvas is a no-op.
  [self.canvas setHandlesNeedDisplay];
}

- (void)setHiddenHandleLabels:(NSSet<NSString *> *)hiddenHandleLabels {
  if (_hiddenHandleLabels == hiddenHandleLabels ||
      [_hiddenHandleLabels isEqualToSet:hiddenHandleLabels])
    return;
  _hiddenHandleLabels = [hiddenHandleLabels copy];
  [self.canvas setHandlesNeedDisplay];
}

- (BOOL)_cropActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && self.cropLabel &&
         ![_suppressedHandleLabels containsObject:self.cropLabel] &&
         [self isConstantLabel:self.cropLabel] &&
         [self _shownLabel:self.cropLabel];
}

// Crop draw alpha: dim when it's a revealed ghost (border + corner handles),
// full in peek mode.
- (CGFloat)cropGhostAlpha {
  if ([self _peekActive])
    return 1.0;
  return [self _userHiddenLabel:self.cropLabel] ? 0.3 : 1.0;
}

- (CGFloat)scaleGhostAlpha {
  return 1.0; // no scale box by default; MagicMove overrides
}

- (CGFloat)anchorSquareGhostAlpha {
  return 1.0; // no anchor square by default; MagicMove overrides
}

- (CGFloat)positionHandleGhostAlpha {
  return 1.0; // no secondary Position handle by default; Glow overrides
}

- (BOOL)positionHandleIsActive {
  return NO; // no secondary Position handle by default; Glow overrides
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    extraHandleCentersForContentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return nil;
  return
      [_cropEditor handleCentersForValues:[self valuesForLabel:self.cropLabel]
                              contentRect:cr];
}

- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
        cropHandleCentersForValues:(NSArray<NSNumber *> *)values
                       contentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return nil;
  return [_cropEditor handleCentersForValues:values contentRect:cr];
}

- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return @[];
  CGRect rect = [self cropRectForContentRect:cr];
  NSArray<NSValue *> *handles =
      [_cropEditor handleCentersForValues:[self valuesForLabel:self.cropLabel]
                              contentRect:cr];
  // Crop readout in source pixels: box fraction × media size.
  NSString *readout = nil;
  CGSize media = canvas.sourceMediaSize;
  if (media.width > 0 && media.height > 0 && cr.size.width > 0 &&
      cr.size.height > 0) {
    long pxW = lround(rect.size.width / cr.size.width * media.width);
    long pxH = lround(rect.size.height / cr.size.height * media.height);
    readout = [NSString stringWithFormat:@"%ld x %ld", pxW, pxH];
  }
  return @[ [KKMiniBox boxWithRect:rect
                     handleCenters:handles
                           readout:readout
                        ghostAlpha:[self cropGhostAlpha]] ];
}

- (BOOL)_pointActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && self.pointLabel &&
         ![_suppressedHandleLabels containsObject:self.pointLabel] &&
         [self isConstantLabel:self.pointLabel] &&
         [self _shownLabel:self.pointLabel];
}

- (BOOL)_rotationActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && self.rotationLabel &&
         ![_suppressedHandleLabels containsObject:self.rotationLabel] &&
         [self isConstantLabel:self.rotationLabel] &&
         [self _shownLabel:self.rotationLabel];
}

- (CGFloat)pointHandleGhostAlpha {
  if ([self _peekActive])
    return 1.0;
  return [self _userHiddenLabel:self.pointLabel] ? 0.3 : 1.0;
}

- (BOOL)labelVisibleOrRevealing:(NSString *)label {
  return [self _shownLabel:label];
}

- (CGFloat)ghostAlphaForLabel:(NSString *)label {
  if ([self _peekActive])
    return 1.0;
  return [self _userHiddenLabel:label] ? 0.3 : 1.0;
}

- (NSCursor *)kkVisibilityCursorForLabel:(NSString *)label {
  if (!label || !self.revealHidden || self.handlesHidden ||
      !self.onHandleVisibilityToggled)
    return nil;
  // Opt held + master on (not peek). eye over a revealed ghost (Opt-click
  // shows), eye.slash over a visible handle (Opt-click hides).
  return ([self ghostAlphaForLabel:label] < 1.0) ? KKVisibilityShowCursor()
                                                 : KKVisibilityHideCursor();
}

- (CGFloat)motionPathGhostAlpha {
  return 1.0;
}

- (void)setRevealHidden:(BOOL)revealHidden {
  if (_revealHidden == revealHidden)
    return;
  _revealHidden = revealHidden;
  // Handles are the Metal pass - invalidate the MTKView, not just the overlay.
  [self.canvas setNeedsDisplay:YES];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    rotationOSCCenter:(out CGPoint *)outCenter
             radiusPx:(out CGFloat *)outRadiusPx
               params:(out KKRotationOSCParams *)outParams
          contentRect:(CGRect)cr {
  self.canvas = canvas;
  if (![self _rotationActiveForContentRect:cr])
    return NO;
  return [self rotationOSCCenter:outCenter
                        radiusPx:outRadiusPx
                          params:outParams
                  forContentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
          contentRect:(CGRect)cr {
  if (![self _pointActiveForContentRect:cr])
    return NO;
  return [self pointHandleCenter:outCenter forContentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
             forValue:(double)value
          contentRect:(CGRect)cr {
  if (![self _pointActiveForContentRect:cr])
    return NO;
  return [self pointHandleCenter:outCenter forValue:value forContentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
            forValues:(NSArray<NSNumber *> *)values
          contentRect:(CGRect)cr {
  if (![self _pointActiveForContentRect:cr])
    return NO;
  return [self pointHandleCenter:outCenter forValues:values forContentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  self.canvas = canvas;
  if (CGRectIsEmpty(cr))
    return NO;
  // Rotation > point > crop by default; a plugin whose point handle draws on
  // top flips to point > rotation (see -pointHandleBeatsRotation).
  BOOL pointFirst = [self pointHandleBeatsRotation];
  if (pointFirst && [self _pointActiveForContentRect:cr] &&
      [self pointHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self _rotationActiveForContentRect:cr] &&
      [self rotationHitTestAtPoint:p contentRect:cr])
    return YES;
  if (!pointFirst && [self _pointActiveForContentRect:cr] &&
      [self pointHandleHitAtPoint:p contentRect:cr])
    return YES;
  return [self _cropActiveForContentRect:cr] &&
         [_cropEditor partAtPoint:p
                           values:[self valuesForLabel:self.cropLabel]
                      contentRect:cr] >= 0;
}

// Hover hit-test for the cursor, same precedence as -handleHitAtPoint:: the
// point handle shows the move cursor, a rotation ring the quadrant rotate
// cursor, a crop handle the matching resize cursor. Subclasses add their own
// handle types (scale, anchor, path) and fall back to super. rotationHitTest
// runs on every hover via -handleHitAtPoint: already, so calling it here adds
// no new side effect.
- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
           cursorAtPoint:(CGPoint)p
             contentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr))
    return nil;
  self.canvas = canvas;
  BOOL pointFirst = [self pointHandleBeatsRotation];
  if (pointFirst && [self _pointActiveForContentRect:cr] &&
      [self pointHandleHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:self.pointLabel]
               ?: KKPointMoveCursor();
  if ([self _rotationActiveForContentRect:cr] &&
      [self rotationHitTestAtPoint:p contentRect:cr]) {
    // rotationHitTestAtPoint set _rotActiveAxis (0=X, 1=Y, 2=Z); the cursor
    // encodes that axis, not the hover position.
    NSString *axis = (_rotActiveAxis == 0)   ? @"X"
                     : (_rotActiveAxis == 1) ? @"Y"
                                             : @"Z";
    NSString *ringKey =
        [NSString stringWithFormat:@"%@.%@", self.rotationLabel, axis];
    CGPoint rc = [self rotationCenterForContentRect:cr];
    return [self kkVisibilityCursorForLabel:ringKey]
               ?: KKRotationAxisCursor(_rotActiveAxis,
                                       atan2(p.y - rc.y, p.x - rc.x));
  }
  if (!pointFirst && [self _pointActiveForContentRect:cr] &&
      [self pointHandleHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:self.pointLabel]
               ?: KKPointMoveCursor();
  if ([self _cropActiveForContentRect:cr]) {
    NSInteger part =
        [_cropEditor partAtPoint:p
                          values:[self valuesForLabel:self.cropLabel]
                     contentRect:cr];
    if (part >= 1)
      return [self kkVisibilityCursorForLabel:self.cropLabel]
                 ?: KKResizeCursorOfKind(KKMiniCropResizeKind(part - 1));
  }
  return nil;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  if (!self.onHandleVisibilityToggled || CGRectIsEmpty(cr))
    return NO;
  self.canvas = canvas;
  NSString *label = nil;
  BOOL pointFirst = [self pointHandleBeatsRotation];
  // Same precedence as the drag path so the same element resolves.
  if (pointFirst && [self _pointActiveForContentRect:cr] &&
      [self pointHandleHitAtPoint:p contentRect:cr] && self.pointLabel) {
    label = self.pointLabel;
  } else if ([self _rotationActiveForContentRect:cr] &&
             [self rotationHitTestAtPoint:p contentRect:cr] &&
             self.rotationLabel) {
    NSString *axis = (_rotActiveAxis == 0)   ? @"X"
                     : (_rotActiveAxis == 1) ? @"Y"
                                             : @"Z";
    label = [NSString stringWithFormat:@"%@.%@", self.rotationLabel, axis];
  } else if ([self _pointActiveForContentRect:cr] &&
             [self pointHandleHitAtPoint:p contentRect:cr] && self.pointLabel) {
    label = self.pointLabel;
  } else if ([self _cropActiveForContentRect:cr] && self.cropLabel &&
             [_cropEditor partAtPoint:p
                               values:[self valuesForLabel:self.cropLabel]
                          contentRect:cr] >= 0) {
    label = self.cropLabel;
  }
  // The hit-tests above leave transient active state (e.g. _rotActiveAxis), but
  // an opt-click never runs the begin/end-drag cycle that would clear it - so a
  // stale highlight would linger until the next click. Reset it here (mirrors
  // -miniViewerEndHandleDrag:) and force a repaint.
  _pointGrabbed = NO;
  _rotationGrabbed = NO;
  _rotActiveAxis = -1;
  [_cropEditor endDrag];
  [canvas setNeedsDisplay:YES];
  if (!label)
    return NO;
  self.onHandleVisibilityToggled(label);
  return YES;
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  self.canvas = canvas;
  _pointGrabbed = NO;
  _rotationGrabbed = NO;
  [_cropEditor endDrag];
  if (CGRectIsEmpty(cr))
    return;
  BOOL pointFirst = [self pointHandleBeatsRotation];
  if (pointFirst && [self _pointActiveForContentRect:cr] &&
      [self pointHandleHitAtPoint:p contentRect:cr]) {
    _pointGrabbed = YES;
    [self applyPointDragToPoint:p contentRect:cr canvas:canvas];
    return;
  }
  if ([self _rotationActiveForContentRect:cr] &&
      [self rotationHitTestAtPoint:p contentRect:cr]) {
    _rotationGrabbed = YES;
    [self rotationBeginDragAtPoint:p contentRect:cr];
    return;
  }
  if ([self _pointActiveForContentRect:cr] && [self pointHandleHitAtPoint:p
                                                              contentRect:cr]) {
    _pointGrabbed = YES;
    [self applyPointDragToPoint:p contentRect:cr canvas:canvas];
    return;
  }
  if (![self _cropActiveForContentRect:cr])
    return;
  if ([_cropEditor beginDragAtPoint:p
                             values:[self valuesForLabel:self.cropLabel]
                        contentRect:cr] >= 0) {
    NSArray<NSNumber *> *v = [_cropEditor valuesForDragToPoint:p
                                                   contentRect:cr];
    if (v)
      [self commitValues:v forLabel:self.cropLabel canvas:canvas];
  }
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr {
  [self miniViewer:canvas dragHandleToPoint:p contentRect:cr modifiers:0];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if (_rotationGrabbed) {
    [self applyRotationDragToPoint:p
                       contentRect:cr
                            canvas:canvas
                         modifiers:modifiers];
  } else if (_pointGrabbed) {
    [self applyPointDragToPoint:p contentRect:cr canvas:canvas];
  } else if (_cropEditor.activePart >= 0) {
    NSArray<NSNumber *> *v = [_cropEditor valuesForDragToPoint:p
                                                   contentRect:cr];
    if (v)
      [self commitValues:v forLabel:self.cropLabel canvas:canvas];
  }
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  _pointGrabbed = NO;
  _rotationGrabbed = NO;
  _rotActiveAxis = -1;
  [_cropEditor endDrag];
  // Force the metal pass to redraw so handles reflect the cleared active
  // state. mouseUp only marks the overlay dirty; without this the arc
  // glyph stays in its active (enlarged) shape until the next param-echo
  // refresh, which never fires when the just-edited lane is rotation/crop
  // rather than the point handle's lane.
  [canvas setNeedsDisplay:YES];
  [canvas setHandlesNeedDisplay];
}

// Slider/field edits in the constants popover - mirror into the preview
// timeline so the mini viewer tracks live (persist stays coalesced
// upstream).
- (void)miniViewer:(KKMiniViewerView *)canvas
    applyConstantValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label {
  if (values.count)
    self.timeline = [self _timelineBySettingValues:values forLabel:label];
}

@end
