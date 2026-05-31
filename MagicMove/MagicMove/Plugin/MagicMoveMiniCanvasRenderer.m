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

static const CGFloat kHandleHitTolPt = 12.0;

@interface MagicMoveMiniCanvasRenderer () {
  KKSnapEngine *_snapEngine;
  // Pipeline cache keyed by (device, pixelFormat) — the plugin's own metallib
  // is in this XPC process's bundle, so we build a real PSO and apply the
  // shader source → dest locally. No FxPlug round-trip = no Flexo lock
  // contention = no deadlock during live drag.
  id<MTLRenderPipelineState> _pipeline;
  id<MTLDevice> _pipelineDevice;
  MTLPixelFormat _pipelineFormat;
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
  double posX = positionVals.count > 0 ? positionVals[0].doubleValue : 0.5;
  double posY = positionVals.count > 1 ? positionVals[1].doubleValue : 0.5;
  double rotXdeg = rotationVals.count > 0 ? rotationVals[0].doubleValue : 0.0;
  double rotYdeg = rotationVals.count > 1 ? rotationVals[1].doubleValue : 0.0;
  double rotZdeg = rotationVals.count > 2 ? rotationVals[2].doubleValue : 0.0;
  static const double kDegToRad = M_PI / 180.0;

  KKLane *positionLane = KKMagicMoveLaneNamed(renderer.timeline, @"Position");
  rotZdeg -= KKMagicMoveRotateWithMotionAdjustmentDegrees(
      positionLane, renderer.editFraction, posX,
      positionLane.lastKnownClipDuration);

  outParams->translate =
      (simd_float2){(float)(posX - 0.5), (float)(posY - 0.5)};
  outParams->anchorOffset = (simd_float2){0.0f, 0.0f};
  outParams->rotation = (float)(rotZdeg * kDegToRad);
  outParams->rotationX = (float)(rotXdeg * kDegToRad);
  outParams->rotationY = (float)(rotYdeg * kDegToRad);
  outParams->scaleX = 1.0f;
  outParams->scaleY = 1.0f;
  outParams->opacity = 1.0f;
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
  if ([label isEqualToString:@"Position"])
    return @[ @0.5, @0.5 ];
  if ([label isEqualToString:@"Rotation"])
    return @[ @0.0, @0.0, @0.0 ];
  return [super defaultValuesForLabel:label];
}

- (CGPoint)_handlePointForContentRect:(CGRect)cr
                             position:(NSArray<NSNumber *> *)pos {
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  return CGPointMake(CGRectGetMinX(cr) + px * cr.size.width,
                     CGRectGetMinY(cr) + py * cr.size.height);
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  *outCenter =
      [self _handlePointForContentRect:cr
                              position:[self valuesForLabel:@"Position"]];
  return YES;
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
  [self applyPointDragToPoint:p contentRect:cr canvas:canvas modifiers:0];
}

// Mirror of the viewer OSC snap: anchors at 0/0.25/0.5/0.75/1.0 plus every
// other keypose's stored position. Cmd bypasses (Canvas convention).
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniCanvasView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers {
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return;
  double nx = (p.x - CGRectGetMinX(cr)) / cr.size.width;
  double ny = (p.y - CGRectGetMinY(cr)) / cr.size.height;
  if (!(modifiers & NSEventModifierFlagCommand)) {
    [self _snapPositionX:&nx Y:&ny contentRect:cr];
  } else {
    [_snapEngine reset];
  }
  [self commitValues:@[ @(nx), @(ny) ] forLabel:@"Position" canvas:canvas];
}

// Mini-canvas drag is also called via the delegate dispatcher in
// KKMiniCanvasView so the modifier variant takes precedence over the plain
// one.
- (void)miniCanvas:(KKMiniCanvasView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
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

- (void)_snapPositionX:(double *)nx Y:(double *)ny contentRect:(CGRect)cr {
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
    NSInteger edited = -1;
    if (kps.count > 0) {
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
        double d = fabs(kps[k].time - self.editFraction);
        if (d < bd) {
          bd = d;
          edited = k;
        }
      }
      objs = malloc(kps.count * sizeof(simd_float2));
    }
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      if (k == edited)
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

- (void)miniCanvasEndHandleDrag:(KKMiniCanvasView *)canvas {
  [_snapEngine reset];
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
