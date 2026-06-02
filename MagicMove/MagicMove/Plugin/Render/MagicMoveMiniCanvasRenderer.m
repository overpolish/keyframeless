/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MagicMoveMiniCanvasRenderer.h"
#import "MagicMoveParamsBuild.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>

NSString *const MagicMoveMiniCanvasDescriptorPath =
    @"/tmp/magicmove-minicanvas.json";
NSString *const MagicMoveMiniCanvasRequestPath =
    @"/tmp/magicmove-minicanvas-request.json";

NSString *MagicMoveMiniCanvasDescriptorPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MagicMoveMiniCanvasDescriptorPath;
  return [NSString stringWithFormat:@"/tmp/magicmove-minicanvas-%@.json", uuid];
}

NSString *MagicMoveMiniCanvasRequestPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MagicMoveMiniCanvasRequestPath;
  return [NSString
      stringWithFormat:@"/tmp/magicmove-minicanvas-request-%@.json", uuid];
}

static const CGFloat kHandleHitTolPt = 12.0;

// Scale box extent as a fraction of the content rect's min dimension (so it
// tracks the clip / scales with preview zoom). Mirrors the viewer's fractions.
static const double kMiniScaleE0Frac = 0.12;
static const double kMiniScaleSpanFrac = 0.057;
// Cmd-fine drag multiplier (matches the viewer).
static const double kMiniScaleFineFactor = 0.2;

@interface MagicMoveMiniCanvasRenderer () {
  KKSnapEngine *_snapEngine;
  // Normalised press point captured at begin-drag; used as the Shift
  // axis-lock anchor so the locked axis stays pinned where it was, not
  // wherever the cursor most recently passed through.
  double _posPressNX;
  double _posPressNY;
  // Position value at grab, for delta dragging (move by the cursor's offset
  // from the press point) instead of snapping the handle to the cursor -
  // matches the viewer OSC.
  double _posGrabValX;
  double _posGrabValY;
  // Pipeline cache keyed by (device, pixelFormat) - the plugin's own metallib
  // is in this XPC process's bundle, so we build a real PSO and apply the
  // shader source → dest locally. No FxPlug round-trip = no Flexo lock
  // contention = no deadlock during live drag.
  id<MTLRenderPipelineState> _pipeline;
  id<MTLDevice> _pipelineDevice;
  MTLPixelFormat _pipelineFormat;
  // Motion-path drag: which keypose + which part (0=anchor, 1=out, 2=in).
  BOOL _pathGrabbed;
  NSInteger _pathIndex;
  NSInteger _pathPart;
  double _pathPressNX;
  double _pathPressNY;
  double _pathGrabValX; // keypose value at grab (delta-drag anchor)
  double _pathGrabValY;
  // Scale box drag (mirrors the viewer OSC's absolute + Cmd-fine model).
  BOOL _scaleGrabbed;
  NSInteger _scaleGrabHandle; // 0-7
  CGPoint _scalePressCenter;
  double _scalePressSclX;
  double _scalePressSclY;
  CGPoint _scaleEffCursor; // effective cursor (starts at the grabbed handle)
  CGPoint _scaleLastCursor;
  // Anchor-square drag: delta-based like Position (snap off unless Cmd).
  BOOL _anchorGrabbed;
  double _anchorGrabValX;
  double _anchorGrabValY;
  double _anchorPressNX;
  double _anchorPressNY;
}
@end

@implementation MagicMoveMiniCanvasRenderer

- (instancetype)init {
  if ((self = [super init])) {
    _snapEngine = [[KKSnapEngine alloc] init];
  }
  return self;
}

// Builds (or returns cached) MTLRenderPipelineState for MagicMove's
// vertex/fragment shader in this process. The plugin XPC has the plugin
// bundle's default.metallib loaded, so we can grab the functions directly.
- (id<MTLRenderPipelineState>)_pipelineForDevice:(id<MTLDevice>)device
                                     pixelFormat:(MTLPixelFormat)format {
  if (_pipeline && _pipelineDevice == device && _pipelineFormat == format)
    return _pipeline;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:[self class]]
                                    error:&err];
  if (!lib) {
    KKLogError(@"MagicMoveMiniCanvasRenderer: no metallib: %@", err);
    return nil;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"vertexShader"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"fragmentShader"];
  if (!vfn || !ffn) {
    KKLogError(@"MagicMoveMiniCanvasRenderer: missing shader functions");
    return nil;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = vfn;
  pd.fragmentFunction = ffn;
  pd.colorAttachments[0].pixelFormat = format;
  pd.colorAttachments[0].blendingEnabled = YES;
  pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
  pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  pd.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  pd.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"MagicMoveMiniCanvasRenderer: pipeline build failed: %@", err);
    return nil;
  }
  _pipeline = ps;
  _pipelineDevice = device;
  _pipelineFormat = format;
  return _pipeline;
}

static KKLane *KKMagicMoveLaneNamed(KKTimeline *timeline, NSString *label) {
  for (KKLane *lane in timeline.lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

// Builds the params at the renderer's current edit fraction. Current Position
// + Rotation values go through `valuesForLabel:` so the popover's live-drag
// override wins; the rotate-with-motion velocity sample reads the persisted
// timeline directly (the prev-tick reference must be the committed history,
// not the in-flight drag value). Mirrors the FCP render path's output so
// the mini preview matches what FCP eventually bakes.
static void KKMagicMoveBuildParams(MagicMoveParams *outParams,
                                   MagicMoveMiniCanvasRenderer *renderer) {
  NSArray<NSNumber *> *positionVals = [renderer valuesForLabel:@"Position"];
  NSArray<NSNumber *> *rotationVals = [renderer valuesForLabel:@"Rotation"];
  NSArray<NSNumber *> *scaleVals = [renderer valuesForLabel:@"Scale"];
  NSArray<NSNumber *> *opacityVals = [renderer valuesForLabel:@"Opacity"];
  NSArray<NSNumber *> *anchorVals = [renderer valuesForLabel:@"Anchor"];
  double posX = positionVals.count > 0 ? positionVals[0].doubleValue : 0.5;
  double posY = positionVals.count > 1 ? positionVals[1].doubleValue : 0.5;
  double rotXdeg = rotationVals.count > 0 ? rotationVals[0].doubleValue : 0.0;
  double rotYdeg = rotationVals.count > 1 ? rotationVals[1].doubleValue : 0.0;
  double rotZdeg = rotationVals.count > 2 ? rotationVals[2].doubleValue : 0.0;
  static const double kDegToRad = M_PI / 180.0;

  KKLane *positionLane = KKMagicMoveLaneNamed(renderer.timeline, @"Position");
  rotZdeg += KKMagicMoveRotateWithMotionAdjustmentDegrees(
      positionLane, renderer.editFraction, positionLane.lastKnownClipDuration);

  outParams->translate =
      (simd_float2){(float)(posX - 0.5), (float)(posY - 0.5)};
  double anchorX = anchorVals.count > 0 ? anchorVals[0].doubleValue : 0.5;
  double anchorY = anchorVals.count > 1 ? anchorVals[1].doubleValue : 0.5;
  outParams->anchorOffset =
      (simd_float2){(float)(anchorX - 0.5), (float)(anchorY - 0.5)};
  outParams->rotation = (float)(rotZdeg * kDegToRad);
  outParams->rotationX = (float)(rotXdeg * kDegToRad);
  outParams->rotationY = (float)(rotYdeg * kDegToRad);
  // Floor at 0 (overshoot easing can dip below 0; negative scale would flip).
  double sclX =
      scaleVals.count > 0 ? fmax(0.0, scaleVals[0].doubleValue) : 100.0;
  double sclY =
      scaleVals.count > 1 ? fmax(0.0, scaleVals[1].doubleValue) : 100.0;
  outParams->scaleX = (float)(sclX / 100.0);
  outParams->scaleY = (float)(sclY / 100.0);
  double opac = opacityVals.count > 0
                    ? fmax(0.0, fmin(100.0, opacityVals[0].doubleValue))
                    : 100.0;
  outParams->opacity = (float)(opac / 100.0);
}

- (NSString *)pointLabel {
  return @"Position";
}

// MagicMove has no Crop lane - return nil so the base renderer doesn't try
// to draw the default crop corner handles (which were showing as a stray
// point in the bottom-left of the mini-canvas).
- (NSString *)cropLabel {
  return nil;
}

- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStyleArc;
}

// The main point handle is an arc (above), so this only sizes the scale-box
// point handles - shrink them like Rounded's so they aren't oversized.
- (CGFloat)pointHandleSizeScale {
  return 0.6;
}

// The Position arc draws on top of the rotation rings (matching the viewer's
// layering), so the hit-test / drag / opt-click prefer it where they overlap.
- (BOOL)pointHandleBeatsRotation {
  return YES;
}

// Apply the real MagicMove shader source → dest, using current lane values
// (which respect the live-override pushed by KK during drag). One path for
// playhead, boundary, filmstrip, onion - they only differ in the value of
// self.editFraction at draw time.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  if (!source || !dest || !cb)
    return NO;
  if (source.width == 0 || source.height == 0 || dest.width == 0 ||
      dest.height == 0)
    return YES;

  id<MTLRenderPipelineState> pso = [self _pipelineForDevice:cb.device
                                                pixelFormat:dest.pixelFormat];
  if (!pso) {
    // Fallback: blit so we don't show black on a transient PSO failure.
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    NSUInteger w = MIN(source.width, dest.width);
    NSUInteger h = MIN(source.height, dest.height);
    [blit copyFromTexture:source
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                toTexture:dest
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    return YES;
  }

  MagicMoveParams params = {0};
  KKMagicMoveBuildParams(&params, self);
  simd_float2 zeroOffset = {0.0f, 0.0f};

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
  float w = (float)dest.width, h = (float)dest.height;
  MTLViewport vp = {0, 0, w, h, -1.0, 1.0};
  [enc setViewport:vp];
  KKVertex2D vertices[4] = {
      {{w / 2.0f, -h / 2.0f}, {1, 1}},
      {{-w / 2.0f, -h / 2.0f}, {0, 1}},
      {{w / 2.0f, h / 2.0f}, {1, 0}},
      {{-w / 2.0f, h / 2.0f}, {0, 0}},
  };
  simd_uint2 viewportSize = {(unsigned)w, (unsigned)h};
  [enc setVertexBytes:vertices
               length:sizeof(vertices)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&viewportSize
               length:sizeof(viewportSize)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setRenderPipelineState:pso];
  [enc setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
  [enc setFragmentBytes:&params
                 length:sizeof(params)
                atIndex:FragmentIndex_Params];
  [enc setFragmentBytes:&zeroOffset
                 length:sizeof(zeroOffset)
                atIndex:FragmentIndex_TileOffsetPx];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
  [enc endEncoding];
  return YES;
}

- (NSInteger)valueTypeForLabel:(NSString *)label {
  if ([label isEqualToString:@"Position"])
    return KKLaneValueTypeGeneric;
  if ([label isEqualToString:@"Rotation"])
    return KKLaneValueTypeAngle;
  return [super valueTypeForLabel:label];
}

- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  // These must match the availableLanes template defaults (and the render
  // reader's fallbacks). Without an entry the base returns zeros, which drew
  // an untouched Anchor at the left edge and an untouched Scale box at 0%.
  if ([label isEqualToString:@"Position"])
    return @[ @0.5, @0.5 ];
  if ([label isEqualToString:@"Rotation"])
    return @[ @0.0, @0.0, @0.0 ];
  if ([label isEqualToString:@"Scale"])
    return @[ @100.0, @100.0 ];
  if ([label isEqualToString:@"Opacity"])
    return @[ @100.0 ];
  if ([label isEqualToString:@"Anchor"])
    return @[ @0.5, @0.5 ];
  return [super defaultValuesForLabel:label];
}

- (CGPoint)_handlePointForContentRect:(CGRect)cr
                             position:(NSArray<NSNumber *> *)pos {
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  return CGPointMake(CGRectGetMinX(cr) + px * cr.size.width,
                     CGRectGetMinY(cr) + py * cr.size.height);
}

- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
    motionPathPolylineForContentRect:(CGRect)cr {
  KKLane *lane = KKMagicMoveLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return @[];
  NSArray<NSValue *> *pts = KKLanePositionPathPoints(lane, 24);
  NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:pts.count];
  for (NSValue *v in pts) {
    NSPoint o = v.pointValue;
    [out addObject:[NSValue
                       valueWithPoint:[self _handlePointForContentRect:cr
                                                              position:@[
                                                                @(o.x), @(o.y)
                                                              ]]]];
  }
  return out;
}

- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
    motionPathAnchorsForContentRect:(CGRect)cr {
  KKLane *lane = KKMagicMoveLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return @[];
  // Skip the keypose under the position handle (nearest editFraction) and
  // coalesce its linked partners; KKLaneCoalescedAnchors dedups the rest. Same
  // helper the viewer uses - returns object-space points to map into the rect.
  NSInteger active = [self _activeAnchorSkipIndexForLane:lane];
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (NSValue *pv in KKLaneCoalescedAnchors(lane, active)) {
    NSPoint v = pv.pointValue;
    [out addObject:[NSValue
                       valueWithPoint:[self _handlePointForContentRect:cr
                                                              position:@[
                                                                @(v.x), @(v.y)
                                                              ]]]];
  }
  return out;
}

- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
    motionPathHandleSegmentsForContentRect:(CGRect)cr {
  KKLane *lane = KKMagicMoveLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return @[];
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    CGPoint anchorPt = [self _handlePointForContentRect:cr position:kp.values];
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint hp =
          [self _handlePointForContentRect:cr
                                  position:@[
                                    @(ax + sides[s].x), @(ay + sides[s].y)
                                  ]];
      [out addObject:[NSValue valueWithPoint:anchorPt]];
      [out addObject:[NSValue valueWithPoint:hp]];
    }
  }
  return out;
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  *outCenter =
      [self _handlePointForContentRect:cr
                              position:[self valuesForLabel:@"Position"]];
  return YES;
}

// Scale transform box (mini-canvas parity with the viewer). Concentric with the
// rotation gizmo (content-rect centre); the half-extents map the Scale percents
// through KKScaleGizmo, anchored to the mini rotation radius with the same
// proportions as the viewer (e0/span = 105/90, 50/90 of the radius).
- (BOOL)_scaleBoxShown {
  if (self.handlesHidden)
    return NO;
  if ([self.suppressedHandleLabels containsObject:@"Scale"])
    return NO;
  // Only when Scale is "active" in the current popover mode: a constant in the
  // constants popover, animated in the keypose popover. Without this, an
  // animated Scale's box wrongly shows in the constants popover.
  if (![self isConstantLabel:@"Scale"])
    return NO;
  return [self labelVisibleOrRevealing:@"Scale"];
}

- (CGFloat)scaleGhostAlpha {
  return [self ghostAlphaForLabel:@"Scale"];
}

- (NSString *)scaleReadoutText {
  if (![self _scaleBoxShown])
    return nil;
  NSArray<NSNumber *> *sv = [self valuesForLabel:@"Scale"];
  double sclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
  double sclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
  return [NSString stringWithFormat:@"%.0f%% x %.0f%%", sclX, sclY];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
      scaleBoxRect:(out CGRect *)outRect
    forContentRect:(CGRect)cr {
  if (![self _scaleBoxShown] || cr.size.width <= 0 || cr.size.height <= 0)
    return NO;
  CGPoint center = [self rotationCenterForContentRect:cr];
  // Size off the content rect (which scales with the preview's zoom/pan), not
  // the fixed popover radius - so the box grows/shrinks with the clip like the
  // viewer box does.
  double crMin = MIN(cr.size.width, cr.size.height);
  double e0 = crMin * kMiniScaleE0Frac, span = crMin * kMiniScaleSpanFrac;
  NSArray<NSNumber *> *sv = [self valuesForLabel:@"Scale"];
  double sclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
  double sclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
  double halfW = KKScaleGizmoExtentForPercent(sclX, e0, span);
  double halfH = KKScaleGizmoExtentForPercent(sclY, e0, span);
  *outRect =
      CGRectMake(center.x - halfW, center.y - halfH, 2 * halfW, 2 * halfH);
  return YES;
}

// Fills out[8] with the scale-box handle centres (0-3 corners BL/BR/TR/TL,
// 4-7 edges bottom/right/top/left) in overlay points. NO if the box isn't
// shown.
- (BOOL)_scaleHandlePositions:(CGPoint *)out forContentRect:(CGRect)cr {
  CGRect sb;
  if (![self miniCanvas:self.canvas scaleBoxRect:&sb forContentRect:cr])
    return NO;
  double l = CGRectGetMinX(sb), r = CGRectGetMaxX(sb);
  double b = CGRectGetMinY(sb), t = CGRectGetMaxY(sb);
  double cx = CGRectGetMidX(sb), cy = CGRectGetMidY(sb);
  out[0] = CGPointMake(l, b);
  out[1] = CGPointMake(r, b);
  out[2] = CGPointMake(r, t);
  out[3] = CGPointMake(l, t);
  out[4] = CGPointMake(cx, b);
  out[5] = CGPointMake(r, cy);
  out[6] = CGPointMake(cx, t);
  out[7] = CGPointMake(l, cy);
  return YES;
}

- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
    scaleHandleCentersForContentRect:(CGRect)cr {
  CGPoint h[8];
  if (![self _scaleHandlePositions:h forContentRect:cr])
    return @[];
  NSMutableArray<NSValue *> *out = [NSMutableArray arrayWithCapacity:8];
  for (int i = 0; i < 8; i++)
    [out addObject:[NSValue valueWithPoint:NSPointFromCGPoint(h[i])]];
  return out;
}

// The Scale transform box, appended to the base's boxes (Magic Move has no
// crop, so super returns none). The shared box path in KKMiniCanvasView draws
// the border + 8 handles + readout uniformly with the crop box.
- (NSArray<KKMiniBox *> *)miniCanvas:(KKMiniCanvasView *)canvas
                 boxesForContentRect:(CGRect)cr {
  NSMutableArray<KKMiniBox *> *boxes = [[super miniCanvas:canvas
                                      boxesForContentRect:cr] mutableCopy];
  CGRect sb;
  if ([self miniCanvas:canvas scaleBoxRect:&sb forContentRect:cr]) {
    [boxes addObject:[KKMiniBox
                           boxWithRect:sb
                         handleCenters:[self miniCanvas:canvas
                                           scaleHandleCentersForContentRect:cr]
                               readout:[self scaleReadoutText]
                            ghostAlpha:[self scaleGhostAlpha]]];
  }
  return boxes;
}

- (BOOL)_scaleHandleHitAtPoint:(CGPoint)p
                   contentRect:(CGRect)cr
                      outIndex:(NSInteger *)outIdx {
  CGPoint h[8];
  if (![self _scaleHandlePositions:h forContentRect:cr])
    return NO;
  NSInteger best = -1;
  double bestD = kHandleHitTolPt;
  for (NSInteger i = 0; i < 8; i++) {
    double d = hypot(p.x - h[i].x, p.y - h[i].y);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  if (best < 0)
    return NO;
  if (outIdx)
    *outIdx = best;
  return YES;
}

// Absolute drag (effective cursor tracks the grabbed handle; Cmd = fine) with
// link-aware coupling (Shift inverts) and integer snapping - mirrors the
// viewer.
- (void)_applyScaleDragToPoint:(CGPoint)p
                   contentRect:(CGRect)cr
                     modifiers:(NSEventModifierFlags)modifiers {
  NSInteger h = _scaleGrabHandle;
  if (h < 0 || cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double rawDx = p.x - _scaleLastCursor.x, rawDy = p.y - _scaleLastCursor.y;
  _scaleLastCursor = p;
  double fine =
      (modifiers & NSEventModifierFlagCommand) ? kMiniScaleFineFactor : 1.0;
  _scaleEffCursor = CGPointMake(_scaleEffCursor.x + rawDx * fine,
                                _scaleEffCursor.y + rawDy * fine);
  CGPoint c = _scalePressCenter;
  double crMin = MIN(cr.size.width, cr.size.height);
  double e0 = crMin * kMiniScaleE0Frac, span = crMin * kMiniScaleSpanFrac;
  double tX =
      KKScaleGizmoPercentForExtent(fabs(_scaleEffCursor.x - c.x), e0, span);
  double tY =
      KKScaleGizmoPercentForExtent(fabs(_scaleEffCursor.y - c.y), e0, span);
  BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
  KKLane *sl = KKMagicMoveLaneNamed(self.timeline, @"Scale");
  BOOL effLinked = (sl.aspectLinked != 0) ^ shift;
  double pX = _scalePressSclX, pY = _scalePressSclY;
  BOOL haveRatio = (pX > 1e-6 && pY > 1e-6);
  double newX = pX, newY = pY;
  BOOL isCorner = (h <= 3);
  BOOL controlsX = isCorner || h == 5 || h == 7;
  if (isCorner) {
    if (effLinked && haveRatio) {
      double f = sqrt((tX / pX) * (tY / pY));
      newX = pX * f;
      newY = pY * f;
    } else {
      newX = tX;
      newY = tY;
    }
  } else if (controlsX) {
    newX = tX;
    newY = effLinked ? (haveRatio ? pY * (tX / pX) : tX) : pY;
  } else { // controls Y (h == 4 || h == 6)
    newY = tY;
    newX = effLinked ? (haveRatio ? pX * (tY / pY) : tY) : pX;
  }
  newX = fmax(0.0, round(newX));
  newY = fmax(0.0, round(newY));
  [self commitValues:@[ @(newX), @(newY) ]
            forLabel:@"Scale"
              canvas:self.canvas];
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)value
           forContentRect:(CGRect)cr {
  // Position is 2D; no single-scalar guide target.
  return NO;
}

- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  CGPoint hp =
      [self _handlePointForContentRect:cr
                              position:[self valuesForLabel:@"Position"]];
  return hypot(p.x - hp.x, p.y - hp.y) <= kHandleHitTolPt;
}

- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniCanvasView *)canvas {
  // No-modifier path is only called on begin (kit's beginHandleDragAtPoint);
  // capture the press normals + the grabbed value here so the drag moves by
  // delta (Shift axis-lock anchors here too).
  if (cr.size.width > 0 && cr.size.height > 0) {
    _posPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
    _posPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  }
  NSArray<NSNumber *> *pv = [self valuesForLabel:@"Position"];
  _posGrabValX = pv.count > 0 ? pv[0].doubleValue : 0.5;
  _posGrabValY = pv.count > 1 ? pv[1].doubleValue : 0.5;
  [self applyPointDragToPoint:p contentRect:cr canvas:canvas modifiers:0];
}

// Mirror of the viewer OSC: snap is OFF by default, Cmd engages it;
// Shift locks to the dominant-travel axis (the other axis pins to the
// press point). Same modifier convention as the viewer's position drag.
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniCanvasView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double nx = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double ny = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  // Delta drag: move the grabbed value by the cursor's offset from the press
  // point, so grabbing off-centre doesn't snap the handle to the cursor.
  double newX = _posGrabValX + (nx - _posPressNX);
  double newY = _posGrabValY + (ny - _posPressNY);
  if (modifiers & NSEventModifierFlagShift) {
    if (fabs(nx - _posPressNX) >= fabs(ny - _posPressNY))
      newY = _posGrabValY;
    else
      newX = _posGrabValX;
  }
  if (modifiers & NSEventModifierFlagCommand) {
    [self _snapPositionX:&newX Y:&newY contentRect:cr];
  } else {
    [_snapEngine reset];
  }
  [self commitValues:@[ @(newX), @(newY) ] forLabel:@"Position" canvas:canvas];
}

// Mini-canvas drag is also called via the delegate dispatcher in
// KKMiniCanvasView so the modifier variant takes precedence over the plain
// one.
- (void)miniCanvas:(KKMiniCanvasView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if (_anchorGrabbed) {
    [self _applyAnchorDragToPoint:p contentRect:cr modifiers:modifiers];
    return;
  }
  if (_pathGrabbed) {
    [self _applyPathDragToPoint:p contentRect:cr modifiers:modifiers];
    return;
  }
  if (_scaleGrabbed) {
    [self _applyScaleDragToPoint:p contentRect:cr modifiers:modifiers];
    return;
  }
  // Rotation drag has to be routed here too - the override was only added
  // so Position could see modifiers, but it accidentally swallowed every
  // non-point drag (rotation rings, crop). Route rotation first, then fall
  // through to point. Crop goes via the base renderer's path on super.
  if ([self rotationIsActive]) {
    [self applyRotationDragToPoint:p
                       contentRect:cr
                            canvas:canvas
                         modifiers:modifiers];
    return;
  }
  if (![self pointHandleIsActive]) {
    [super miniCanvas:canvas
        dragHandleToPoint:p
              contentRect:cr
                modifiers:modifiers];
    return;
  }
  [self applyPointDragToPoint:p
                  contentRect:cr
                       canvas:canvas
                    modifiers:modifiers];
}

// The active keypose's dot is skipped only when the Position handle is actually
// drawn there (full opacity). When the Position OSC is hidden, return -1 so the
// path anchor shows / is grabbable - the active keypose stays editable,
// matching the viewer.
- (NSInteger)_activeAnchorSkipIndexForLane:(KKLane *)lane {
  if ([self ghostAlphaForLabel:@"Position"] < 0.999)
    return -1;
  NSInteger active = -1;
  double bd = 1e9;
  for (NSInteger i = 0; i < (NSInteger)lane.keyposes.count; i++) {
    double dd = fabs(lane.keyposes[i].time - self.editFraction);
    if (dd < bd) {
      bd = dd;
      active = i;
    }
  }
  return active;
}

// The keypose anchor under `p` (excluding the active one, whose dot is hidden
// under the position handle), or NO. Mirrors the viewer's anchor hit-test.
- (BOOL)_pathAnchorHitAtPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                     outIndex:(NSInteger *)outIdx {
  KKLane *lane = KKMagicMoveLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return NO;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSInteger active = [self _activeAnchorSkipIndexForLane:lane];
  double bestD = kHandleHitTolPt;
  NSInteger best = -1;
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    if (i == active || kps[i].values.count < 2)
      continue;
    CGPoint hp = [self _handlePointForContentRect:cr position:kps[i].values];
    double d = hypot(p.x - hp.x, p.y - hp.y);
    if (d <= bestD) {
      bestD = d;
      best = i;
    }
  }
  if (best < 0)
    return NO;
  if (outIdx)
    *outIdx = best;
  return YES;
}

// A smooth keypose's tangent-handle dot under `p`: outputs the keypose index +
// which side (out vs in). Mirrors the viewer's handle hit-test.
- (BOOL)_pathHandleHitAtPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                     outIndex:(NSInteger *)outIdx
                     outIsOut:(BOOL *)outIsOut {
  KKLane *lane = KKMagicMoveLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return NO;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  double bestD = kHandleHitTolPt;
  NSInteger bestI = -1;
  BOOL bestOut = NO;
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    BOOL sideOut[2] = {YES, NO};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint hp =
          [self _handlePointForContentRect:cr
                                  position:@[
                                    @(ax + sides[s].x), @(ay + sides[s].y)
                                  ]];
      double d = hypot(p.x - hp.x, p.y - hp.y);
      if (d <= bestD) {
        bestD = d;
        bestI = i;
        bestOut = sideOut[s];
      }
    }
  }
  if (bestI < 0)
    return NO;
  if (outIdx)
    *outIdx = bestI;
  if (outIsOut)
    *outIsOut = bestOut;
  return YES;
}

// Live-update the dragged keypose's position in self.timeline (drives the
// preview); the full blob is persisted once on drag end.
- (void)_applyPathDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                    modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  KKLane *lane = KKMagicMoveLaneNamed(self.timeline, @"Position");
  if (!lane || _pathIndex < 0 || _pathIndex >= (NSInteger)lane.keyposes.count)
    return;
  double curNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double curNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  NSMutableArray<KKLane *> *lanes = [self.timeline.lanes mutableCopy];
  NSInteger li = [lanes indexOfObject:lane];
  if (li == NSNotFound)
    return;
  KKLane *nl = [lane copy];
  NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
  KKKeyPose *nk = [kps[_pathIndex] copy];
  if (_pathPart == 0) {
    // Anchor: delta-based move (no jump) + Shift axis-lock + Cmd-snap.
    double nx = _pathGrabValX + (curNX - _pathPressNX);
    double ny = _pathGrabValY + (curNY - _pathPressNY);
    if (modifiers & NSEventModifierFlagShift) {
      double dx = curNX - _pathPressNX, dy = curNY - _pathPressNY;
      if (fabs(dx) >= fabs(dy))
        ny = _pathGrabValY;
      else
        nx = _pathGrabValX;
    }
    if (modifiers & NSEventModifierFlagCommand)
      [self _snapPositionX:&nx Y:&ny contentRect:cr excludeIndex:_pathIndex];
    else
      [_snapEngine reset];
    nk.values = @[ @(nx), @(ny) ];
  } else {
    // Tangent handle: offset from the anchor; symmetric unless Shift breaks it.
    double ax = nk.values.count > 0 ? nk.values[0].doubleValue : 0.5;
    double ay = nk.values.count > 1 ? nk.values[1].doubleValue : 0.5;
    double offX = curNX - ax, offY = curNY - ay;
    NSArray<NSNumber *> *off = @[ @(offX), @(offY) ];
    NSArray<NSNumber *> *mir = @[ @(-offX), @(-offY) ];
    BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
    nk.spatialSmooth = YES;
    if (_pathPart == 1) {
      nk.outHandle = off;
      if (!shift)
        nk.inHandle = mir;
    } else {
      nk.inHandle = off;
      if (!shift)
        nk.outHandle = mir;
    }
  }
  kps[_pathIndex] = nk;
  nl.keyposes = kps;
  lanes[li] = nl;
  KKTimeline *t = [self.timeline copy];
  t.lanes = lanes;
  self.timeline = t;
  [self.canvas setNeedsDisplay:YES];
  [self.canvas setHandlesNeedDisplay];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  NSInteger idx;
  BOOL isOut;
  // Anchor pivot square is topmost (mirrors the viewer) so it is always
  // grabbable; the larger Position arc ring around it stays clickable.
  if ([self _anchorSquareHitAtPoint:p contentRect:cr])
    return YES;
  // The active keypose's position handle is next: when it coincides with a
  // path anchor or tangent handle, the handle wins. Handles are offset from the
  // anchor centre, so they stay grabbable away from it.
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self _pathHandleHitAtPoint:p
                      contentRect:cr
                         outIndex:&idx
                         outIsOut:&isOut])
    return YES;
  if ([self _pathAnchorHitAtPoint:p contentRect:cr outIndex:&idx])
    return YES;
  if ([self _scaleHandleHitAtPoint:p contentRect:cr outIndex:&idx])
    return YES;
  return [super miniCanvas:canvas handleHitAtPoint:p contentRect:cr];
}

- (void)miniCanvas:(KKMiniCanvasView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  _pathGrabbed = NO;
  _anchorGrabbed = NO;
  NSInteger idx;
  BOOL isOut;
  // Anchor square grabs first (topmost, matches the hit-test priority).
  if ([self _anchorSquareHitAtPoint:p contentRect:cr]) {
    self.canvas = canvas;
    _anchorGrabbed = YES;
    NSArray<NSNumber *> *av = [self valuesForLabel:@"Anchor"];
    _anchorGrabValX = av.count > 0 ? av[0].doubleValue : 0.5;
    _anchorGrabValY = av.count > 1 ? av[1].doubleValue : 0.5;
    if (cr.size.width > 0 && cr.size.height > 0) {
      _anchorPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
      _anchorPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
    }
    return;
  }
  // Active keypose's position handle takes the grab next (matches the hit-test
  // priority), so a coincident path anchor/handle doesn't steal it.
  if ([self pointHandleHitAtPoint:p contentRect:cr]) {
    [super miniCanvas:canvas beginHandleDragAtPoint:p contentRect:cr];
    return;
  }
  if ([self _pathHandleHitAtPoint:p
                      contentRect:cr
                         outIndex:&idx
                         outIsOut:&isOut]) {
    self.canvas = canvas;
    _pathGrabbed = YES;
    _pathIndex = idx;
    _pathPart = isOut ? 1 : 2;
    [self _applyPathDragToPoint:p contentRect:cr modifiers:0];
    return;
  }
  if ([self _pathAnchorHitAtPoint:p contentRect:cr outIndex:&idx]) {
    self.canvas = canvas;
    _pathGrabbed = YES;
    _pathIndex = idx;
    _pathPart = 0;
    NSArray<NSNumber *> *gv =
        KKMagicMoveLaneNamed(self.timeline, @"Position").keyposes[idx].values;
    _pathGrabValX = gv.count > 0 ? gv[0].doubleValue : 0.5;
    _pathGrabValY = gv.count > 1 ? gv[1].doubleValue : 0.5;
    if (cr.size.width > 0 && cr.size.height > 0) {
      _pathPressNX = (p.x - CGRectGetMinX(cr)) / cr.size.width;
      _pathPressNY = (p.y - CGRectGetMinY(cr)) / cr.size.height;
    }
    [self _applyPathDragToPoint:p contentRect:cr modifiers:0];
    return;
  }
  if ([self _scaleHandleHitAtPoint:p contentRect:cr outIndex:&idx]) {
    self.canvas = canvas;
    _scaleGrabbed = YES;
    _scaleGrabHandle = idx;
    _scalePressCenter = [self rotationCenterForContentRect:cr];
    NSArray<NSNumber *> *sv = [self valuesForLabel:@"Scale"];
    _scalePressSclX = sv.count > 0 ? fmax(0.0, sv[0].doubleValue) : 100.0;
    _scalePressSclY = sv.count > 1 ? fmax(0.0, sv[1].doubleValue) : 100.0;
    // Effective cursor starts at the grabbed handle (no press snap).
    CGPoint h[8];
    [self _scaleHandlePositions:h forContentRect:cr];
    _scaleEffCursor = h[idx];
    _scaleLastCursor = p;
    return;
  }
  [super miniCanvas:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    doubleClickAtPoint:(CGPoint)p
           contentRect:(CGRect)cr {
  KKLane *lane = KKMagicMoveLaneNamed(self.timeline, @"Position");
  if (!lane || lane.keyposes.count < 2 || CGRectIsEmpty(cr) ||
      ![self labelVisibleOrRevealing:@"Path"] || !self.boundaryEditing)
    return NO;
  // Toggle the keypose under the click: an anchor dot, or the active keypose
  // under the position handle.
  NSInteger idx = -1;
  if (![self _pathAnchorHitAtPoint:p contentRect:cr outIndex:&idx]) {
    if ([self pointHandleHitAtPoint:p contentRect:cr]) {
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)lane.keyposes.count; k++) {
        double d = fabs(lane.keyposes[k].time - self.editFraction);
        if (d < bd) {
          bd = d;
          idx = k;
        }
      }
    }
  }
  if (idx < 0)
    return NO;
  NSMutableArray<KKLane *> *lanes = [self.timeline.lanes mutableCopy];
  NSInteger li = [lanes indexOfObject:lane];
  if (li == NSNotFound)
    return NO;
  KKLane *nl = [lane copy];
  NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
  KKKeyPose *nk = [kps[idx] copy];
  nk.spatialSmooth = !nk.spatialSmooth;
  kps[idx] = nk;
  nl.keyposes = kps;
  lanes[li] = nl;
  KKTimeline *t = [self.timeline copy];
  t.lanes = lanes;
  self.timeline = t;
  if (self.onTimelinePersist)
    self.onTimelinePersist(self.timeline);
  [canvas setNeedsDisplay:YES];
  [canvas setHandlesNeedDisplay];
  return YES;
}

- (CGFloat)motionPathGhostAlpha {
  return [self ghostAlphaForLabel:@"Path"];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  // Anchor square is topmost, so it claims the opt-click first.
  if (self.onHandleVisibilityToggled && [self _anchorSquareHitAtPoint:p
                                                          contentRect:cr]) {
    self.onHandleVisibilityToggled(@"Anchor");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  // Built-in handles (Position arc, rotation, crop) claim the opt-click next,
  // so at the active keypose the Position handle wins over the path anchor that
  // shares its spot when Position is revealed - matching the viewer. The path
  // then catches its own anchors/handles.
  if ([super miniCanvas:canvas optClickHandleAtPoint:p contentRect:cr])
    return YES;
  NSInteger idx;
  BOOL isOut;
  if (self.onHandleVisibilityToggled && ([self _pathHandleHitAtPoint:p
                                                         contentRect:cr
                                                            outIndex:&idx
                                                            outIsOut:&isOut] ||
                                         [self _pathAnchorHitAtPoint:p
                                                         contentRect:cr
                                                            outIndex:&idx])) {
    self.onHandleVisibilityToggled(@"Path");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  if (self.onHandleVisibilityToggled && [self _scaleHandleHitAtPoint:p
                                                         contentRect:cr
                                                            outIndex:&idx]) {
    self.onHandleVisibilityToggled(@"Scale");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  return NO;
}

- (void)_snapPositionX:(double *)nx Y:(double *)ny contentRect:(CGRect)cr {
  // Position-handle drag edits the keypose nearest editFraction; exclude it.
  NSInteger edited = -1;
  for (KKLane *lane in self.timeline.lanes) {
    if (![lane.label isEqualToString:@"Position"])
      continue;
    double bd = 1e9;
    for (NSInteger k = 0; k < (NSInteger)lane.keyposes.count; k++) {
      double d = fabs(lane.keyposes[k].time - self.editFraction);
      if (d < bd) {
        bd = d;
        edited = k;
      }
    }
    break;
  }
  [self _snapPositionX:nx Y:ny contentRect:cr excludeIndex:edited];
}

- (void)_snapPositionX:(double *)nx
                     Y:(double *)ny
           contentRect:(CGRect)cr
          excludeIndex:(NSInteger)excludeIndex {
  static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  // Snap threshold in mini-canvas view points; convert to normalized units
  // (per-axis since the mini may not be square).
  static const float kThreshPt = 6.0f;
  float thrX = cr.size.width > 0 ? kThreshPt / (float)cr.size.width : 0.01f;
  float thrY = cr.size.height > 0 ? kThreshPt / (float)cr.size.height : 0.01f;

  // Other keyposes on the Position lane. Identify the edited keypose by
  // closest-time match against editFraction (skipping by *value* would
  // unskip mid-drag the moment the edited keypose's value lines up with
  // another, producing a snap → unsnap → snap pingback).
  simd_float2 *objs = NULL;
  NSUInteger nObj = 0;
  for (KKLane *lane in self.timeline.lanes) {
    if (![lane.label isEqualToString:@"Position"])
      continue;
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    if (kps.count > 0)
      objs = malloc(kps.count * sizeof(simd_float2));
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      if (k == excludeIndex)
        continue;
      NSArray<NSNumber *> *v = kps[k].values;
      if (v.count < 2)
        continue;
      objs[nObj++] =
          (simd_float2){(float)v[0].doubleValue, (float)v[1].doubleValue};
    }
    break;
  }
  simd_float2 snapped =
      [_snapEngine snapPoint:(simd_float2){(float)*nx, (float)*ny}
              canvasAnchorsX:anchors
                      countX:5
              canvasAnchorsY:anchors
                      countY:5
               objectTargets:objs
                       count:nObj
                  thresholdX:thrX
                  thresholdY:thrY];
  if (objs)
    free(objs);
  *nx = snapped.x;
  *ny = snapped.y;
}

- (void)miniCanvas:(KKMiniCanvasView *)canvas
     snapGuideHasX:(out BOOL *)hasX
                 X:(out CGFloat *)outX
      fromKeyposeX:(out BOOL *)fromKeyposeX
              hasY:(out BOOL *)hasY
                 Y:(out CGFloat *)outY
      fromKeyposeY:(out BOOL *)fromKeyposeY {
  *hasX = _snapEngine.snappedX;
  *outX = (CGFloat)_snapEngine.snapValueX;
  *fromKeyposeX = _snapEngine.snapXFromObject;
  *hasY = _snapEngine.snappedY;
  *outY = (CGFloat)_snapEngine.snapValueY;
  *fromKeyposeY = _snapEngine.snapYFromObject;
}

// Overlay-point centre of the anchor pivot: the clip centre (Position) shifted
// by the Anchor offset, in the same normalized clip space as the path anchors.
- (CGPoint)_anchorPointForContentRect:(CGRect)cr {
  NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
  NSArray<NSNumber *> *anc = [self valuesForLabel:@"Anchor"];
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  double ax = anc.count > 0 ? anc[0].doubleValue : 0.5;
  double ay = anc.count > 1 ? anc[1].doubleValue : 0.5;
  return
      [self _handlePointForContentRect:cr
                              position:@[ @(px + ax - 0.5), @(py + ay - 0.5) ]];
}

// The anchor square shows when the Anchor lane is constant (a single fixed
// pivot) and not hidden - same convention as the other single-handle OSCs in
// the mini-canvas (animated lanes draw keypose dots instead).
- (BOOL)_anchorActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && [self isConstantLabel:@"Anchor"] &&
         [self labelVisibleOrRevealing:@"Anchor"];
}

- (BOOL)_anchorSquareHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  if (![self _anchorActiveForContentRect:cr])
    return NO;
  CGPoint c = [self _anchorPointForContentRect:cr];
  // Tight to the drawn square (Chebyshev, square hit region), and well under
  // the Position handle's 12pt grab so clicking the arc ring around the small
  // square still reaches Position - mirroring the viewer where the square is
  // physically smaller than the arc. Scales with the popover (canvas H / 230).
  CGFloat scale = self.canvas.bounds.size.height > 0
                      ? self.canvas.bounds.size.height / 230.0
                      : 1.0;
  CGFloat r = 5.0 * scale;
  return fmax(fabs(p.x - c.x), fabs(p.y - c.y)) < r;
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    anchorSquareCenter:(out CGPoint *)outCenter
           contentRect:(CGRect)cr {
  if (![self _anchorActiveForContentRect:cr])
    return NO;
  if (outCenter)
    *outCenter = [self _anchorPointForContentRect:cr];
  return YES;
}

- (CGFloat)anchorSquareGhostAlpha {
  return [self ghostAlphaForLabel:@"Anchor"];
}

// Delta drag like Position: the anchor value moves by the cursor's normalized
// offset from the grab point. Cmd snaps the PIVOT (Position + Anchor offset) to
// the clip's centre / corners / edge-midpoints / thirds, routed through the
// shared snap engine so the canvas strokes the yellow guide lines.
- (void)_applyAnchorDragToPoint:(CGPoint)p
                    contentRect:(CGRect)cr
                      modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double nx = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double ny = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  double newX = _anchorGrabValX + (nx - _anchorPressNX);
  double newY = _anchorGrabValY + (ny - _anchorPressNY);
  if (modifiers & NSEventModifierFlagCommand) {
    NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
    double posX = pos.count > 0 ? pos[0].doubleValue : 0.5;
    double posY = pos.count > 1 ? pos[1].doubleValue : 0.5;
    // Clip features in pivot-normalized content space (0/⅓/½/⅔/1 of the clip
    // offset from its centre by Position). Snapping the pivot here makes the
    // guide land on the clip's real edges/centre, not on a fixed value.
    static const double frac[] = {0.0, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1.0};
    float ax[5], ay[5];
    for (int i = 0; i < 5; i++) {
      ax[i] = (float)(posX + frac[i] - 0.5);
      ay[i] = (float)(posY + frac[i] - 0.5);
    }
    float thrX = cr.size.width > 0 ? 6.0f / (float)cr.size.width : 0.02f;
    float thrY = cr.size.height > 0 ? 6.0f / (float)cr.size.height : 0.02f;
    simd_float2 pivot = {(float)(posX + newX - 0.5),
                         (float)(posY + newY - 0.5)};
    simd_float2 sn = [_snapEngine snapPoint:pivot
                             canvasAnchorsX:ax
                                     countX:5
                             canvasAnchorsY:ay
                                     countY:5
                              objectTargets:NULL
                                      count:0
                                 thresholdX:thrX
                                 thresholdY:thrY];
    newX = sn.x - posX + 0.5;
    newY = sn.y - posY + 0.5;
  } else {
    [_snapEngine reset];
  }
  [self commitValues:@[ @(newX), @(newY) ]
            forLabel:@"Anchor"
              canvas:self.canvas];
}

- (void)miniCanvasEndHandleDrag:(KKMiniCanvasView *)canvas {
  [_snapEngine reset];
  _anchorGrabbed = NO;
  _scaleGrabbed = NO;
  if (_pathGrabbed) {
    _pathGrabbed = NO;
    if (self.onTimelinePersist)
      self.onTimelinePersist(self.timeline);
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return;
  }
  [super miniCanvasEndHandleDrag:canvas];
}

#pragma mark - Rotation gizmo

// Opting in to the base's 3-ring gizmo. The drag state machine, hit-test,
// compose × axis(dAngle) → decompose-near, and commit all live in the base
// (`KKMiniCanvasRenderer`). The only thing MagicMove-specific is anchoring
// the sphere to the Position handle so the rings move with the translated
// image.
- (NSString *)rotationLabel {
  return @"Rotation";
}

- (CGPoint)rotationCenterForContentRect:(CGRect)cr {
  return [self _handlePointForContentRect:cr
                                 position:[self valuesForLabel:@"Position"]];
}

@end
