/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerRenderer.h"

#import "KKMiniElement.h"
#import "KKMiniViewerCropEditor.h"
#import "KKOSCGlyphStyle.h"
#import "KKOSCVisibilityModel.h"
#import "KKResizeCursor.h"
#import <KeyframelessKit/KKLinkBus.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KKLocalized.h>
#import <KeyframelessKit/KKRotationOSCMath.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKWatermark.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

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
  BOOL _previewMotionBlurSampling;
  // Motion-blur sample targets, rebuilt only when the preview's size or format
  // changes (see -_motionBlurSampleTexturesCount:like:).
  NSArray<id<MTLTexture>> *_mbSampleTextures;
  NSUInteger _mbSampleW;
  NSUInteger _mbSampleH;
  MTLPixelFormat _mbSampleFormat;
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
  // viewer side by `KKRotationOSC`).
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

// The canvas is a PAUSED MTKView driven by setNeedsDisplay, so a swapped-in
// timeline (browser template load, preset apply, undo, the host's
// parameterChanged pump) leaves the last render on screen until something else
// happens to dirty the view. The main viewer has the render nudge for exactly
// this; marking the canvas here is the mini's equivalent, so every path that
// replaces the timeline re-renders instead of only the ones that remembered to.
- (void)setTimeline:(KKTimeline *)timeline {
  _timeline = [timeline copy];
  [self.canvas setNeedsDisplay:YES];
  [self.canvas setHandlesNeedDisplay];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _cropEditor = [[KKMiniViewerCropEditor alloc] init];
    _currentSlotCount = 1;
    _rotActiveAxis = -1;
    _clipTimelineStartSec = -1.0; // unknown until the inspector pushes it
    // Warm the app-group container off-thread so the first parameter-link
    // resolve in this (inspector/ViewBridge) process doesn't stall on the ~1-2s
    // cold container lookup. Harmless no-op when nothing links.
    [KKLinkBus warmUp];
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
  // Every shipped plugin overrode the old 1.0 default to 0.6 so its handles
  // match the motion-path anchor dots - so the family scale IS the default
  // now (shared constant, KKOSCGlyphStyle.h). Override only to deviate.
  return KKOSCAnchorDotScale;
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
// plugin whose point handle draws ON TOP of the rings (e.g. a Position
// arc, matching the viewer's layering) overrides this to YES so the
// hit-test / drag / opt-click all prefer the point where they overlap.
- (BOOL)pointHandleBeatsRotation {
  return NO;
}

#pragma mark - Rotation gizmo: small accessor defaults

- (KKRotationAxes)rotationEnabledAxes {
  return KKRotationAxesAll;
}

// Expand a lane value (one component per enabled axis, X/Y/Z order) to a full
// [X,Y,Z] Euler in degrees; disabled axes read 0.
- (NSArray<NSNumber *> *)_eulerDegFromLaneValues:(NSArray<NSNumber *> *)v {
  KKRotationAxes axes = [self rotationEnabledAxes];
  double xyz[3] = {0.0, 0.0, 0.0};
  NSUInteger idx = 0;
  if (axes & KKRotationAxisX)
    xyz[0] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
  if (axes & KKRotationAxisY)
    xyz[1] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
  if (axes & KKRotationAxisZ)
    xyz[2] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
  return @[ @(xyz[0]), @(xyz[1]), @(xyz[2]) ];
}

// Collapse a full [X,Y,Z] Euler back to the lane's components (enabled axes
// only, X/Y/Z order).
- (NSArray<NSNumber *> *)_laneValuesFromEulerDeg:(NSArray<NSNumber *> *)e {
  KKRotationAxes axes = [self rotationEnabledAxes];
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  if (axes & KKRotationAxisX)
    [out addObject:e[0]];
  if (axes & KKRotationAxisY)
    [out addObject:e[1]];
  if (axes & KKRotationAxisZ)
    [out addObject:e[2]];
  return out;
}

- (NSArray<NSNumber *> *)rotationEulerDegrees {
  NSString *label = self.rotationLabel;
  if (!label)
    return @[ @0.0, @0.0, @0.0 ];
  // ROOT value: this drives the rotation GIZMO (ring draw, hit-test, drag
  // seed), which edits the lane's own value - not the link-expression result
  // (else a drag would compound). The rendered object uses the resolved
  // valuesForLabel:.
  return [self _eulerDegFromLaneValues:[self rootValuesForLabel:label]];
}

- (CGPoint)rotationCenterForContentRect:(CGRect)cr {
  return CGPointMake(CGRectGetMidX(cr), CGRectGetMidY(cr));
}

- (KKRotMatrix3)rotationBaseMatrix {
  return KKRotMatrixIdentity();
}

- (CGPoint)scaleAnchorFrac {
  // OPT-IN: default symmetric (no scale-from-anchor). A plugin whose render
  // scales about the anchor overrides this to map its Anchor lane to a
  // fraction.
  return CGPointZero;
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
  CGFloat h = canvas.oscSizingHeight;
  CGFloat scale = (h > 0) ? (h / kKKRotationBaselineCanvasH) : 1.0;
  return kKKRotationBaselineRadiusPt * scale;
}

#pragma mark - Rotation gizmo: state machine (default impls)

// The displayed world matrix = parent/group rotation · the object's own Euler.
// Used for drawing the rings, hit-testing them, and the drag tangent, so a
// nested object's rings show + drag in the parent's frame; the written value
// stays the object's own Euler (the parent factors out of the compose).
- (KKRotMatrix3)_currentRotationMatrix {
  NSArray<NSNumber *> *r = [self rotationEulerDegrees];
  double xDeg = r[0].doubleValue;
  double yDeg = r[1].doubleValue;
  double zDeg = r[2].doubleValue;
  KKRotMatrix3 pose = KKBuildRotationMatrix((float)(xDeg * M_PI / 180.0),
                                            (float)(yDeg * M_PI / 180.0),
                                            (float)(zDeg * M_PI / 180.0));
  return KKRotMatrixMul([self rotationBaseMatrix], pose);
}

// Converts an NSColor to the simd_float4 the rotation shader wants.
static simd_float4 KKMiniRotationColorToFloat4(NSColor *color) {
  NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  CGFloat r = 1, g = 1, b = 1, a = 1;
  [c getRed:&r green:&g blue:&b alpha:&a];
  return (simd_float4){(float)r, (float)g, (float)b, (float)a};
}

// Reveal mode only bites when the host wired the toggle (so plugins that don't
// support opt-hide are untouched). A locked layer is never revealed - Opt-hold
// can't peek a non-interactive OSC into existence.
- (BOOL)_revealActive {
  return !_handlesLocked && _revealHidden &&
         self.onHandleVisibilityToggled != nil;
}

// The mini's inputs to the shared visibility rules (KKOSCVisibilityModel) -
// every shown/ghost/peek decision below routes through the model so the mini
// cannot drift from the viewer's KKOnScreenControl rules.
- (KKOSCVisibilityState)_visibilityState {
  return (KKOSCVisibilityState){.locked = _handlesLocked,
                                .masterOff = _handlesHidden,
                                .revealActive = [self _revealActive]};
}

// "Peek and use" mode: the master is off (handlesHidden) and Opt is held.
// Every control reveals and is interactive, so its ghost draws at FULL alpha.
- (BOOL)_peekActive {
  return KKOSCVisibilityPeek([self _visibilityState]);
}

// A handle/element is "user-hidden" (master tick off or its own pill off) -
// eligible to be revealed as a ghost. Boundary-phase suppression is separate.
- (BOOL)_userHiddenLabel:(NSString *)label {
  return _handlesHidden || [self _individuallyHiddenLabel:label];
}

// Hidden by its own pill (or a hidden dot-hierarchy ancestor), independent of
// the master tick.
- (BOOL)_individuallyHiddenLabel:(NSString *)label {
  return KKOSCLabelHiddenInSet(_hiddenHandleLabels, label);
}

// Whether `label`'s handle should be drawn + hit-tested this frame.
- (BOOL)_shownLabel:(NSString *)label {
  return KKOSCVisibilityShown([self _visibilityState],
                              [self _individuallyHiddenLabel:label]);
}

// A specific rotation ring is user-hidden if the master tick is off, the whole
// Rotation compound is hidden, or that ring's own key is hidden. The popover
// stores ring keys as "<rotationLabel>.X/.Y/.Z" (e.g. @"Rotation.X") - the
// parent-compound rule is the model's dot-hierarchy walk.
- (BOOL)_ringUserHiddenAtAxis:(int)k {
  if (_handlesHidden)
    return YES;
  return [self _ringIndividuallyHiddenAtAxis:k];
}

- (NSString *)_ringKeyAtAxis:(int)k {
  NSString *axis = (k == 0) ? @"X" : (k == 1) ? @"Y" : @"Z";
  return [NSString stringWithFormat:@"%@.%@", self.rotationLabel, axis];
}

// As above but independent of the master tick: the ring's own pill, or its
// parent Rotation compound, turned off.
- (BOOL)_ringIndividuallyHiddenAtAxis:(int)k {
  if (!self.rotationLabel)
    return NO;
  return KKOSCLabelHiddenInSet(_hiddenHandleLabels, [self _ringKeyAtAxis:k]);
}

// Ring is drawn / hit-tested this frame. Same model rule as -_shownLabel:.
- (BOOL)_ringShownAtAxis:(int)k {
  // A disabled axis (e.g. X/Y on a 2D plugin's Z-only rotation) never shows or
  // hit-tests.
  if (!([self rotationEnabledAxes] & (1 << k)))
    return NO;
  return KKOSCVisibilityShown([self _visibilityState],
                              [self _ringIndividuallyHiddenAtAxis:k]);
}

// Per-ring draw alpha: dim when it's a revealed ghost, full in peek mode.
- (float)_ringAlphaAtAxis:(int)k {
  return KKOSCVisibilityGhostAlpha([self _visibilityState],
                                   [self _ringUserHiddenAtAxis:k]);
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
  // Built-in path is the classic full 3-axis gizmo: every ring under the one
  // pose (trackball semantics).
  KKRotationOSCParamsSetRingBases(&p, m, m, m);
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
  NSArray<NSNumber *> *euler =
      @[ @(rx * kRadToDeg), @(ry * kRadToDeg), @(rz * kRadToDeg) ];
  // Persist only the enabled axes (the lane carries one component per axis).
  [self commitValues:[self _laneValuesFromEulerDeg:euler]
            forLabel:label
              canvas:canvas];
}

#pragma mark - Provided to subclasses

// The mini viewer is the *constants* editor: a property's handle shows only
// while it's a constant. Every property always has a lane; `enabled` means
// animatable (dropdown-controlled). Constant == the lane is absent or not
// enabled. Editing a value preserves `enabled`, so the handle stays put
// through a drag - no mid-drag exemption needed.
- (BOOL)isConstantLabel:(NSString *)label {
  for (KKLane *lane in self.timeline.lanes)
    if ([lane.key isEqualToString:label])
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
    if (![lane.key isEqualToString:label])
      continue;
    // An expression-driven lane resolves through the same path the render uses
    // (its own value plus any `${refs}` sampled at the playhead's project time)
    // so the mini-viewer PREVIEW matches - this method feeds the shader-uniform
    // reads that draw the object. Non-expression lanes keep the plain sampler.
    // NB: the OSC handles must NOT use this (they'd seed a drag from value*expr
    // and compound the write) - they read `rootValuesForLabel:` instead.
    if (lane.linkExpression.length) {
      // Resolve `${refs}` that point at a lane in THIS SAME clip to the LIVE
      // timeline value, not the published bus curve. The bus only updates on
      // commit, so a derived lane (e.g. rotation = min(${...Split}, 90)) would
      // otherwise lag its source until mouse-up. When static the timeline and
      // bus agree, so this is byte-identical then; during an edit the timeline
      // is live, so the derived lane tracks in real time. Identity-checked by
      // KKLinkSelfClipLaneForRef: another clip, another layer, or a param with
      // no lane here falls through to the bus (republished by its source every
      // tick), as does an expression-driven source (resolved recursively
      // there).
      KKTimeline *tl = self.timeline;
      double editFrac = self.editFraction;
      NSString *selfUUID = self.linkSelfUUID;
      KKLinkRefOverride refOverride =
          ^NSArray<NSNumber *> *(NSString *refName) {
        KKLane *l = KKLinkSelfClipLaneForRef(refName, selfUUID, tl.lanes);
        if (!l || l.linkExpression.length)
          return nil;
        // Display evaluation, matching what the bus publishes for this
        // source when static - a raw read here would skip the visual
        // projection + join smoothing the committed curve carries.
        return KKLaneDisplayValueAtFraction(l, editFrac);
      };
      NSArray<NSNumber *> *rv = KKLinkResolvedLaneValueWithOverride(
          lane, self.editFraction, self.linkTimelineSec,
          self.clipDurationSeconds, refOverride);
      if (rv.count > 0)
        return rv;
    }
    // Display evaluation (visual projection + join smoothing), matching the
    // real render - this feeds the shader-uniform reads that draw the object.
    // A raw read here made the mini's picture skip the Basic hold projection
    // and the C1 join fillet the FCP render applies.
    NSArray<NSNumber *> *v =
        KKLaneDisplayValueAtFraction(lane, self.editFraction);
    if (v.count > 0)
      return v;
  }
  return [self defaultValuesForLabel:label];
}

- (NSArray<NSNumber *> *)rootValuesForLabel:(NSString *)label {
  // The lane's OWN value (NO link-expression resolution) - what the OSC handles
  // edit. Identical to valuesForLabel: minus the expression pass: same
  // live-drag override, same sampler, same default. An OSC drag on an
  // expression lane must seed + write THIS (else it seeds from value*expr and
  // compounds the write); the rendered object still uses the resolved
  // valuesForLabel:, so the handle sits at the root value just like the main
  // FCP viewer's OSC.
  if (_hasLiveFraction) {
    NSArray<NSNumber *> *live = _liveValues[label];
    if (live.count > 0 && fabs(self.editFraction - _liveFraction) < 1e-4)
      return live;
  }
  for (KKLane *lane in self.timeline.lanes) {
    if (![lane.key isEqualToString:label])
      continue;
    NSArray<NSNumber *> *v =
        KKTimelineLaneValueAtFraction(lane, self.editFraction);
    if (v.count > 0)
      return v;
  }
  return [self defaultValuesForLabel:label];
}

// Filmstrip/onion fan-out for a generator: the distinct keypose times across
// the ANIMATED lanes. Mirrors what the boundary popover collects for a source
// plugin (every kp.time on enabled lanes, snapped + de-duplicated), but derived
// straight from our own timeline - a generator has no FCP source round-trip.
// A constant-only timeline yields [0] (one cell).
- (NSArray<NSNumber *> *)miniViewerKeyposeFractions:(KKMiniViewerView *)canvas {
  NSMutableArray<NSNumber *> *fracs = [NSMutableArray array];
  for (KKLane *lane in self.timeline.lanes) {
    if (!lane.enabled) // constants (single t=0 keypose) don't fan out
      continue;
    for (KKKeyPose *kp in lane.keyposes) {
      double t = MAX(0.0, MIN(1.0, kp.time));
      BOOL dup = NO;
      for (NSNumber *f in fracs)
        if (fabs(f.doubleValue - t) < 1e-4) {
          dup = YES;
          break;
        }
      if (!dup)
        [fracs addObject:@(t)];
    }
  }
  if (fracs.count == 0)
    return @[ @0.0 ];
  [fracs sortUsingSelector:@selector(compare:)];
  return fracs;
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
  // The boundary (keypose) popover in a multi-owner timeline passes a
  // LAYER-TAGGED label ("Stroke Width\x1f<id>"), but this renderer's timeline
  // is single-owner with PLAIN labels - so match on the plain label or the live
  // value edit finds no lane and the mini never re-renders (it worked in
  // Constants only because that popover is single-owner / plain). No-op for
  // single-owner plugins (plain == plain).
  NSString *plain = KKPlainLaneLabel(label);
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
      if (![KKPlainLaneLabel(lanes[i].key) isEqualToString:plain])
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
    if ([KKPlainLaneLabel(lanes[i].key) isEqualToString:plain]) {
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
    KKLane *lane = tmpl ? [tmpl copy] : [KKLane laneWithKey:label label:label];
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
  return [self _encodeProcessedSource:source into:dest commandBuffer:cb];
}

- (BOOL)_encodeProcessedSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  if ([self _motionBlurSampleCount] >= 2) {
    // Fast first when the subclass can do it: fixed cost instead of N renders.
    // It declines (returns NO) if unsupported or setup fails, and accumulate is
    // the correct fallback in both cases.
    if (_previewMotionBlurTechnique == 0 &&
        [self encodeFastMotionBlurFromSource:source
                                        into:dest
                             shutterFraction:_previewMotionBlurShutterSeconds /
                                             _clipDurationSeconds
                               commandBuffer:cb])
      return YES;
    return [self _encodeMotionBlurredFromSource:source
                                           into:dest
                                  commandBuffer:cb];
  }
  return [self encodeEffectFromSource:source into:dest commandBuffer:cb];
}

- (BOOL)encodeFastMotionBlurFromSource:(id<MTLTexture>)source
                                  into:(id<MTLTexture>)dest
                       shutterFraction:(double)shutterFraction
                         commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  return NO; // no velocity buffer by default
}

// 0 = don't blur. Every term has to be usable: the shutter only becomes a clip
// FRACTION (which is all `editFraction` understands) once the clip duration is
// known.
- (NSInteger)_motionBlurSampleCount {
  if (!_previewMotionBlurEnabled || _previewMotionBlurSamples < 2 ||
      _previewMotionBlurShutterSeconds <= 0.0 || _clipDurationSeconds <= 0.0)
    return 0;
  return MIN(_previewMotionBlurSamples, (NSInteger)KK_MOTION_BLUR_MAX_SAMPLES);
}

// Pooled sample targets, one per sample, matching dest's size and format.
// Rebuilt only when those change - the preview redraws at 60fps, so allocating
// per frame would churn badly at high sample counts.
- (NSArray<id<MTLTexture>> *)_motionBlurSampleTexturesCount:(NSInteger)n
                                                       like:(id<MTLTexture>)dest {
  if (_mbSampleTextures.count == (NSUInteger)n && _mbSampleW == dest.width &&
      _mbSampleH == dest.height && _mbSampleFormat == dest.pixelFormat)
    return _mbSampleTextures;

  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:dest.pixelFormat
                                   width:dest.width
                                  height:dest.height
                               mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  NSMutableArray<id<MTLTexture>> *out = [NSMutableArray arrayWithCapacity:n];
  for (NSInteger i = 0; i < n; i++) {
    id<MTLTexture> t = [dest.device newTextureWithDescriptor:td];
    if (!t)
      return nil;
    [out addObject:t];
  }
  _mbSampleTextures = out;
  _mbSampleW = dest.width;
  _mbSampleH = dest.height;
  _mbSampleFormat = dest.pixelFormat;
  return _mbSampleTextures;
}

- (BOOL)_encodeMotionBlurredFromSource:(id<MTLTexture>)source
                                  into:(id<MTLTexture>)dest
                         commandBuffer:(id<MTLCommandBuffer>)cb {
  NSInteger n = [self _motionBlurSampleCount];
  NSArray<id<MTLTexture>> *samples = [self _motionBlurSampleTexturesCount:n
                                                                    like:dest];
  id<MTLRenderPipelineState> acc = [self _motionBlurAccumulatePipelineFor:dest];
  if (samples.count != (NSUInteger)n || !acc) // fall back rather than draw nothing
    return [self encodeEffectFromSource:source into:dest commandBuffer:cb];

  // Match the render's sample distribution exactly (see
  // +[KKMotionBlur sampleTimesForState:]): the window TRAILS the frame,
  // spanning [t - shutter, t], so the blur streaks behind the current position.
  // Centring it here would put the smear on the wrong side of the movement.
  double shutterFrac = _previewMotionBlurShutterSeconds / _clipDurationSeconds;
  double base = _editFraction;
  BOOL ok = YES;
  _previewMotionBlurSampling = YES;
  for (NSInteger i = 0; i < n && ok; i++) {
    double t = (double)i / (double)(n - 1);
    // Assign the ivar, not the property: subclasses may react to the setter,
    // and this is a transient value restored before anything else observes it.
    _editFraction = MAX(0.0, MIN(1.0, base - shutterFrac * t));
    ok = [self encodeEffectFromSource:source
                                 into:samples[i]
                        commandBuffer:cb];
  }
  _previewMotionBlurSampling = NO;
  _editFraction = base;
  if (!ok)
    return [self encodeEffectFromSource:source into:dest commandBuffer:cb];

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> enc =
      [cb renderCommandEncoderWithDescriptor:rpd];
  float dw = (float)dest.width, dh = (float)dest.height;
  [enc setViewport:(MTLViewport){0, 0, dw, dh, -1.0, 1.0}];
  KKVertex2D verts[] = {
      {{dw / 2.0f, -dh / 2.0f}, {1.0, 1.0}},
      {{-dw / 2.0f, -dh / 2.0f}, {0.0, 1.0}},
      {{dw / 2.0f, dh / 2.0f}, {1.0, 0.0}},
      {{-dw / 2.0f, dh / 2.0f}, {0.0, 0.0}},
  };
  simd_uint2 vp = {(unsigned)dw, (unsigned)dh};
  [enc setVertexBytes:verts
               length:sizeof(verts)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&vp length:sizeof(vp) atIndex:KKVertexInputIndex_ViewportSize];
  [enc setRenderPipelineState:acc];
  for (NSUInteger i = 0; i < samples.count; i++)
    [enc setFragmentTexture:samples[i] atIndex:i];
  int sc = (int)n;
  [enc setFragmentBytes:&sc length:sizeof(sc) atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [enc endEncoding];
  return YES;
}

- (id<MTLRenderPipelineState>)_motionBlurAccumulatePipelineFor:
    (id<MTLTexture>)dest {
  // Same shader the render path accumulates with, so the averaging matches.
  return [[KKMetalDeviceCache sharedCache]
      buildAndRegisterPipelineStateForPluginID:@"KKMiniViewerMotionBlur"
                                    registryID:dest.device.registryID
                                   pixelFormat:dest.pixelFormat
                                      bundleID:[NSBundle bundleForClass:[KKMiniViewerRenderer class]]
                                                   .bundleIdentifier
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKMotionBlurAccumulateFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
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

- (void)setHandlesLocked:(BOOL)handlesLocked {
  if (_handlesLocked == handlesLocked)
    return;
  _handlesLocked = handlesLocked;
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
  return [self ghostAlphaForLabel:self.cropLabel];
}

- (CGFloat)scaleGhostAlpha {
  return 1.0; // no scale box by default; subclasses override
}

- (CGFloat)anchorSquareGhostAlpha {
  return 1.0; // no anchor square by default; subclasses override
}

- (CGFloat)positionHandleGhostAlpha {
  return 1.0; // no secondary Position handle by default; subclasses override
}

- (BOOL)positionHandleIsActive {
  return NO; // no secondary Position handle by default; subclasses override
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
  return [self ghostAlphaForLabel:self.pointLabel];
}

- (BOOL)labelVisibleOrRevealing:(NSString *)label {
  return [self _shownLabel:label];
}

- (CGFloat)ghostAlphaForLabel:(NSString *)label {
  return KKOSCVisibilityGhostAlpha([self _visibilityState],
                                   [self _userHiddenLabel:label]);
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
    // A single-axis rotation gizmo is keyed on the FLAT label (matching the
    // viewer OSC's -oscElementKeyForActivePart:); only a multi-axis gizmo
    // qualifies the key by axis. Emitting "Rotation.Z" for a single-axis lane
    // would toggle a key nothing else checks, so the hide would silently no-op.
    KKRotationAxes axes = [self rotationEnabledAxes];
    BOOL singleAxis = axes != 0 && (axes & (axes - 1)) == 0;
    if (singleAxis) {
      label = self.rotationLabel;
    } else {
      NSString *axis = (_rotActiveAxis == 0)   ? @"X"
                       : (_rotActiveAxis == 1) ? @"Y"
                                               : @"Z";
      label = [NSString stringWithFormat:@"%@.%@", self.rotationLabel, axis];
    }
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

// THE aggregate element assembly: translate every legacy per-kind hook into
// typed KKMiniElement descriptors, in the canvas's historical draw order
// (rings, motion paths, boxes, rotations, primary point, extra glyphs, fixed
// glyphs, anchor square, secondary Position arc). Subclasses keep overriding
// the legacy hooks and inherit the descriptor surface for free; a subclass
// that has outgrown the hooks overrides THIS instead and returns elements
// directly. The view consults ONLY this for OSC drawing.
- (NSArray<KKMiniElement *> *)miniViewer:(KKMiniViewerView *)canvas
                  elementsForContentRect:(CGRect)cr {
  NSMutableArray<KKMiniElement *> *els = [NSMutableArray array];
  self.canvas = canvas;

  // Single ring OSC (radius ring) - emphasis + ghost from the legacy hooks.
  {
    CGPoint c = CGPointZero;
    CGFloat rx = 0, ry = 0;
    if ([self respondsToSelector:@selector(miniViewer:ringCenter:radiusX:
                                           radiusY:contentRect:)] &&
        [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                                        ringCenter:&c
                                           radiusX:&rx
                                           radiusY:&ry
                                       contentRect:cr] &&
        rx > 0.5 && ry > 0.5) {
      NSInteger emph =
          [self respondsToSelector:@selector(miniViewerRingEmphasis:)]
              ? [(id<KKMiniViewerDelegate>)self miniViewerRingEmphasis:canvas]
              : 0;
      CGFloat a =
          [self respondsToSelector:@selector(miniViewerRingGhostAlpha:)]
              ? [(id<KKMiniViewerDelegate>)self miniViewerRingGhostAlpha:canvas]
              : 1.0;
      [els addObject:[KKMiniElement ringAt:c
                                   radiusX:rx
                                   radiusY:ry
                                  emphasis:emph
                                     alpha:a]];
    }
  }
  // Extra rings (multiple dynamic ring OSCs).
  if ([self
          respondsToSelector:@selector(miniViewer:extraRingsForContentRect:)]) {
    for (NSDictionary<NSString *, id> *b in
         [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                           extraRingsForContentRect:cr]) {
      CGFloat rx = [b[@"radiusX"] doubleValue];
      CGFloat ry = [b[@"radiusY"] doubleValue];
      if (rx <= 0.5 || ry <= 0.5)
        continue;
      [els addObject:[KKMiniElement
                           ringAt:[b[@"center"] pointValue]
                          radiusX:rx
                          radiusY:ry
                         emphasis:[b[@"emphasis"] integerValue]
                            alpha:b[@"alpha"] ? [b[@"alpha"] doubleValue]
                                              : 1.0]];
    }
  }

  // Primary motion path (Position trajectory + tangents + anchors).
  if ([self respondsToSelector:
                @selector(miniViewer:motionPathPolylineForContentRect:)]) {
    NSArray<NSValue *> *poly = [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                                         motionPathPolylineForContentRect:cr];
    NSArray<NSValue *> *segs =
        [self respondsToSelector:
                  @selector(miniViewer:motionPathHandleSegmentsForContentRect:)]
            ? [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                  motionPathHandleSegmentsForContentRect:cr]
            : nil;
    NSArray<NSValue *> *anchors =
        [self
            respondsToSelector:@selector(
                                   miniViewer:motionPathAnchorsForContentRect:)]
            ? [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                         motionPathAnchorsForContentRect:cr]
            : nil;
    if (poly.count >= 2 || segs.count || anchors.count)
      [els addObject:[KKMiniElement
                         motionPathWithPolyline:poly
                                 handleSegments:segs
                                        anchors:anchors
                                          alpha:[self motionPathGhostAlpha]]];
  }
  // Extra motion paths (one per additional point OSC).
  if ([self
          respondsToSelector:@selector(
                                 miniViewer:extraMotionPathsForContentRect:)]) {
    for (NSDictionary<NSString *, id> *b in
         [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                     extraMotionPathsForContentRect:cr]) {
      [els addObject:[KKMiniElement
                         motionPathWithPolyline:b[@"poly"]
                                 handleSegments:b[@"segs"]
                                        anchors:b[@"anchors"]
                                          alpha:b[@"alpha"]
                                                    ? [b[@"alpha"] doubleValue]
                                                    : 1.0]];
    }
  }

  // Boxes (crop / scale / future box gizmos). Element alpha = the box's own
  // ghostAlpha - the per-kind cropGhostAlpha hook dissolves into the element.
  if ([self respondsToSelector:@selector(miniViewer:boxesForContentRect:)]) {
    for (KKMiniBox *box in [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                                                  boxesForContentRect:cr]) {
      KKMiniElement *e = [KKMiniElement boxWithRect:box.rect
                                      handleCenters:box.handleCenters
                                            readout:box.readout
                                              alpha:box.ghostAlpha];
      e.sizeScale = [self pointHandleSizeScale]; // box handles match the dots
      [els addObject:e];
    }
  }

  // Rotation gizmos: the single delegate path (which carries the base's
  // visibility gating) + the multi array.
  {
    CGPoint c = CGPointZero;
    CGFloat r = 0;
    KKRotationOSCParams p = {0};
    if ([self respondsToSelector:@selector(miniViewer:rotationOSCCenter:
                                           radiusPx:params:contentRect:)] &&
        [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                                 rotationOSCCenter:&c
                                          radiusPx:&r
                                            params:&p
                                       contentRect:cr])
      [els addObject:[KKMiniElement rotationAt:c radiusPx:r params:p]];
  }
  if ([self respondsToSelector:@selector(
                                   miniViewer:rotationOSCsForContentRect:)]) {
    for (KKMiniRotation *r in [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                                              rotationOSCsForContentRect:cr])
      [els addObject:[KKMiniElement rotationAt:r.center
                                      radiusPx:r.radiusPx
                                        params:r.params]];
  }

  // Primary point handle - style/active/ghost fold onto the element.
  {
    CGPoint c = CGPointZero;
    if ([self respondsToSelector:
                  @selector(miniViewer:pointHandleCenter:contentRect:)] &&
        [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                                 pointHandleCenter:&c
                                       contentRect:cr]) {
      KKMiniElement *e = [KKMiniElement glyphAt:c
                                          style:[self pointHandleStyle]
                                          alpha:[self pointHandleGhostAlpha]];
      e.active = [self pointHandleIsActive];
      e.sizeScale = [self pointHandleSizeScale];
      e.label = self.pointLabel;
      [els addObject:e];
    }
  }
  // Extra point handles (every one drawn with the primary's style).
  if ([self respondsToSelector:
                @selector(miniViewer:extraPointHandleGlyphsForContentRect:)]) {
    for (NSDictionary<NSString *, id> *g in
         [(id<KKMiniViewerDelegate>)self miniViewer:canvas
               extraPointHandleGlyphsForContentRect:cr]) {
      KKMiniElement *e =
          [KKMiniElement glyphAt:[g[@"center"] pointValue]
                           style:[self pointHandleStyle]
                           alpha:g[@"alpha"] ? [g[@"alpha"] doubleValue] : 1.0];
      e.sizeScale = [self pointHandleSizeScale];
      [els addObject:e];
    }
  }
  // Fixed-glyph handles (style chosen per handle).
  if ([self
          respondsToSelector:@selector(
                                 miniViewer:extraFixedGlyphsForContentRect:)]) {
    for (NSDictionary<NSString *, id> *g in
         [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                     extraFixedGlyphsForContentRect:cr]) {
      KKMiniElement *e =
          [KKMiniElement glyphAt:[g[@"center"] pointValue]
                           style:[g[@"style"] integerValue]
                           alpha:g[@"alpha"] ? [g[@"alpha"] doubleValue] : 1.0];
      e.whiteFill = [g[@"white"] boolValue];
      e.sizeScale = [self pointHandleSizeScale];
      [els addObject:e];
    }
  }

  // Anchor pivot square (topmost-but-one, matching viewer layering).
  {
    CGPoint c = CGPointZero;
    if ([self respondsToSelector:
                  @selector(miniViewer:anchorSquareCenter:contentRect:)] &&
        [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                                anchorSquareCenter:&c
                                       contentRect:cr]) {
      KKMiniElement *e = [KKMiniElement glyphAt:c
                                          style:KKMiniHandleStyleSquare
                                          alpha:[self anchorSquareGhostAlpha]];
      e.sizeScale = [self pointHandleSizeScale];
      [els addObject:e];
    }
  }

  // Secondary Position arc handle (topmost).
  {
    CGPoint c = CGPointZero;
    if ([self respondsToSelector:
                  @selector(miniViewer:positionHandleCenter:contentRect:)] &&
        [(id<KKMiniViewerDelegate>)self miniViewer:canvas
                              positionHandleCenter:&c
                                       contentRect:cr]) {
      KKMiniElement *e =
          [KKMiniElement glyphAt:c
                           style:KKMiniHandleStyleArc
                           alpha:[self positionHandleGhostAlpha]];
      e.active = [self positionHandleIsActive];
      [els addObject:e];
    }
  }

  return els;
}

@end
