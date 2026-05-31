/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasRenderer.h"

#import "KKMiniCanvasCropEditor.h"
#import <KeyframelessKit/KKRotationOSCMath.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimingStage.h>

// 28pt at the 230pt mini-canvas baseline (see project_minicanvas_osc_port).
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

@implementation KKMiniCanvasRenderer {
  KKMiniCanvasCropEditor *_cropEditor;
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
    _cropEditor = [[KKMiniCanvasCropEditor alloc] init];
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

#pragma mark - Subclass effect + point handle (defaults)

- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  return NO;
}
- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStylePoint;
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
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)contentRect {
  return NO;
}
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)contentRect
                       canvas:(KKMiniCanvasView *)canvas {
}
- (BOOL)rotationIsActive {
  return _rotationGrabbed;
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

- (CGFloat)rotationRadiusPxForCanvas:(KKMiniCanvasView *)canvas {
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
                          canvas:(KKMiniCanvasView *)canvas
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

// The mini canvas is the *constants* editor: a property's handle shows only
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

- (KKTimeline *)_timelineBySettingValues:(NSArray<NSNumber *> *)values
                                forLabel:(NSString *)label {
  if (self.boundaryEditing) {
    // Replace the keypose nearest editFraction, preserving the lane's
    // structure (times, intervals, enabled). Authoritative Hold-twin
    // handling is the host's job; the preview only renders editFraction.
    KKTimeline *updated = [self.timeline copy] ?: [KKTimeline timeline];
    NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
      if (![lanes[i].label isEqualToString:label])
        continue;
      KKLane *nl = [lanes[i] copy];
      NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
      if (kps.count) {
        NSInteger best = 0;
        double bd = 1.0e9;
        for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
          double d = fabs(kps[k].time - self.editFraction);
          if (d < bd) {
            bd = d;
            best = k;
          }
        }
        KKKeyPose *nk = [KKKeyPose keyposeAtTime:kps[best].time values:values];
        nk.outgoing = kps[best].outgoing; // preserve easing/modulation
        kps[best] = nk;
        nl.keyposes = kps;
      }
      lanes[i] = nl;
      break;
    }
    updated.lanes = lanes;
    return updated;
  }
  KKTimeline *updated = [self.timeline copy] ?: [KKTimeline timeline];
  KKLane *lane = [KKLane laneWithLabel:label];
  lane.valueType = (KKLaneValueType)[self valueTypeForLabel:label];
  lane.enabled = NO; // a value edit must not opt the property in
  [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:values]];
  NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
  BOOL replaced = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([lanes[i].label isEqualToString:label]) {
      lane.enabled = lanes[i].enabled; // preserve animatable status
      lane.componentMin = lanes[i].componentMin;
      lane.componentMax = lanes[i].componentMax;
      lanes[i] = lane;
      replaced = YES;
      break;
    }
  }
  if (!replaced)
    [lanes addObject:lane];
  updated.lanes = lanes;
  return updated;
}

- (void)commitValues:(NSArray<NSNumber *> *)values
            forLabel:(NSString *)label
              canvas:(KKMiniCanvasView *)canvas {
  self.timeline = [self _timelineBySettingValues:values forLabel:label];
  [canvas reportHandleValueForLabel:label values:values];
  [canvas setNeedsDisplay:YES];
  [canvas setHandlesNeedDisplay];
}

#pragma mark - KKMiniCanvasDelegate

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    processSourceTexture:(id<MTLTexture>)source
             intoTexture:(id<MTLTexture>)dest
           commandBuffer:(id<MTLCommandBuffer>)cb {
  self.canvas = canvas;
  if (!source || !dest || !cb)
    return NO;
  return [self encodeEffectFromSource:source into:dest commandBuffer:cb];
}

- (BOOL)_labelSuppressed:(NSString *)label {
  return label && [_suppressedHandleLabels containsObject:label];
}

- (BOOL)_cropActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && self.cropLabel &&
         ![self _labelSuppressed:self.cropLabel] &&
         [self isConstantLabel:self.cropLabel];
}

- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
    extraHandleCentersForContentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return nil;
  return
      [_cropEditor handleCentersForValues:[self valuesForLabel:self.cropLabel]
                              contentRect:cr];
}

- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
        cropHandleCentersForValues:(NSArray<NSNumber *> *)values
                       contentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return nil;
  return [_cropEditor handleCentersForValues:values contentRect:cr];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
        borderRect:(out CGRect *)outRect
    forContentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return NO;
  *outRect = [self cropRectForContentRect:cr];
  return YES;
}

- (BOOL)_pointActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && self.pointLabel &&
         ![self _labelSuppressed:self.pointLabel] &&
         [self isConstantLabel:self.pointLabel];
}

- (BOOL)_rotationActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && self.rotationLabel &&
         ![self _labelSuppressed:self.rotationLabel] &&
         [self isConstantLabel:self.rotationLabel];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
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

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
          contentRect:(CGRect)cr {
  if (![self _pointActiveForContentRect:cr])
    return NO;
  return [self pointHandleCenter:outCenter forContentRect:cr];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
             forValue:(double)value
          contentRect:(CGRect)cr {
  if (![self _pointActiveForContentRect:cr])
    return NO;
  return [self pointHandleCenter:outCenter forValue:value forContentRect:cr];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  self.canvas = canvas;
  if (CGRectIsEmpty(cr))
    return NO;
  // Rotation > point > crop. Rotation is the largest target (the sphere) but
  // also the most context-rich, and rings are visually distinct from point
  // handles, so overlap is rare.
  if ([self _rotationActiveForContentRect:cr] &&
      [self rotationHitTestAtPoint:p contentRect:cr])
    return YES;
  if ([self _pointActiveForContentRect:cr] && [self pointHandleHitAtPoint:p
                                                              contentRect:cr])
    return YES;
  return [self _cropActiveForContentRect:cr] &&
         [_cropEditor partAtPoint:p
                           values:[self valuesForLabel:self.cropLabel]
                      contentRect:cr] >= 0;
}

- (void)miniCanvas:(KKMiniCanvasView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  self.canvas = canvas;
  _pointGrabbed = NO;
  _rotationGrabbed = NO;
  [_cropEditor endDrag];
  if (CGRectIsEmpty(cr))
    return;
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

- (void)miniCanvas:(KKMiniCanvasView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr {
  [self miniCanvas:canvas dragHandleToPoint:p contentRect:cr modifiers:0];
}

- (void)miniCanvas:(KKMiniCanvasView *)canvas
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

- (void)miniCanvasEndHandleDrag:(KKMiniCanvasView *)canvas {
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
// timeline so the mini canvas tracks live (persist stays coalesced
// upstream).
- (void)miniCanvas:(KKMiniCanvasView *)canvas
    applyConstantValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label {
  if (values.count)
    self.timeline = [self _timelineBySettingValues:values forLabel:label];
}

@end
