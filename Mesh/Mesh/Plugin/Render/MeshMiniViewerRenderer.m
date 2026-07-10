/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MeshMiniViewerRenderer.h"

#import "MeshColorSpace.h"
#import "MeshUniformBuilders.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKPositionMiniController.h>
#import <KeyframelessKit/KKScaleMiniController.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

NSString *const MeshMiniViewerDescriptorPath = @"/tmp/mesh-miniviewer.json";

NSString *const MeshMiniViewerRequestPath =
    @"/tmp/mesh-miniviewer-request.json";

NSString *MeshMiniViewerDescriptorPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MeshMiniViewerDescriptorPath;
  return [NSString stringWithFormat:@"/tmp/mesh-miniviewer-%@.json", uuid];
}

NSString *MeshMiniViewerRequestPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MeshMiniViewerRequestPath;
  return
      [NSString stringWithFormat:@"/tmp/mesh-miniviewer-request-%@.json", uuid];
}

@implementation MeshMiniViewerRenderer {
  NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_pipelines;
  MTLPixelFormat _pipelineFormat;
  KKPositionMiniController *_originMini;
  KKScaleMiniController *_scaleMini;
  // Render-at-reference-resolution + downscale (so the small mini texture shows
  // a proper minified copy of a full-res render: grain, dither, everything).
  id<MTLTexture> _hiResTex;
  id<MTLRenderPipelineState> _blitPipeline;
  MTLPixelFormat _blitFormat;
  id<MTLSamplerState> _linearSampler;
}

// Mini-viewer Origin handle: the reusable Position controller, keyed on the
// "Origin" lane (mirrors the main viewer's KKPositionOSC). Built lazily (no
// -init override) so the renderer is fully constructed before the controller
// weak-refs it back.
- (KKPositionMiniController *)originMini {
  if (!_originMini)
    _originMini = [[KKPositionMiniController alloc] initWithRenderer:self
                                                           laneLabel:@"Origin"
                                                           pathLabel:@"Path"];
  return _originMini;
}

// Mini-viewer Scale box: the reusable Scale controller, keyed on the "Scale"
// lane (mirrors the main viewer's KKScaleOSC). Concentric with the Origin pivot
// (see -rotationCenterForContentRect:).
- (KKScaleMiniController *)scaleMini {
  if (!_scaleMini)
    _scaleMini = [[KKScaleMiniController alloc] initWithRenderer:self
                                                       laneLabel:@"Scale"];
  return _scaleMini;
}

// The Scale box centres on the Origin point. Reuse the Origin controller's
// placement for the current Origin value.
- (CGPoint)rotationCenterForContentRect:(CGRect)cr {
  CGPoint c = CGPointZero;
  NSArray<NSNumber *> *o = [self valuesForLabel:@"Origin"];
  if (o.count >= 2 && [self.originMini pointHandleCenter:&c
                                               forValues:o
                                          forContentRect:cr])
    return c;
  if ([self.originMini pointHandleCenter:&c forContentRect:cr])
    return c;
  return CGPointMake(CGRectGetMidX(cr), CGRectGetMidY(cr));
}

- (KKLane *)templateLaneForLabel:(NSString *)label {
  for (KKLane *l in self.laneTemplates)
    if ([l.label isEqualToString:label])
      return l;
  return [super templateLaneForLabel:label];
}

// The Origin handle is the reusable Position control (arc glyph); the base
// renderer draws + drags it keyed on `pointLabel`. No crop handle.
- (NSString *)cropLabel {
  return nil;
}
- (NSString *)pointLabel {
  return @"Origin";
}
- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStyleArc;
}
// The Origin handle is the arc (above); this only sizes the Scale box's corner
// handles - shrink them so they aren't oversized (matches MagicMove).
- (CGFloat)pointHandleSizeScale {
  return 0.6;
}
// The Origin arc draws on top of the Scale box + rotation ring, so the
// hit-test / drag prefer it where they overlap.
- (BOOL)pointHandleBeatsRotation {
  return YES;
}
// Opt into the base mini rotation gizmo, Z axis only (2D pattern), keyed on the
// 1-component "Rotation" lane and centred on the Origin pivot (see
// -rotationCenterForContentRect:).
- (NSString *)rotationLabel {
  return @"Rotation";
}
- (KKRotationAxes)rotationEnabledAxes {
  return KKRotationAxisZ;
}
- (NSInteger)valueTypeForLabel:(NSString *)label {
  if ([label hasPrefix:@"Color "] || [label isEqualToString:@"Background"] ||
      [label isEqualToString:@"Foreground"] || [label isEqualToString:@"Mid"] ||
      [label isEqualToString:@"Bloom Color"])
    return KKLaneValueTypeColor;
  if ([label isEqualToString:@"Origin"] || [label isEqualToString:@"Scale"])
    return KKLaneValueTypeGeneric;
  return KKLaneValueTypeFloat;
}
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  int ci = MeshIndexForLabel(label, @"Color ");
  if (ci >= 0 && ci < KK_MESH_COLOR_COUNT) {
    const float *c = kMeshDefaultColorsSRGB[ci];
    return @[ @(c[0]), @(c[1]), @(c[2]), @(c[3]) ];
  }
  if ([label isEqualToString:@"Distortion"])
    return @[ @(KK_MESH_GRAD_DEFAULT_DISTORTION * 100.0) ];
  if ([label isEqualToString:@"Swirl"])
    return @[ @(KK_MESH_GRAD_DEFAULT_SWIRL * 100.0) ];
  if ([label isEqualToString:@"Speed"])
    return @[ @(KK_MESH_GRAD_DEFAULT_SPEED) ];
  if ([label isEqualToString:@"Seed"])
    return @[ @(KK_MESH_GRAD_DEFAULT_SEED) ];
  if ([label isEqualToString:@"Grain"])
    return @[ @(KK_CORE_GRAIN_DEFAULT * 100.0) ];
  if ([label isEqualToString:@"Grain Size"])
    return @[ @(KK_CORE_GRAINSIZE_DEFAULT) ];
  if ([label isEqualToString:@"Type"])
    return @[ @0.0 ];
  if ([label isEqualToString:@"Background"])
    return @[ @0.04, @0.04, @0.07, @1.0 ];
  if ([label isEqualToString:@"Foreground"])
    return @[ @0.85, @0.90, @0.98, @1.0 ];
  if ([label isEqualToString:@"Mid"])
    return @[ @0.25, @0.45, @0.95, @1.0 ];
  if ([label isEqualToString:@"Brightness"])
    return @[ @(KK_NEURO_DEFAULT_BRIGHTNESS * 100.0) ];
  if ([label isEqualToString:@"Contrast"])
    return @[ @(KK_NEURO_DEFAULT_CONTRAST * 100.0) ];
  if ([label isEqualToString:@"Steps"])
    return @[ @(KK_SIMPLEX_DEFAULT_STEPS) ];
  if ([label isEqualToString:@"Count"])
    return @[ @(KK_METABALLS_DEFAULT_COUNT) ];
  if ([label isEqualToString:@"Size"])
    return @[ @(KK_METABALLS_DEFAULT_SIZE * 100.0) ];
  if ([label isEqualToString:@"Bloom Color"])
    return @[ @1.0, @0.9, @0.7, @1.0 ];
  if ([label isEqualToString:@"Density"])
    return @[ @(KK_GODRAYS_DEFAULT_DENSITY * 100.0) ];
  if ([label isEqualToString:@"Spots"])
    return @[ @(KK_GODRAYS_DEFAULT_SPOTTY * 100.0) ];
  if ([label isEqualToString:@"Glow Size"])
    return @[ @(KK_GODRAYS_DEFAULT_MIDSIZE * 100.0) ];
  if ([label isEqualToString:@"Glow"])
    return @[ @(KK_GODRAYS_DEFAULT_MIDINTENSITY * 100.0) ];
  if ([label isEqualToString:@"Rays"])
    return @[ @(KK_GODRAYS_DEFAULT_INTENSITY * 100.0) ];
  if ([label isEqualToString:@"Bloom"])
    return @[ @(KK_GODRAYS_DEFAULT_BLOOM * 100.0) ];
  if ([label isEqualToString:@"Detail"])
    return @[ @(KK_FLUID_DEFAULT_DETAIL * 100.0) ];
  if ([label isEqualToString:@"Marble"])
    return @[ @(KK_FLUID_DEFAULT_MARBLE * 100.0) ];
  if ([label isEqualToString:@"Vibrance"])
    return @[ @(KK_FLUID_DEFAULT_VIBRANCE * 100.0) ];
  if ([label isEqualToString:@"Radiance"])
    return @[ @(KK_NEON_DEFAULT_RADIANCE * 100.0) ];
  if ([label isEqualToString:@"Wisps"])
    return @[ @(KK_NEON_DEFAULT_WISPS * 100.0) ];
  if ([label isEqualToString:@"Strands"])
    return @[ @(KK_NEON_DEFAULT_STRANDS * 100.0) ];
  if ([label isEqualToString:@"Sheen"])
    return @[ @(KK_SILK_DEFAULT_SHEEN * 100.0) ];
  if ([label isEqualToString:@"Folds"])
    return @[ @(KK_SILK_DEFAULT_FOLDS * 100.0) ];
  if ([label isEqualToString:@"Drape"])
    return @[ @(KK_SILK_DEFAULT_DRAPE * 100.0) ];
  if ([label isEqualToString:@"Layers"])
    return @[ @(KK_STRATA_DEFAULT_LAYERS) ];
  if ([label isEqualToString:@"Tectonics"])
    return @[ @(KK_STRATA_DEFAULT_TECTONICS * 100.0) ];
  if ([label isEqualToString:@"Texture"])
    return @[ @(KK_STRATA_DEFAULT_TEXTURE * 100.0) ];
  if ([label isEqualToString:@"Shape"])
    return @[ @0.0 ]; // simplex
  if ([label isEqualToString:@"Dither"])
    return @[ @3.0 ]; // 8x8 Bayer
  if ([label isEqualToString:@"Pixel Size"])
    return @[ @(KK_DITHER_DEFAULT_PXSIZE) ];
  if ([label isEqualToString:@"Softness"])
    return @[ @(KK_GRAIN_DEFAULT_SOFTNESS * 100.0) ];
  if ([label isEqualToString:@"Intensity"])
    return @[ @(KK_GRAIN_DEFAULT_INTENSITY * 100.0) ];
  if ([label isEqualToString:@"Noise"])
    return @[ @(KK_GRAIN_DEFAULT_NOISE * 100.0) ];
  if ([label isEqualToString:@"Pattern"])
    return @[ @(KK_GRAIN_DEFAULT_SHAPE - 1) ]; // pill is 0-based
  if ([label isEqualToString:@"Proportion"])
    return @[ @(KK_WARP_DEFAULT_PROPORTION * 100.0) ];
  if ([label isEqualToString:@"Shape Scale"])
    return @[ @(KK_WARP_DEFAULT_SHAPESCALE * 100.0) ];
  if ([label isEqualToString:@"Swirl Iterations"])
    return @[ @(KK_WARP_DEFAULT_SWIRLITER) ];
  if ([label isEqualToString:@"Base"])
    return @[ @(KK_WARP_DEFAULT_SHAPE) ];
  if ([label isEqualToString:@"Scale"])
    return @[ @100.0, @100.0 ];
  if ([label isEqualToString:@"Rotation"])
    return @[ @0.0 ];
  if ([label isEqualToString:@"Origin"])
    return @[ @0.5, @0.5 ];
  return [super defaultValuesForLabel:label];
}

// Builds (and caches per fragment + format) the pipeline for the active type's
// fragment function, so the mini preview matches the FCP render.
- (id<MTLRenderPipelineState>)_pipelineForDevice:(id<MTLDevice>)device
                                     pixelFormat:(MTLPixelFormat)format
                                  fragmentShader:(NSString *)fragmentName {
  if (_pipelineFormat != format) {
    _pipelines = nil;
    _pipelineFormat = format;
  }
  if (!_pipelines)
    _pipelines = [NSMutableDictionary dictionary];
  id<MTLRenderPipelineState> existing = _pipelines[fragmentName];
  if (existing)
    return existing;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib) {
    KKLogError(@"MeshMiniViewerRenderer: no metal library: %@", err);
    return nil;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  pd.fragmentFunction = [lib newFunctionWithName:fragmentName];
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"MeshMiniViewerRenderer: pipeline failed: %@", err);
    return nil;
  }
  _pipelines[fragmentName] = ps;
  return ps;
}

// A cached reference-resolution (1080-tall, dest aspect) intermediate render
// target, or nil when `dest` is already tall enough that rendering direct is
// fine. The type is rendered into this at full resolution and then downscaled
// into the small mini texture, so grain / dither / any resolution-dependent
// effect looks like a proper minified copy of the FCP render.
- (id<MTLTexture>)hiResTargetForDest:(id<MTLTexture>)dest {
  NSUInteger dh = dest.height;
  const NSUInteger refH = 1080;
  if (dh == 0 || dh >= refH)
    return nil; // already high enough, render straight in
  NSUInteger refW = (NSUInteger)llround((double)refH * dest.width / (double)dh);
  if (refW < 1)
    refW = 1;
  if (!_hiResTex || _hiResTex.width != refW || _hiResTex.height != refH ||
      _hiResTex.pixelFormat != dest.pixelFormat) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:dest.pixelFormat
                                     width:refW
                                    height:refH
                                 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    _hiResTex = [dest.device newTextureWithDescriptor:td];
  }
  return _hiResTex;
}

- (id<MTLRenderPipelineState>)blitPipelineForDevice:(id<MTLDevice>)device
                                             format:(MTLPixelFormat)format {
  if (_blitPipeline && _blitFormat == format)
    return _blitPipeline;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib)
    return nil;
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"meshBlitVertex"];
  pd.fragmentFunction = [lib newFunctionWithName:@"meshBlitFragment"];
  pd.colorAttachments[0].pixelFormat = format;
  _blitPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
  _blitFormat = format;
  if (!_blitPipeline)
    KKLogError(@"MeshMiniViewerRenderer: blit pipeline failed: %@", err);
  return _blitPipeline;
}

- (id<MTLSamplerState>)linearSamplerForDevice:(id<MTLDevice>)device {
  if (_linearSampler)
    return _linearSampler;
  MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
  sd.minFilter = MTLSamplerMinMagFilterLinear;
  sd.magFilter = MTLSamplerMinMagFilterLinear;
  sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
  _linearSampler = [device newSamplerStateWithDescriptor:sd];
  return _linearSampler;
}

// Downscale the reference-res intermediate into the mini dest with linear
// filtering (averages the fine grain instead of showing raw coarse pixels).
- (void)blitFrom:(id<MTLTexture>)src
             into:(id<MTLTexture>)dest
    commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  id<MTLRenderPipelineState> bp = [self blitPipelineForDevice:dest.device
                                                       format:dest.pixelFormat];
  if (!bp)
    return;
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [e setRenderPipelineState:bp];
  [e setFragmentTexture:src atIndex:0];
  [e setFragmentSamplerState:[self linearSamplerForDevice:dest.device]
                     atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];
}

// Generator render: no source. Runs the same Metal pipeline as the FCP render
// (vertexShader + solid-blue fragmentShader) straight into the preview dest.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    generateIntoTexture:(id<MTLTexture>)dest
          commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  // Dispatch on the active type, same as the FCP render.
  NSArray<NSNumber *> *typeV = [self valuesForLabel:@"Type"];
  int meshType =
      typeV.count ? (int)lround(typeV[0].doubleValue) : MeshType_Mesh;
  const MeshTypeInfo *info = MeshTypeInfoForType(meshType);
  NSString *fragment = @(info->fragment);
  id<MTLRenderPipelineState> pipeline =
      [self _pipelineForDevice:dest.device
                   pixelFormat:dest.pixelFormat
                fragmentShader:fragment];
  if (!pipeline)
    return NO;

  // Render the type at reference resolution into an intermediate, then
  // downscale into the (small) mini dest below - so grain / dither look like a
  // proper minified full-res render rather than raw low-res pixels.
  id<MTLTexture> renderTex = [self hiResTargetForDest:dest];
  BOOL downscale = (renderTex != nil);
  if (!renderTex)
    renderTex = dest;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = renderTex;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  float W = (float)renderTex.width, H = (float)renderTex.height;
  MTLViewport vp = {0, 0, W, H, -1.0, 1.0};
  [e setViewport:vp];
  KKVertex2D verts[4] = {
      {{-W / 2, H / 2}, {0, 0}},
      {{-W / 2, -H / 2}, {0, 1}},
      {{W / 2, H / 2}, {1, 0}},
      {{W / 2, -H / 2}, {1, 1}},
  };
  simd_uint2 vpSize = {(unsigned)W, (unsigned)H};
  // The mini-viewer renders into an 8-bit unorm texture shown directly on
  // screen, so gamma-encode (unlike FCP's linear float working buffer). The
  // mini is a static preview, so time tracks the edit fraction.
  int encodeSRGB = (dest.pixelFormat == MTLPixelFormatRGBA8Unorm ||
                    dest.pixelFormat == MTLPixelFormatBGRA8Unorm)
                       ? 1
                       : 0;
  float timeSec = (float)self.editFraction;
  NSArray<NSNumber *> *seedV = [self valuesForLabel:@"Seed"];
  float seedShared =
      seedV.count ? seedV[0].floatValue : KK_MESH_GRAD_DEFAULT_SEED;
  NSArray<NSNumber *> *originV = [self valuesForLabel:@"Origin"];
  vector_float2 originShared =
      (originV.count >= 2)
          ? (vector_float2){originV[0].floatValue, originV[1].floatValue}
          : (vector_float2){0.5f, 0.5f};
  // Common transforms: Scale stored as percent (100 = 1x), Rotation in degrees.
  NSArray<NSNumber *> *scaleV = [self valuesForLabel:@"Scale"];
  NSArray<NSNumber *> *rotV = [self valuesForLabel:@"Rotation"];
  vector_float2 scaleShared =
      (scaleV.count >= 2) ? (vector_float2){scaleV[0].floatValue / 100.0f,
                                            scaleV[1].floatValue / 100.0f}
                          : (vector_float2){1.0f, 1.0f};
  float rotationShared =
      rotV.count ? rotV[0].floatValue * (float)(M_PI / 180.0) : 0.0f;
  NSArray<NSNumber *> *speedShV = [self valuesForLabel:@"Speed"];
  float speedShared =
      speedShV.count ? speedShV[0].floatValue : KK_MESH_GRAD_DEFAULT_SPEED;

  [e setRenderPipelineState:pipeline];
  [e setVertexBytes:verts
             length:sizeof(verts)
            atIndex:KKVertexInputIndex_Vertices];
  [e setVertexBytes:&vpSize
             length:sizeof(vpSize)
            atIndex:KKVertexInputIndex_ViewportSize];

  // Build every Type's uniform from the lanes, then bind the active Type's
  // block (offset/size from the registry). Same builders as the FCP render.
  MeshPluginState state;
  memset(&state, 0, sizeof(state));
  MeshLaneReader read = ^NSArray<NSNumber *> *(NSString *label) {
    return [self valuesForLabel:label];
  };
  MeshBuildAllTypes(read, &state);
  [e setFragmentBytes:(const char *)&state + info->uniformOffset
               length:info->uniformSize
              atIndex:MeshFragmentIndex_Grid];

  // Shared params (transforms + timing + grain), same as the FCP render path.
  MeshCommonUniforms common = MeshCommonDefault();
  NSArray<NSNumber *> *grainV = [self valuesForLabel:@"Grain"];
  NSArray<NSNumber *> *grainSizeV = [self valuesForLabel:@"Grain Size"];
  common.origin = originShared;
  common.scale = scaleShared;
  common.rotation = rotationShared;
  common.speed = speedShared;
  common.seed = seedShared;
  common.time = timeSec;
  common.grain =
      grainV.count ? grainV[0].floatValue / 100.0f : KK_CORE_GRAIN_DEFAULT;
  common.grainSize =
      grainSizeV.count ? grainSizeV[0].floatValue : KK_CORE_GRAINSIZE_DEFAULT;
  common.grainScale = MeshGrainScaleForType(meshType);
  common.resolution = (vector_float2){W, H};
  [e setFragmentBytes:&common
               length:sizeof(common)
              atIndex:MeshFragmentIndex_Common];

  [e setFragmentBytes:&encodeSRGB
               length:sizeof(encodeSRGB)
              atIndex:MeshFragmentIndex_EncodeSRGB];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];

  // Downscale the reference-res intermediate into the actual mini texture.
  if (downscale)
    [self blitFrom:renderTex into:dest commandBuffer:commandBuffer];
  return YES;
}

// Dead for the generator: no source is ever published to the mini-viewer feed,
// so the source path never runs (see -miniViewer:generateIntoTexture:). Kept as
// a no-op to satisfy the KKMiniViewerRenderer contract.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  return NO;
}

// Base point-handle overrides forwarded to the reusable Position controller.
// The base drives the constant-lane Origin handle's draw / hit / drag lifecycle
// (gated by _pointActiveForContentRect -> isConstantLabel); these place it,
// hit-test it, and commit its drag through the controller.
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  return [self.originMini pointHandleCenter:outCenter forContentRect:cr];
}
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                forValues:(NSArray<NSNumber *> *)values
           forContentRect:(CGRect)cr {
  return [self.originMini pointHandleCenter:outCenter
                                  forValues:values
                             forContentRect:cr];
}
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self.originMini pointHandleHitAtPoint:p contentRect:cr];
}
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas {
  // The no-modifier form is only called on drag begin (base
  // beginHandleDragAtPoint): capture the press state, then apply.
  [self.originMini beginPointDragAtPoint:p contentRect:cr];
  [self.originMini applyPointDragToPoint:p
                             contentRect:cr
                                  canvas:canvas
                               modifiers:0];
}
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers {
  [self.originMini applyPointDragToPoint:p
                             contentRect:cr
                                  canvas:canvas
                               modifiers:modifiers];
}

// Motion-path overlay (animated Origin): keypose anchors + tangent handles,
// owned by the controller. The base hides the point handle for a non-constant
// lane, so the path takes over.
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathPolylineForContentRect:(CGRect)cr {
  return [self.originMini motionPathPolylineForContentRect:cr];
}
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathAnchorsForContentRect:(CGRect)cr {
  return [self.originMini motionPathAnchorsForContentRect:cr];
}
- (NSArray<NSValue *> *)miniViewer:(KKMiniViewerView *)canvas
    motionPathHandleSegmentsForContentRect:(CGRect)cr {
  return [self.originMini motionPathHandleSegmentsForContentRect:cr];
}
- (CGFloat)motionPathGhostAlpha {
  return [self ghostAlphaForLabel:@"Path"];
}

// Scale transform box: geometry + hit-test + drag live in the reusable
// KKScaleMiniController; these are the thin delegate forwards.
- (NSArray<KKMiniBox *> *)miniViewer:(KKMiniViewerView *)canvas
                 boxesForContentRect:(CGRect)cr {
  NSMutableArray<KKMiniBox *> *boxes = [[super miniViewer:canvas
                                      boxesForContentRect:cr] mutableCopy];
  CGRect sb;
  if ([self.scaleMini boxRect:&sb forContentRect:cr]) {
    [boxes addObject:[KKMiniBox boxWithRect:sb
                              handleCenters:[self.scaleMini
                                                handleCentersForContentRect:cr]
                                    readout:[self.scaleMini readoutText]
                                 ghostAlpha:[self.scaleMini ghostAlpha]]];
  }
  return boxes;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  self.canvas = canvas;
  // Constant Origin handle first, then the motion-path tangents / anchors,
  // then the Scale box, then the base (crop/rotation - none here).
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.originMini pathHandleHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.originMini pathAnchorHitAtPoint:p contentRect:cr])
    return YES;
  if ([self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:NULL])
    return YES;
  return [super miniViewer:canvas handleHitAtPoint:p contentRect:cr];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
           cursorAtPoint:(CGPoint)p
             contentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr))
    return nil;
  self.canvas = canvas;
  if ([self pointHandleHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:self.pointLabel]
               ?: KKPointMoveCursor();
  if ([self.originMini pathHandleHitAtPoint:p contentRect:cr] ||
      [self.originMini pathAnchorHitAtPoint:p contentRect:cr])
    return [self kkVisibilityCursorForLabel:@"Path"] ?: KKPointMoveCursor();
  NSInteger scaleIdx;
  if ([self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:&scaleIdx])
    return [self kkVisibilityCursorForLabel:@"Scale"]
               ?: KKResizeCursorForBoxHandle(scaleIdx);
  return [super miniViewer:canvas cursorAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  self.canvas = canvas;
  // Constant Origin handle takes the grab first (base sets _pointGrabbed +
  // applies), else the motion-path anchors / tangents.
  if ([self pointHandleHitAtPoint:p contentRect:cr]) {
    [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
    return;
  }
  if ([self.originMini beginPathDragAtPoint:p contentRect:cr])
    return;
  if ([self.scaleMini beginDragAtPoint:p contentRect:cr])
    return;
  [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if (self.originMini.pathGrabbed) {
    [self.originMini applyPathDragToPoint:p contentRect:cr modifiers:modifiers];
    return;
  }
  if (self.scaleMini.isDragging) {
    [self.scaleMini applyDragToPoint:p
                         contentRect:cr
                           modifiers:modifiers
                              canvas:canvas];
    return;
  }
  if (![self pointHandleIsActive]) {
    [super miniViewer:canvas
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

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    doubleClickAtPoint:(CGPoint)p
           contentRect:(CGRect)cr {
  self.canvas = canvas;
  return [self.originMini toggleSmoothAtPoint:p contentRect:cr];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  self.canvas = canvas;
  // Base claims the Origin point handle first; then the path anchors/handles.
  if ([super miniViewer:canvas optClickHandleAtPoint:p contentRect:cr])
    return YES;
  if (self.onHandleVisibilityToggled &&
      ([self.originMini pathHandleHitAtPoint:p contentRect:cr] ||
       [self.originMini pathAnchorHitAtPoint:p contentRect:cr])) {
    self.onHandleVisibilityToggled(@"Path");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  if (self.onHandleVisibilityToggled &&
      [self.scaleMini handleHitAtPoint:p contentRect:cr outIndex:NULL]) {
    self.onHandleVisibilityToggled(@"Scale");
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return YES;
  }
  return NO;
}

- (void)miniViewer:(KKMiniViewerView *)canvas
     snapGuideHasX:(out BOOL *)hasX
                 X:(out CGFloat *)outX
      fromKeyposeX:(out BOOL *)fromKeyposeX
              hasY:(out BOOL *)hasY
                 Y:(out CGFloat *)outY
      fromKeyposeY:(out BOOL *)fromKeyposeY {
  [self.originMini snapGuideHasX:hasX
                               X:outX
                    fromKeyposeX:fromKeyposeX
                            hasY:hasY
                               Y:outY
                    fromKeyposeY:fromKeyposeY];
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  [self.scaleMini endDrag];
  // endDrag resets the snap engine and reports whether a motion-path drag was
  // active (so the host persists the full blob).
  if ([self.originMini endDrag]) {
    if (self.onTimelinePersist)
      self.onTimelinePersist(self.timeline);
    [canvas setNeedsDisplay:YES];
    [canvas setHandlesNeedDisplay];
    return;
  }
  [super miniViewerEndHandleDrag:canvas];
}

@end
