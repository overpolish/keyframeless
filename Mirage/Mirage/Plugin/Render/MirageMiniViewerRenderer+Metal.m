/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The mini preview's Metal plumbing: the transpiled-pipeline cache, the
// render-at-reference-resolution target and its downscaling blit, and the
// colour-matched `// #frames` neighbour textures.
//
// Every one of these is a CACHE keyed on whatever would invalidate it, because
// a preview redraws far more often than its inputs change.

#import "MirageMiniViewerRenderer.h"
#import "MirageMiniViewerRenderer_Internal.h"
#import <KeyframelessKit/KKLog.h>

#import "Constants.h"        // MirageCustomDefaultShaderSource
#import "KKGLSLTranspiler.h" // GLSL -> MSL + channel binding
#import "MirageAudioPool.h"
#import "MirageCustomShader.h" // MirageCustomErrorShaderSource
#import "MirageDirectives.h"
#import "MirageExprMiniSet.h"
#import "MirageFrameOffsets.h" // `// #frames` neighbour offsets
#import "MirageRack.h"
#import "MirageRenderUniforms.h" // MirageMakeUniforms (shared with FCP render)
#import "MirageTypes.h"
#import "Plugin+Render_Internal.h" // kMiragePassthroughSource
#import "Plugin_Private.h"
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>
#import <math.h>
#import <simd/simd.h>

@implementation MirageMiniViewerRenderer (Metal)

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
    KKLogError(@"MirageMiniViewerRenderer: GLSL transpile failed: %@",
               tr.errorLog);
    return nil;
  }
  if (!_pipelines)
    _pipelines = [NSMutableDictionary dictionary];
  // Keyed on the PIXEL FORMAT as well as the MSL digest. A chain asks for both
  // formats within a single draw - every entry but the last renders into an
  // RGBA16Float intermediate while the last renders into the target's own
  // format - so a single-format guard that dropped the whole dictionary on a
  // mismatch cleared it twice per draw and recompiled every entry's shader on
  // every drawn frame. Two formats of one shader are two pipelines; hold both.
  NSString *key = [NSString
      stringWithFormat:@"custom:%lu:%@", (unsigned long)format, tr.mslDigest];
  id<MTLRenderPipelineState> existing = _pipelines[key];
  if (existing)
    return existing;
  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:tr.msl
                                            options:nil
                                              error:&err];
  if (!lib) {
    KKLogError(@"MirageMiniViewerRenderer: custom MSL compile failed: %@", err);
    return nil;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:tr.vertexName];
  pd.fragmentFunction = [lib newFunctionWithName:tr.fragmentName];
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"MirageMiniViewerRenderer: custom pipeline failed: %@", err);
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
  // Motion blur re-renders this N times per preview frame, and at 1080 that
  // made each sample as expensive as a full render tick. The intermediate only
  // buys correct MINIFICATION of grain / dither, which the blur's averaging
  // destroys anyway, so skip it while sampling. Mirage can't use the Fast
  // (velocity) technique - an arbitrary GLSL shader has no analytic velocity -
  // so the sample path has to be affordable on its own.
  if (self.previewMotionBlurSampling)
    return nil;
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
    KKLogError(@"MirageMiniViewerRenderer: blit pipeline failed: %@", err);
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

// The `// #frames` neighbour textures to bind for `source`, in DIRECTIVE order.
//
// Call this BEFORE opening any render encoder on `commandBuffer`: matching a
// neighbour's colour to iChannel0 encodes its own render pass, exactly like the
// srcLin / toLin conversions this sits beside, and a command buffer permits one
// live encoder at a time.
//
// The conversions are CACHED per aux index and reused until the render process
// pumps a new frame. A drag redraws the mini many times against neighbours that
// cannot have changed, and each conversion is a full-frame pass plus an
// RGBA16Float allocation - multiplied by the filmstrip's slot count, since the
// effect pass runs once per slot. Reconverting per redraw was the mini's lag on
// a `#frames` shader.
//
// The render process pumps the neighbours it resolved into the feed's auxiliary
// textures, so a trails / echo / temporal shader previews on the real frames.
// Between FCP renders the last pumped set stays - tuning on a parked playhead
// has to keep previewing, so nothing here invalidates them.
//
// Three deterministic fallbacks, all of which return a short/empty array that
// KKBindCustomNeighborTextures fills with the caller's current-frame fallback
// (skipping the bind is not an option: a declared-but-unbound sampler aborts
// under Metal API Validation):
//   - the shader declares no offsets, so there is nothing to bind;
//   - nothing pumped yet (cold boot, or a shader without `// #frames`);
//   - the pumped count disagrees with the directive, which is a pump from
//     before a directive edit - clamping is wrong-but-stable, mis-indexing
//     would show frames the shader never asked for.
- (NSArray *)_neighborTexturesForSource:(NSString *)source
                     technicalTransform:(BOOL)technicalTransform
                          commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  MirageFrameOffsets fo = MirageFrameOffsetsForSource(source, NULL);
  if (fo.count <= 0)
    return @[];
  NSUInteger available = self.canvas.auxTextureCount;
  NSString *signature =
      [NSString stringWithFormat:@"%d/%+d/%lu", fo.count, fo.offsets[0],
                                 (unsigned long)available];
  if (![signature isEqualToString:_neighborBindSignature]) {
    _neighborBindSignature = [signature copy];
    KKLogDebug(@"[Mirage] mini bind neighbours declared=%d firstOffset=%+d "
               @"pumped=%lu",
               fo.count, fo.offsets[0], (unsigned long)available);
  }
  if (available != (NSUInteger)fo.count)
    return @[];
  if (!_neighborConversions)
    _neighborConversions = [NSMutableArray array];
  while (_neighborConversions.count < available)
    [_neighborConversions addObject:[[_MirageNeighborConversion alloc] init]];
  while (_neighborConversions.count > available)
    [_neighborConversions removeLastObject];

  NSMutableArray *out = [NSMutableArray arrayWithCapacity:available];
  for (NSUInteger i = 0; i < available; i++) {
    id<MTLTexture> raw = [self.canvas auxTextureAtIndex:i];
    _MirageNeighborConversion *entry = _neighborConversions[i];
    if (!raw) {
      entry.raw = nil;
      entry.converted = nil;
      [out addObject:[NSNull null]];
      continue;
    }
    // Keyed on the PUBLISHER's generation as well as the texture object: the
    // feed writes each new frame into the same IOSurface, so the wrapper object
    // alone would report "unchanged" forever and the preview would freeze on
    // the first pumped neighbours.
    uint64_t generation = [self.canvas auxTextureGenerationAtIndex:i];
    if (entry.converted && entry.raw == raw && entry.generation == generation &&
        entry.technicalTransform == technicalTransform) {
      [out addObject:entry.converted];
      continue;
    }
    // The same colour handling iChannel0 gets a few lines above, so a temporal
    // blend mixes like values: the feed's surface is display-encoded, so read
    // it linearly, then re-encode to gamma for an ordinary Shadertoy shader.
    id<MTLTexture> tex = [self _linearSourceView:raw];
    if (!technicalTransform)
      tex = KKGammaEncodeSourceTextureOnBuffer(commandBuffer, tex) ?: tex;
    entry.raw = raw;
    entry.generation = generation;
    entry.technicalTransform = technicalTransform;
    // Written by THIS command buffer and read by later ones. Safe without a
    // fence: every mini draw commits on the one view queue, and command buffers
    // on a queue execute in commit order. Metal retains a resource for as long
    // as any encoded buffer references it, so replacing the entry cannot pull a
    // texture out from under a frame still in flight.
    entry.converted = tex;
    [out addObject:tex ?: (id)[NSNull null]];
  }

  return out;
}

@end
