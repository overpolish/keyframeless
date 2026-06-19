/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MagicMoveMiniViewerRenderer.h"
#import "MagicMoveMiniViewerRenderer_Internal.h"
#import "MagicMoveParamsBuild.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>

NSString *const MagicMoveMiniViewerDescriptorPath =
    @"/tmp/magicmove-miniviewer.json";
NSString *const MagicMoveMiniViewerRequestPath =
    @"/tmp/magicmove-miniviewer-request.json";

NSString *MagicMoveMiniViewerDescriptorPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MagicMoveMiniViewerDescriptorPath;
  return [NSString stringWithFormat:@"/tmp/magicmove-miniviewer-%@.json", uuid];
}

NSString *MagicMoveMiniViewerRequestPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MagicMoveMiniViewerRequestPath;
  return [NSString
      stringWithFormat:@"/tmp/magicmove-miniviewer-request-%@.json", uuid];
}
#import "MagicMoveMiniViewerRenderer_Internal.h"

@implementation MagicMoveMiniViewerRenderer

- (instancetype)init {
  if ((self = [super init])) {
    _positionMini =
        [[KKPositionMiniController alloc] initWithRenderer:self
                                                 laneLabel:@"Position"
                                                 pathLabel:@"Path"];
    _scaleMini = [[KKScaleMiniController alloc] initWithRenderer:self
                                                       laneLabel:@"Scale"];
    _anchorMini = [[KKAnchorMiniController alloc]
        initWithRenderer:self
               laneLabel:@"Anchor"
       positionLaneLabel:@"Position"
              snapEngine:_positionMini.snapEngine];
    // The anchor pivot sits dead-centre on the Position arc at a default anchor,
    // so keep its grab zone tight - the larger Position handle around it stays
    // clickable, the small centre square still grabs the anchor.
    _anchorMini.hitRadiusPt = 3.0;
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
    KKLogError(@"MagicMoveMiniViewerRenderer: no metallib: %@", err);
    return nil;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"vertexShader"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"fragmentShader"];
  if (!vfn || !ffn) {
    KKLogError(@"MagicMoveMiniViewerRenderer: missing shader functions");
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
    KKLogError(@"MagicMoveMiniViewerRenderer: pipeline build failed: %@", err);
    return nil;
  }
  _pipeline = ps;
  _pipelineDevice = device;
  _pipelineFormat = format;
  return _pipeline;
}

KKLane *MMMiniLaneNamed(KKTimeline *timeline, NSString *label) {
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
                                   MagicMoveMiniViewerRenderer *renderer) {
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

  KKLane *positionLane = MMMiniLaneNamed(renderer.timeline, @"Position");
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
// point in the bottom-left of the mini-viewer).
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

- (KKLane *)templateLaneForLabel:(NSString *)label {
  for (KKLane *l in self.laneTemplates)
    if ([l.label isEqualToString:label])
      return l;
  return [super templateLaneForLabel:label];
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
  return [self handlePointForContentRect:cr position:pos];
}

- (NSString *)rotationLabel {
  return @"Rotation";
}

- (CGPoint)rotationCenterForContentRect:(CGRect)cr {
  return [self _handlePointForContentRect:cr
                                 position:[self valuesForLabel:@"Position"]];
}

@end
