/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderMiniViewerRenderer.h"
#import "ShaderMiniViewerRenderer_Internal.h"

#import "Constants.h"        // ShaderCustomDefaultShaderSource
#import "KKGLSLTranspiler.h" // GLSL -> MSL + channel binding
#import "ShaderColorSpace.h"
#import "ShaderCustomShader.h" // ShaderCustomErrorShaderSource
#import "ShaderTypes.h"
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
  // Render-at-reference-resolution + downscale (so the small mini texture shows
  // a proper minified copy of a full-res render: grain, dither, everything).
  id<MTLTexture> _hiResTex;
  id<MTLRenderPipelineState> _blitPipeline;
  MTLPixelFormat _blitFormat;
  id<MTLSamplerState> _linearSampler;
  // Source last fed to -_syncMiniPointController, so the per-draw sync is a
  // cheap string compare instead of re-running the directive parse each frame.
  NSString *_pointSyncedSource;
  KKPointOSCSet *_pointSet;
  NSString *_radialSyncedSource;
  KKRingOSCSet *_ringSet;
  KKBoxOSCSet *_boxSet;
  NSString *_rotSyncedSource;
  KKRotationOSCSet *_rotSet;
}

// All point OSCs draw + drag uniformly through the KKPointOSCSet (via the
// Interaction category's extra-handle / extra-path forwards), so the base
// renderer has no single "primary" handle of its own.
- (NSString *)pointLabel {
  return nil;
}

- (KKPointOSCSet *)pointSet {
  if (!_pointSet)
    _pointSet = [[KKPointOSCSet alloc] initWithRenderer:self];
  return _pointSet;
}

// Feed the set the shader's current `#point osc` uniform names (its lane
// identities). Cheap string compare skips the directive parse when the source
// is unchanged; the set itself no-ops when the label list is unchanged.
- (void)_syncMiniPointController {
  NSString *src = [self _customShaderSource] ?: @"";
  if ([src isEqualToString:_pointSyncedSource])
    return;
  _pointSyncedSource = [src copy];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  if (src.length) {
    ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
    int used = 0;
    int n = ShaderParseScalarProps(src, props, KK_SHADER_MAX_SCALAR_PROPS, 0,
                                   &used);
    for (int i = 0; i < n; i++)
      if (props[i].isPoint && strcmp(props[i].oscKind, "point") == 0)
        [labels addObject:@(props[i].name)]; // uniform name = lane identity
  }
  [self.pointSet setLaneLabels:labels];
}

- (KKRingOSCSet *)ringSet {
  if (!_ringSet)
    _ringSet = [[KKRingOSCSet alloc] initWithRenderer:self];
  return _ringSet;
}

- (KKBoxOSCSet *)boxSet {
  if (!_boxSet)
    _boxSet = [[KKBoxOSCSet alloc] initWithRenderer:self];
  return _boxSet;
}

- (KKRotationOSCSet *)rotSet {
  if (!_rotSet)
    _rotSet = [[KKRotationOSCSet alloc] initWithRenderer:self];
  return _rotSet;
}

// Feed the rotation set the shader's current `osc={..}` lanes: one spec per
// rotate directive (label + active-axis bitmask + clip-centre). Cheap string
// compare skips the parse when the source is unchanged.
- (void)_syncMiniRotController {
  NSString *src = [self _customShaderSource] ?: @"";
  if ([src isEqualToString:_rotSyncedSource])
    return;
  _rotSyncedSource = [src copy];
  NSMutableArray<NSDictionary<NSString *, id> *> *rots = [NSMutableArray array];
  if (src.length) {
    ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
    int used = 0;
    int n = ShaderParseScalarProps(src, props, KK_SHADER_MAX_SCALAR_PROPS, 0,
                                   &used);
    for (int i = 0; i < n; i++) {
      if (!ShaderScalarOSCIsRotate(&props[i]))
        continue;
      // Axis bitmask (KKRotationAxisX/Y/Z = 1/2/4) from the braced set; the
      // lane stores its components in canonical X<Y<Z order, which the set
      // expands.
      int axes = ShaderScalarRotationAxisMask(&props[i]);
      [rots addObject:@{
        @"label" : @(props[i].name),
        @"axes" : @(axes),
        @"centerX" : @(props[i].rcenterx),
        @"centerY" : @(props[i].rcentery),
        @"linkLabel" : @(props[i].linkName),
      }];
    }
  }
  [self.rotSet setRotations:rots];
}

// Feed the ring + box sets the shader's current `osc=ring` / `osc=box` scalar
// lanes in ONE parse. A ring and a box share the exact same radial spec (label
// + value range + object-space centre + aspect-lock); only the osc kind picks
// the target set. Cheap string compare skips the parse when the source is
// unchanged.
- (void)_syncMiniRadialControllers {
  NSString *src = [self _customShaderSource] ?: @"";
  if ([src isEqualToString:_radialSyncedSource])
    return;
  _radialSyncedSource = [src copy];
  NSMutableArray<NSDictionary<NSString *, id> *> *rings =
      [NSMutableArray array];
  NSMutableArray<NSDictionary<NSString *, id> *> *boxes =
      [NSMutableArray array];
  if (src.length) {
    ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
    int used = 0;
    int n = ShaderParseScalarProps(src, props, KK_SHADER_MAX_SCALAR_PROPS, 0,
                                   &used);
    for (int i = 0; i < n; i++) {
      if (!ShaderScalarRingEligible(&props[i]))
        continue;
      BOOL isRing = strcmp(props[i].oscKind, "ring") == 0;
      BOOL isBox = ShaderScalarOSCIsBox(&props[i]);
      if (!isRing && !isBox)
        continue;
      BOOL isInt = props[i].isInt || props[i].isPercent;
      int fields = props[i].isMulti
                       ? (props[i].fieldCount > 0 ? props[i].fieldCount : 2)
                       : 1;
      NSDictionary<NSString *, id> *spec = @{
        @"label" : @(props[i].name),
        @"min" : @(props[i].fmin),
        @"max" : @(props[i].fmax),
        @"isInt" : @(isInt),
        @"isPercent" : @(props[i].isPercent != 0),
        @"bounded" : @(props[i].hasMax != 0),
        @"fields" : @(fields),
        @"linked" : @(props[i].aspectLinked != 0),
        @"centerX" : @(props[i].rcenterx),
        @"centerY" : @(props[i].rcentery),
        @"linkLabel" : @(props[i].linkName),
      };
      [(isRing ? rings : boxes) addObject:spec];
    }
  }
  [self.ringSet setRings:rings];
  [self.boxSet setBoxes:boxes];
}

- (KKLane *)templateLaneForLabel:(NSString *)label {
  for (KKLane *l in self.laneTemplates)
    if ([l.label isEqualToString:label])
      return l;
  return [super templateLaneForLabel:label];
}

// No crop box in the mini viewer.
- (NSString *)cropLabel {
  return nil;
}

// Match the viewer's `#point osc` handle (KKPositionOSC draws an arc), so the
// mini-viewer point control looks the same as the on-screen one.
- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStyleArc;
}

// Match the other plugins' mini-viewer dot handles (Rounded / Canvas /
// MagicMove all use 0.6): the `osc=box` handle glyphs read lighter. The #point
// handles are arc-style, so this doesn't touch them.
- (CGFloat)pointHandleSizeScale {
  return 0.6;
}
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  // The plugin is Custom-only now; only the shared lanes have defaults here.
  if ([label isEqualToString:@"Speed"])
    return @[ @(KK_SHADER_GRAD_DEFAULT_SPEED) ];
  if ([label isEqualToString:@"Seed"])
    return @[ @(KK_SHADER_GRAD_DEFAULT_SEED) ];
  if ([label isEqualToString:@"Grain"])
    return @[ @(KK_CORE_GRAIN_DEFAULT * 100.0) ];
  if ([label isEqualToString:@"Grain Size"])
    return @[ @(KK_CORE_GRAINSIZE_DEFAULT) ];

  // Dynamic props declared by the shader. Right after a paste the timeline
  // isn't seeded with these lanes yet, so valuesForLabel lands here. Return the
  // shader-DECLARED default (not super's @[@0], which would drive a `// #float`
  // uniform to 0 and flatten the preview) so the mini matches the first render.
  NSString *src = [self _customShaderSource];
  ShaderScalarProp sp[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int ns =
      ShaderParseScalarProps(src, sp, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);
  for (int i = 0; i < ns; i++)
    if ([label isEqualToString:@(sp[i].name)]) { // uniform name = identity
      if (sp[i].isPoint)
        return @[ @(sp[i].pdefx), @(sp[i].pdefy) ];
      if (sp[i].isMulti) {
        NSMutableArray<NSNumber *> *d = [NSMutableArray array];
        for (int k = 0; k < sp[i].fieldCount && k < 4; k++)
          [d addObject:@(sp[i].mdef[k])];
        return d;
      }
      return @[ @(sp[i].isChoice ? (double)sp[i].cdefault : sp[i].fdefault) ];
    }

  ShaderColorProp cp[KK_SHADER_MAX_COLOR_PROPS];
  int pool = 0;
  int nc = ShaderParseColorProps(src, cp, KK_SHADER_MAX_COLOR_PROPS, &pool);
  for (int i = 0; i < nc; i++) {
    NSString *lbl = @(cp[i].name); // uniform name = identity
    if (!cp[i].isArray) {
      if ([label isEqualToString:lbl]) {
        // Per-index palette colour (matches the catalog + render fallback), not
        // pal[0] for every single colour.
        const float *d = kShaderDefaultPalette[i % 10];
        return @[ @(d[0]), @(d[1]), @(d[2]), @(d[3]) ];
      }
      continue;
    }
    if ([label isEqualToString:[NSString stringWithFormat:@"%@ Count", lbl]])
      return @[ @(cp[i].defaultCount) ];
    for (int n = 1; n <= cp[i].maxCount; n++)
      if ([label
              isEqualToString:[NSString stringWithFormat:@"%@ %d", lbl, n]]) {
        const float *d = kShaderDefaultPalette[(n - 1) % 10];
        return @[ @(d[0]), @(d[1]), @(d[2]), @(d[3]) ];
      }
  }
  return [super defaultValuesForLabel:label];
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
  // A shader's `// #color` properties -> the colour pool (bound after the fixed
  // uniforms, same as the FCP render).
  simd_float4 colorPool[KK_SHADER_COLOR_POOL];
  NSArray<NSNumber *> * (^values)(NSString *) =
      ^NSArray<NSNumber *> *(NSString *label) {
    return [self valuesForLabel:label];
  };
  int colorPoolN = ShaderFillColorPool(image, colorPool, values);
  colorPoolN = ShaderFillScalarPool(image, colorPool, colorPoolN, values);

  id<MTLTexture> srcLin = [self _linearSourceView:source];
  // srcLin is linear (FCP's float source, or the sRGB view that linearises the
  // mini's gamma surface). Shadertoy wants gamma-space input and the output
  // wrapper re-decodes for a float dest, so encode to gamma here to match the
  // main render - otherwise the source double-decodes and the preview darkens.
  // Encodes onto the shared command buffer, ahead of the buffer/image passes.
  srcLin = KKGammaEncodeSourceTextureOnBuffer(commandBuffer, srcLin);
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
      KKBindGLSLUniforms(be, &bufU, colorPool, colorPoolN);
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
  KKBindGLSLUniforms(e, &imgU, colorPool, colorPoolN);
  KKBindCustomChannelTextures(e, imgTR, imgCh, srcSampler, noiseTex,
                              noiseSampler);
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];

  if (downscale)
    [self blitFrom:renderTex into:dest commandBuffer:commandBuffer];
  return YES;
}

// Effect render: the plugin is Custom-only, so this always runs the Custom
// (single- or multi-pass) GLSL path. `source` is the mini-viewer's source frame
// (bound as iChannel0).
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  return [self _encodeCustomEffectFromSource:source
                                        into:dest
                               commandBuffer:commandBuffer];
}

@end
