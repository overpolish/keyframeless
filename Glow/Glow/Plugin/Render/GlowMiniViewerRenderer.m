/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "GlowMiniViewerRenderer.h"

#import "Constants.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <simd/simd.h>

NSString *const GlowMiniViewerDescriptorPath = @"/tmp/glow-miniviewer.json";
NSString *const GlowMiniViewerRequestPath =
    @"/tmp/glow-miniviewer-request.json";

// Prep + blur run in float, matching the main render (FCP tiles are
// RGBA16Float). The mini dest is 8-bit BGRA, which would quantize the soft
// glow tail toward zero in an 8-bit blur - making the preview read as a
// tighter/dimmer glow than the viewer. Compositing still targets the 8-bit
// dest; only the blur intermediates need the extra precision.
static const MTLPixelFormat kGlowMiniBlurFormat = MTLPixelFormatRGBA16Float;

// The sRGB sibling of an 8-bit format, so a view of it gamma-encodes on write /
// decodes on read (a linear-light working pass). Returns the input unchanged if
// there's no sRGB sibling (then no gamma conversion happens).
static MTLPixelFormat GlowSRGBVariant(MTLPixelFormat f) {
  switch (f) {
  case MTLPixelFormatBGRA8Unorm:
    return MTLPixelFormatBGRA8Unorm_sRGB;
  case MTLPixelFormatRGBA8Unorm:
    return MTLPixelFormatRGBA8Unorm_sRGB;
  default:
    return f;
  }
}

@implementation GlowMiniViewerRenderer {
  id<MTLRenderPipelineState> _prepPipeline;
  id<MTLRenderPipelineState> _compPipeline;
  MTLPixelFormat _pipelineFormat;
}

// Glow has no Crop lane (M1) - return nil so the base renderer doesn't try to
// draw / hit-test the default crop box against a missing lane (crashes).
- (NSString *)cropLabel {
  return nil;
}

- (NSInteger)valueTypeForLabel:(NSString *)label {
  return KKLaneValueTypeFloat;
}

- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  if ([label isEqualToString:@"Radius"])
    return @[ @(kGlowM1Radius), @(kGlowM1Radius) ];
  return [super defaultValuesForLabel:label];
}

- (BOOL)_ensurePipelinesForDevice:(id<MTLDevice>)device
                      pixelFormat:(MTLPixelFormat)format {
  if (_prepPipeline && _compPipeline && _pipelineFormat == format)
    return YES;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib) {
    KKLogError(@"GlowMiniViewerRenderer: no metal library: %@", err);
    return NO;
  }
  MTLRenderPipelineDescriptor *prep =
      [[MTLRenderPipelineDescriptor alloc] init];
  prep.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  prep.fragmentFunction = [lib newFunctionWithName:@"glowPrep"];
  prep.colorAttachments[0].pixelFormat = kGlowMiniBlurFormat; // float prep tex
  id<MTLRenderPipelineState> prepPS =
      [device newRenderPipelineStateWithDescriptor:prep error:&err];
  if (!prepPS) {
    KKLogError(@"GlowMiniViewerRenderer: prep pipeline failed: %@", err);
    return NO;
  }
  MTLRenderPipelineDescriptor *comp =
      [[MTLRenderPipelineDescriptor alloc] init];
  comp.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  comp.fragmentFunction = [lib newFunctionWithName:@"glowComposite"];
  // Render into the sRGB VIEW of the (8-bit) dest, so the shader's linear-light
  // output is gamma-encoded on write - matching the main viewer, which works in
  // FCP's float/linear space. Without this the glow is composited and shown in
  // gamma space and reads far too dim.
  comp.colorAttachments[0].pixelFormat = GlowSRGBVariant(format);
  id<MTLRenderPipelineState> compPS =
      [device newRenderPipelineStateWithDescriptor:comp error:&err];
  if (!compPS) {
    KKLogError(@"GlowMiniViewerRenderer: composite pipeline failed: %@", err);
    return NO;
  }
  _prepPipeline = prepPS;
  _compPipeline = compPS;
  _pipelineFormat = format;
  return YES;
}

- (id<MTLTexture>)_scratchForDevice:(id<MTLDevice>)device
                             format:(MTLPixelFormat)format
                              width:(NSUInteger)w
                             height:(NSUInteger)h {
  MTLTextureDescriptor *d =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                         width:MAX(1, w)
                                                        height:MAX(1, h)
                                                     mipmapped:NO];
  d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
            MTLTextureUsageShaderWrite;
  d.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:d];
}

// Self-contained glow preview. Unlike the render path (Plugin+Render.m) this
// runs in the inspector process on raw source/dest MTLTextures, so it cannot
// touch the render-side texture pool. M1 skips the bloom lane (threshold 0)
// and uses the kGlowM1* fallbacks for every field except the animated radius.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  if (![self _ensurePipelinesForDevice:dest.device
                           pixelFormat:dest.pixelFormat])
    return NO;

  // Work in linear light: read the (gamma-encoded) source through an sRGB view
  // (decodes sRGB->linear on sample) and write the composite through an sRGB
  // view of the dest (encodes linear->sRGB on store). Falls back to the plain
  // textures if a view can't be made.
  id<MTLTexture> srcLin =
      [source newTextureViewWithPixelFormat:GlowSRGBVariant(source.pixelFormat)]
          ?: source;
  id<MTLTexture> dstSRGB =
      [dest newTextureViewWithPixelFormat:GlowSRGBVariant(dest.pixelFormat)]
          ?: dest;
  source = srcLin;

  NSArray<NSNumber *> *rv = [self valuesForLabel:@"Radius"];
  double rx = rv.count >= 1 ? rv[0].doubleValue : kGlowM1Radius;
  double ry = rv.count >= 2 ? rv[1].doubleValue : rx;

  // Map the full source frame to the dest (same as the main viewer: the glow
  // forms wherever the source is transparent - around a logo's edges, etc. -
  // which for normal centred content is INSIDE the frame). Radius is canonical
  // source pixels; scale it into the (smaller) preview's pixel space so the
  // glow keeps its visual proportion (glow:content ratio matches the viewer).
  float W = (float)dest.width, H = (float)dest.height;
  float scale = source.width > 0 ? W / (float)source.width : 1.0f;
  float effRx = (float)rx * scale, effRy = (float)ry * scale;
  float sigma = fmaxf(fmaxf(effRx, effRy) * 0.5f, 0.5f);

  id<MTLTexture> prepTex = [self _scratchForDevice:dest.device
                                            format:kGlowMiniBlurFormat
                                             width:dest.width
                                            height:dest.height];
  id<MTLTexture> blurTex = [self _scratchForDevice:dest.device
                                            format:kGlowMiniBlurFormat
                                             width:dest.width
                                            height:dest.height];
  if (!prepTex || !blurTex)
    return NO;

  simd_uint2 vp = {(uint)W, (uint)H};
  MTLViewport viewport = {0, 0, (double)W, (double)H, -1, 1};

  // 1) Prep: draw source into prepTex (full frame; dynamic mode keeps RGBA).
  KKVertex2D srcV[] = {
      {{W / 2, -H / 2}, {1, 1}},
      {{-W / 2, -H / 2}, {0, 1}},
      {{W / 2, H / 2}, {1, 0}},
      {{-W / 2, H / 2}, {0, 0}},
  };
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = prepTex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [e setViewport:viewport];
    [e setVertexBytes:srcV
               length:sizeof(srcV)
              atIndex:KKVertexInputIndex_Vertices];
    [e setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
    [e setRenderPipelineState:_prepPipeline];
    [e setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
    int cm = kGlowM1ColorMode;
    [e setFragmentBytes:&cm length:sizeof(cm) atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
    [e endEncoding];
  }

  // 2) MPS Gaussian blur: prepTex -> blurTex.
  {
    MPSImageGaussianBlur *mps =
        [[MPSImageGaussianBlur alloc] initWithDevice:dest.device sigma:sigma];
    mps.edgeMode = MPSImageEdgeModeClamp;
    [mps encodeToCommandBuffer:commandBuffer
                 sourceTexture:prepTex
            destinationTexture:blurTex];
  }

  // 3) Composite into dest. Geometry mirrors the render path's full-image
  // case; sampling is derived from the fragment window position + uniforms.
  KKVertex2D dstV[] = {
      {{W / 2, -H / 2}, {1, 1}},
      {{-W / 2, -H / 2}, {0, 1}},
      {{W / 2, H / 2}, {1, 0}},
      {{-W / 2, H / 2}, {0, 0}},
  };
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = dstSRGB; // gamma-encode on store
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [e setViewport:viewport];
    [e setVertexBytes:dstV
               length:sizeof(dstV)
              atIndex:KKVertexInputIndex_Vertices];
    [e setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
    [e setRenderPipelineState:_compPipeline];
    [e setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
    [e setFragmentTexture:blurTex atIndex:1];
    [e setFragmentTexture:blurTex atIndex:2];

    float rxF = effRx, ryF = effRy;
    float intensity = kGlowM1Intensity, falloff = kGlowM1Falloff,
          noise = kGlowM1Noise, noiseOffset = kGlowM1NoiseOffset,
          noiseSeed = kGlowM1NoiseSeed, gradAngle = kGlowM1GradientAngle,
          threshold = kGlowM1Threshold;
    int colorMode = kGlowM1ColorMode, gradType = kGlowM1GradientType;
    simd_float2 offset = {0.0f, 0.0f};
    simd_float3 glowColor = {1.0f, 1.0f, 1.0f};
    simd_float3 lut[KK_GRADIENT_LUT_SIZE];
    for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++)
      lut[i] = glowColor;
    simd_float2 blurUVScale = {1.0f, 1.0f};
    simd_float2 tileOffsetPx = {0.0f, 0.0f};
    simd_float2 destImgSizePx = {W, H};
    simd_float2 srcOriginInDestPx = {0.0f, 0.0f};
    simd_float2 srcImgSizePx = {W, H};

    [e setFragmentBytes:&rxF length:sizeof(rxF) atIndex:FragmentIndex_RadiusX];
    [e setFragmentBytes:&ryF length:sizeof(ryF) atIndex:FragmentIndex_RadiusY];
    [e setFragmentBytes:&intensity
                 length:sizeof(intensity)
                atIndex:FragmentIndex_Intensity];
    [e setFragmentBytes:&falloff
                 length:sizeof(falloff)
                atIndex:FragmentIndex_Falloff];
    [e setFragmentBytes:&offset
                 length:sizeof(offset)
                atIndex:FragmentIndex_Offset];
    [e setFragmentBytes:&glowColor
                 length:sizeof(glowColor)
                atIndex:FragmentIndex_GlowColor];
    [e setFragmentBytes:&colorMode
                 length:sizeof(colorMode)
                atIndex:FragmentIndex_ColorMode];
    [e setFragmentBytes:lut
                 length:sizeof(lut)
                atIndex:FragmentIndex_GradientLUT];
    [e setFragmentBytes:&gradType
                 length:sizeof(gradType)
                atIndex:FragmentIndex_GradientType];
    [e setFragmentBytes:&gradAngle
                 length:sizeof(gradAngle)
                atIndex:FragmentIndex_GradientAngle];
    [e setFragmentBytes:&noise
                 length:sizeof(noise)
                atIndex:FragmentIndex_Noise];
    [e setFragmentBytes:&noiseOffset
                 length:sizeof(noiseOffset)
                atIndex:FragmentIndex_NoiseOffset];
    [e setFragmentBytes:&noiseSeed
                 length:sizeof(noiseSeed)
                atIndex:FragmentIndex_NoiseSeed];
    [e setFragmentBytes:&blurUVScale
                 length:sizeof(blurUVScale)
                atIndex:FragmentIndex_BlurUVScale];
    [e setFragmentBytes:&threshold
                 length:sizeof(threshold)
                atIndex:FragmentIndex_Threshold];
    [e setFragmentBytes:&tileOffsetPx
                 length:sizeof(tileOffsetPx)
                atIndex:FragmentIndex_TileOffsetPx];
    [e setFragmentBytes:&destImgSizePx
                 length:sizeof(destImgSizePx)
                atIndex:FragmentIndex_DestImgSizePx];
    [e setFragmentBytes:&srcOriginInDestPx
                 length:sizeof(srcOriginInDestPx)
                atIndex:FragmentIndex_SrcOriginInDestPx];
    [e setFragmentBytes:&srcImgSizePx
                 length:sizeof(srcImgSizePx)
                atIndex:FragmentIndex_SrcImgSizePx];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
    [e endEncoding];
  }
  return YES;
}

@end
