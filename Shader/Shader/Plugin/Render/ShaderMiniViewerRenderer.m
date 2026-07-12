/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderMiniViewerRenderer.h"

#import "Constants.h"        // ShaderCustomDefaultShaderSource
#import "KKGLSLTranspiler.h" // GLSL -> MSL + channel binding
#import "ShaderColorSpace.h"
#import "ShaderCustomShader.h" // ShaderCustomErrorShaderSource
#import "ShaderTypes.h"
#import "ShaderUniformBuilders.h"
#import <KeyframelessKit/KKPositionMiniController.h>
#import <KeyframelessKit/KKScaleMiniController.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

NSString *const ShaderMiniViewerDescriptorPath = @"/tmp/mesh-miniviewer.json";

NSString *const ShaderMiniViewerRequestPath =
    @"/tmp/mesh-miniviewer-request.json";

NSString *ShaderMiniViewerDescriptorPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return ShaderMiniViewerDescriptorPath;
  return [NSString stringWithFormat:@"/tmp/mesh-miniviewer-%@.json", uuid];
}

NSString *ShaderMiniViewerRequestPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return ShaderMiniViewerRequestPath;
  return
      [NSString stringWithFormat:@"/tmp/mesh-miniviewer-request-%@.json", uuid];
}

@implementation ShaderMiniViewerRenderer {
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
// renderer draws + drags it keyed on `pointLabel`.
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
  if ([label hasPrefix:@"Color "] || [label isEqualToString:@"Bloom Color"])
    return KKLaneValueTypeColor;
  if ([label isEqualToString:@"Origin"] || [label isEqualToString:@"Scale"])
    return KKLaneValueTypeGeneric;
  return KKLaneValueTypeFloat;
}
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  int ci = ShaderIndexForLabel(label, @"Color ");
  if (ci >= 0 && ci < KK_SHADER_COLOR_MAX) {
    const float *c = kShaderDefaultColorsSRGB[ci];
    return @[ @(c[0]), @(c[1]), @(c[2]), @(c[3]) ];
  }
  if ([label isEqualToString:KK_SHADER_COLOR_COUNT_LABEL])
    return @[ @(KK_SHADER_COLOR_COUNT) ];
  if ([label isEqualToString:@"Distortion"])
    return @[ @(KK_SHADER_GRAD_DEFAULT_DISTORTION * 100.0) ];
  if ([label isEqualToString:@"Swirl"])
    return @[ @(KK_SHADER_GRAD_DEFAULT_SWIRL * 100.0) ];
  if ([label isEqualToString:@"Speed"])
    return @[ @(KK_SHADER_GRAD_DEFAULT_SPEED) ];
  if ([label isEqualToString:@"Seed"])
    return @[ @(KK_SHADER_GRAD_DEFAULT_SEED) ];
  if ([label isEqualToString:@"Grain"])
    return @[ @(KK_CORE_GRAIN_DEFAULT * 100.0) ];
  if ([label isEqualToString:@"Grain Size"])
    return @[ @(KK_CORE_GRAINSIZE_DEFAULT) ];
  if ([label isEqualToString:@"Type"])
    return @[ @(ShaderType_Custom) ]; // Custom-only plugin (no Type lane)
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
    KKLogError(@"ShaderMiniViewerRenderer: no metal library: %@", err);
    return nil;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  pd.fragmentFunction = [lib newFunctionWithName:fragmentName];
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"ShaderMiniViewerRenderer: pipeline failed: %@", err);
    return nil;
  }
  _pipelines[fragmentName] = ps;
  return ps;
}

// The Custom type's user shader source from the timeline's "Shader" code lane
// (the default plasma when empty), mirroring the FCP render read.
- (NSString *)_customShaderSource {
  KKLane *shaderLane = nil;
  for (KKLane *lane in self.timeline.lanes)
    if ([lane.label isEqualToString:@"Shader"]) {
      shaderLane = lane;
      break;
    }
  if (shaderLane.codeString.length)
    return shaderLane.codeString;
  if (!shaderLane)
    // Fresh instance: timeline not yet seeded. Mirror the FCP render and use
    // the baked plasma default so the mini matches. A present-but-empty
    // codeString means the user cleared it => passthrough.
    return ShaderCustomDefaultShaderSource();
  return @"void mainImage(out vec4 O, in vec2 fc){ O = "
         @"texture(iChannel0, fc / iResolution.xy); }"; // passthrough when
                                                        // empty
}

// All Custom sections from the Shader lane: Image (codeString) + non-empty
// extra tabs (Common / Buffer A-D) by name. Mirrors the FCP render's blob
// sections.
- (NSDictionary<NSString *, NSString *> *)_customSections {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  KKLane *shaderLane = nil;
  for (KKLane *lane in self.timeline.lanes)
    if ([lane.label isEqualToString:@"Shader"]) {
      shaderLane = lane;
      break;
    }
  if (!shaderLane) {
    // Fresh instance: seed the baked plasma default (mirrors the FCP render).
    out[@"Image"] = ShaderCustomDefaultShaderSource();
    return out;
  }
  if (shaderLane.codeString.length)
    out[@"Image"] = shaderLane.codeString;
  for (NSDictionary *t in shaderLane.codeTabs) {
    NSString *n = t[@"name"], *c = t[@"code"];
    if ([n isKindOfClass:[NSString class]] &&
        [c isKindOfClass:[NSString class]] && c.length)
      out[n] = c;
  }
  return out;
}

// Runtime-compiled pipeline for a Custom shader: the GLSL is
// transpiled to MSL via glslang + SPIRV-Cross (the same shared, memoised path
// as the FCP render), then cached in _pipelines on the emitted MSL hash.
// Returns nil (logged) on failure; the caller falls back to the error pattern.
- (id<MTLRenderPipelineState>)_customPipelineForDevice:(id<MTLDevice>)device
                                           pixelFormat:(MTLPixelFormat)format
                                                source:(NSString *)userSource
                                            bufferMode:(BOOL)bufferMode {
  KKGLSLTranspileResult *tr = bufferMode ? KKTranspileGLSLBuffer(userSource)
                                         : KKTranspileGLSL(userSource);
  if (!tr.msl) {
    KKLogError(@"ShaderMiniViewerRenderer: GLSL transpile failed: %@",
               tr.errorLog);
    return nil;
  }
  if (_pipelineFormat != format) {
    _pipelines = nil;
    _pipelineFormat = format;
  }
  if (!_pipelines)
    _pipelines = [NSMutableDictionary dictionary];
  NSString *key =
      [NSString stringWithFormat:@"custom:%lu", (unsigned long)tr.msl.hash];
  id<MTLRenderPipelineState> existing = _pipelines[key];
  if (existing)
    return existing;
  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:tr.msl
                                            options:nil
                                              error:&err];
  if (!lib) {
    KKLogError(@"ShaderMiniViewerRenderer: custom MSL compile failed: %@", err);
    return nil;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:tr.vertexName];
  pd.fragmentFunction = [lib newFunctionWithName:tr.fragmentName];
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"ShaderMiniViewerRenderer: custom pipeline failed: %@", err);
    return nil;
  }
  _pipelines[key] = ps;
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
    // Mipmapped so the down-blit can area-average the whole minification
    // footprint (trilinear) instead of a single bilinear tap. Without this a
    // fine per-channel dither aliases into chroma speckle when shrunk.
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:dest.pixelFormat
                                     width:refW
                                    height:refH
                                 mipmapped:YES];
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
    KKLogError(@"ShaderMiniViewerRenderer: blit pipeline failed: %@", err);
  return _blitPipeline;
}

- (id<MTLSamplerState>)linearSamplerForDevice:(id<MTLDevice>)device {
  if (_linearSampler)
    return _linearSampler;
  MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
  sd.minFilter = MTLSamplerMinMagFilterLinear;
  sd.magFilter = MTLSamplerMinMagFilterLinear;
  sd.mipFilter = MTLSamplerMipFilterLinear; // trilinear: area-average on shrink
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
  // Build the mip chain so the trilinear sampler averages the full footprint.
  if (src.mipmapLevelCount > 1) {
    id<MTLBlitCommandEncoder> mip = [commandBuffer blitCommandEncoder];
    [mip generateMipmapsForTexture:src];
    [mip endEncoding];
  }
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

// The mini feed publishes the source sRGB-encoded (KKMiniViewerFeed writes
// FCP's linear source through a BGRA8_sRGB texture), so a plain BGRA8 read
// samples GAMMA. Return an _sRGB-typed view of the same IOSurface so sampling
// returns LINEAR, matching the main render (which samples FCP's linear source).
// Falls back to `source` when it has no backing IOSurface or isn't plain BGRA8.
- (id<MTLTexture>)_linearSourceView:(id<MTLTexture>)source {
  if (!source.iosurface || source.pixelFormat != MTLPixelFormatBGRA8Unorm)
    return source;
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                   width:source.width
                                  height:source.height
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> v = [source.device newTextureWithDescriptor:d
                                                   iosurface:source.iosurface
                                                       plane:0];
  return v ?: source;
}

// Custom mini render: Buffer A-D render into offscreen RGBA16F textures on the
// shared command buffer, then the Image pass draws into the hi-res intermediate
// (downscaled to dest). Mirrors the FCP render's multi-pass routing
// (iChannelN->Buffer[N], source/noise fallback); Common is prepended to each. A
// FEEDBACK shader (a buffer reading itself / a later buffer) re-simulates a
// short window at capped resolution so the static preview accumulates; others
// do a single full-res step. The mini keeps no state across renders (unlike the
// FCP render), so this is an approximate preview, not a frame-exact match.
- (BOOL)_encodeCustomEffectFromSource:(id<MTLTexture>)source
                                 into:(id<MTLTexture>)dest
                        commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  id<MTLDevice> device = dest.device;
  NSDictionary<NSString *, NSString *> *sections = [self _customSections];
  NSString *common = sections[@"Common"] ?: @"";
  NSString *image = sections[@"Image"];
  if (image.length == 0)
    image = @"void mainImage(out vec4 O, in vec2 fc){ O = "
            @"texture(iChannel0, fc / iResolution.xy); }"; // passthrough
  NSString * (^withCommon)(NSString *) = ^NSString *(NSString *s) {
    return common.length ? [NSString stringWithFormat:@"%@\n%@", common, s] : s;
  };

  id<MTLTexture> renderTex = [self hiResTargetForDest:dest];
  BOOL downscale = (renderTex != nil);
  if (!renderTex)
    renderTex = dest;
  MTLPixelFormat fmt = renderTex.pixelFormat;
  float W = (float)renderTex.width, H = (float)renderTex.height;
  int encodeSRGB = (dest.pixelFormat == MTLPixelFormatRGBA8Unorm ||
                    dest.pixelFormat == MTLPixelFormatBGRA8Unorm)
                       ? 1
                       : 0;
  float timeSec = (float)self.editFraction;
  NSArray<NSNumber *> *seedV = [self valuesForLabel:@"Seed"];
  float seed = seedV.count ? seedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SEED;
  NSArray<NSNumber *> *speedV = [self valuesForLabel:@"Speed"];
  float speed =
      speedV.count ? speedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SPEED;
  float iTime = timeSec * speed + fmodf(seed, 10000.0f);
  NSArray<NSNumber *> *grV = [self valuesForLabel:@"Grain"];
  NSArray<NSNumber *> *grSzV = [self valuesForLabel:@"Grain Size"];
  float grain = grV.count ? grV[0].floatValue / 100.0f : KK_CORE_GRAIN_DEFAULT;
  float grainSize =
      grSzV.count ? grSzV[0].floatValue : KK_CORE_GRAINSIZE_DEFAULT;

  KKGLSLUniforms base;
  base.resTime = (simd_float4){W, H, 1.0f, iTime};
  base.mouse = (simd_float4){0, 0, 0, 0};
  base.date = (simd_float4){0, 0, 0, 0};
  base.extra =
      (simd_float4){1.0f / 60.0f, iTime * 60.0f, 0.0f, (float)encodeSRGB};
  base.grain = (simd_float4){grain, grainSize, 0.0f, 0.0f};
  for (int c = 0; c < 4; c++)
    base.chanRes[c] = (simd_float4){256.0f, 256.0f, 1.0f, 0.0f};

  id<MTLTexture> srcLin = [self _linearSourceView:source];
  id<MTLSamplerState> srcSampler = KKCustomSourceSampler(device);
  id<MTLTexture> noiseTex = KKCustomChannelNoiseTexture(device);
  id<MTLSamplerState> noiseSampler = KKCustomChannelSampler(device);

  // Precompile buffer pipelines + transpile; detect FEEDBACK (a buffer reading
  // itself or a later buffer, i.e. any channel c >= its own index).
  NSArray<NSString *> *bufNames =
      @[ @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ];
  id<MTLRenderPipelineState> bufPS[4] = {nil, nil, nil, nil};
  KKGLSLTranspileResult *bufTR[4] = {nil, nil, nil, nil};
  BOOL present[4] = {NO, NO, NO, NO};
  BOOL needsFeedback = NO;
  for (int k = 0; k < 4; k++) {
    NSString *bs = sections[bufNames[k]];
    if (bs.length == 0 || W == 0 || H == 0)
      continue;
    NSString *bsrc = withCommon(bs);
    bufPS[k] = [self _customPipelineForDevice:device
                                  pixelFormat:MTLPixelFormatRGBA16Float
                                       source:bsrc
                                   bufferMode:YES];
    if (!bufPS[k])
      continue;
    present[k] = YES;
    bufTR[k] = KKTranspileGLSLBuffer(bsrc);
    for (int c = k; c < 4; c++)
      if (bufTR[k].usedChannelMask & (1u << c))
        needsFeedback = YES;
  }

  // Feedback shaders re-sim a short window (so the static preview accumulates)
  // at a capped resolution (the mini is a preview - keep it cheap).
  // Non-feedback buffers do a single full-res step. `srcLin` is only bound to a
  // channel that has no buffer, so re-sim reads its own previous frame, not the
  // source.
  NSUInteger bufW = (NSUInteger)W, bufH = (NSUInteger)H;
  if (needsFeedback && bufH > (NSUInteger)KK_FEEDBACK_SIM_MAXDIM) {
    bufH = KK_FEEDBACK_SIM_MAXDIM;
    bufW = (NSUInteger)llround((double)W * (double)KK_FEEDBACK_SIM_MAXDIM /
                               (double)H);
  }
  NSInteger frames = needsFeedback ? 48 : 1;
  float dt = (1.0f / 60.0f) * speed; // approximate per-frame iTime step

  id<MTLTexture> setTex[2][4] = {{nil, nil, nil, nil}, {nil, nil, nil, nil}};
  int prevI = 0;
  for (NSInteger f = 0; f < frames; f++) {
    int curI = 1 - prevI;
    BOOL first = (f == 0);
    KKGLSLUniforms fu = base;
    fu.resTime = (simd_float4){(float)bufW, (float)bufH, 1.0f,
                               iTime - (float)(frames - 1 - f) * dt};
    fu.extra.y = (float)f; // iFrame: 0 on the first step (seed-on-frame-0 sims)
    fu.extra.w = 1.0f;     // buffers store raw data (no sRGB encode)
    for (int k = 0; k < 4; k++) {
      if (!bufPS[k])
        continue;
      id<MTLTexture> cur = setTex[curI][k];
      if (!cur) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                         width:bufW
                                        height:bufH
                                     mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        cur = [device newTextureWithDescriptor:td];
        setTex[curI][k] = cur;
      }
      if (!cur)
        continue;
      NSMutableArray *chArr = [NSMutableArray arrayWithCapacity:4];
      KKGLSLUniforms bufU = fu;
      for (int c = 0; c < 4; c++) {
        id<MTLTexture> ct = nil;
        if (present[c]) {
          if (c < k)
            ct = setTex[curI][c];
          else if (!first)
            ct = setTex[prevI][c];
        } else if (c == 0) {
          ct = srcLin;
        }
        [chArr addObject:ct ?: (id)[NSNull null]];
        if (ct)
          bufU.chanRes[c] =
              (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
      }
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = cur;
      rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
      rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
      id<MTLRenderCommandEncoder> be =
          [commandBuffer renderCommandEncoderWithDescriptor:rpd];
      [be setViewport:(MTLViewport){0, 0, (double)bufW, (double)bufH, -1.0,
                                    1.0}];
      [be setRenderPipelineState:bufPS[k]];
      [be setFragmentBytes:&bufU length:sizeof(bufU) atIndex:0];
      KKBindCustomChannelTextures(be, bufTR[k], chArr, srcSampler, noiseTex,
                                  noiseSampler);
      [be drawPrimitives:MTLPrimitiveTypeTriangleStrip
             vertexStart:0
             vertexCount:4];
      [be endEncoding];
    }
    prevI = curI;
  }
  id<MTLTexture> bufTex[4];
  for (int c = 0; c < 4; c++)
    bufTex[c] = setTex[prevI][c];

  NSString *imgSrc = withCommon(image);
  id<MTLRenderPipelineState> imagePS = [self _customPipelineForDevice:device
                                                          pixelFormat:fmt
                                                               source:imgSrc
                                                           bufferMode:NO];
  if (!imagePS) {
    imgSrc = withCommon(ShaderCustomErrorShaderSource());
    imagePS = [self _customPipelineForDevice:device
                                 pixelFormat:fmt
                                      source:imgSrc
                                  bufferMode:NO];
  }
  if (!imagePS)
    return NO;
  KKGLSLTranspileResult *imgTR = KKTranspileGLSL(imgSrc);
  NSMutableArray *imgCh = [NSMutableArray arrayWithCapacity:4];
  KKGLSLUniforms imgU = base;
  for (int c = 0; c < 4; c++) {
    id<MTLTexture> ct = bufTex[c];
    if (!ct && c == 0)
      ct = srcLin;
    [imgCh addObject:ct ?: (id)[NSNull null]];
    if (ct)
      imgU.chanRes[c] =
          (simd_float4){(float)ct.width, (float)ct.height, 1.0f, 0.0f};
  }
  MTLRenderPassDescriptor *irpd =
      [MTLRenderPassDescriptor renderPassDescriptor];
  irpd.colorAttachments[0].texture = renderTex;
  irpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  irpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  irpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:irpd];
  [e setViewport:(MTLViewport){0, 0, W, H, -1.0, 1.0}];
  [e setRenderPipelineState:imagePS];
  [e setFragmentBytes:&imgU length:sizeof(imgU) atIndex:0];
  KKBindCustomChannelTextures(e, imgTR, imgCh, srcSampler, noiseTex,
                              noiseSampler);
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];

  if (downscale)
    [self blitFrom:renderTex into:dest commandBuffer:commandBuffer];
  return YES;
}

// Effect render: runs the same type/custom pipeline as the FCP render into the
// preview dest. `source` is the mini-viewer's source frame (bound as iChannel0
// in the Custom path); the built-in types are procedural and ignore it.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  // Dispatch on the active type, same as the FCP render.
  NSArray<NSNumber *> *typeV = [self valuesForLabel:@"Type"];
  int meshType =
      typeV.count ? (int)lround(typeV[0].doubleValue) : ShaderType_Custom;
  // Custom (single- or multi-pass) has its own dedicated path (Common +
  // buffers).
  if (meshType == ShaderType_Custom)
    return [self _encodeCustomEffectFromSource:source
                                          into:dest
                                 commandBuffer:commandBuffer];
  const ShaderTypeInfo *info = ShaderTypeInfoForType(meshType);
  id<MTLRenderPipelineState> pipeline =
      [self _pipelineForDevice:dest.device
                   pixelFormat:dest.pixelFormat
                fragmentShader:@(info->fragment)];
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
      seedV.count ? seedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SEED;
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
      speedShV.count ? speedShV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SPEED;

  [e setRenderPipelineState:pipeline];
  {
    [e setVertexBytes:verts
               length:sizeof(verts)
              atIndex:KKVertexInputIndex_Vertices];
    [e setVertexBytes:&vpSize
               length:sizeof(vpSize)
              atIndex:KKVertexInputIndex_ViewportSize];

    // Build every Type's uniform from the lanes, then bind the active Type's
    // block (offset/size from the registry). Same builders as the FCP render.
    ShaderPluginState state;
    memset(&state, 0, sizeof(state));
    ShaderLaneReader read = ^NSArray<NSNumber *> *(NSString *label) {
      return [self valuesForLabel:label];
    };
    ShaderBuildAllTypes(read, &state);
    [e setFragmentBytes:(const char *)&state + info->uniformOffset
                 length:info->uniformSize
                atIndex:ShaderFragmentIndex_Grid];

    // Shared params (transforms + timing + grain), same as the FCP render path.
    ShaderCommonUniforms common = ShaderCommonDefault();
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
    common.grainScale = ShaderGrainScaleForType(meshType);
    common.resolution = (vector_float2){W, H};
    [e setFragmentBytes:&common
                 length:sizeof(common)
                atIndex:ShaderFragmentIndex_Common];

    [e setFragmentBytes:&encodeSRGB
                 length:sizeof(encodeSRGB)
                atIndex:ShaderFragmentIndex_EncodeSRGB];
  }
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];

  // Downscale the reference-res intermediate into the actual mini texture.
  if (downscale)
    [self blitFrom:renderTex into:dest commandBuffer:commandBuffer];
  return YES;
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
  // then the Scale box, then the base (rotation - none here).
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
