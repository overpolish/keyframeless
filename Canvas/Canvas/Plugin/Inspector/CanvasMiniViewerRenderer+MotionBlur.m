/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h"
#import "CanvasMiniViewerRenderer_Internal.h"
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKMotionBlurReconstruct.h>
#import <KeyframelessKit/KKShaderTypes.h>

// "Fast" motion blur for the PREVIEW: render the composite once, emit a
// screen-space velocity buffer, reconstruct. Cost is fixed in the tap count
// rather than proportional to the sample count, which is the point of Fast -
// the accumulate path re-renders the whole layer stack N times per preview
// frame and drags playback down.
//
// ONE DELIBERATE DIFFERENCE FROM THE RENDER. The render reconstructs PER LAYER
// (each layer alone over transparent, its own velocity, its own reconstruct,
// then composited) because a single full-frame velocity buffer holds one
// velocity per pixel: where two moving layers overlap, only the one drawn last
// smears. The preview uses a single whole-frame pass instead - one composite,
// one velocity pass, one reconstruct, independent of layer count. That keeps it
// genuinely cheap and reuses -encodeEffectFromSource: wholesale rather than
// duplicating the per-layer draw logic, at the cost of that overlap artifact.
// Visible only where moving layers overlap; the render stays exact.
@implementation CanvasMiniViewerRenderer (MotionBlur)

static id<MTLTexture> CanvasMiniScratchTex(id<MTLTexture> existing,
                                           id<MTLDevice> device, NSUInteger w,
                                           NSUInteger h, MTLPixelFormat fmt) {
  if (existing && existing.width == w && existing.height == h &&
      existing.pixelFormat == fmt)
    return existing;
  if (w == 0 || h == 0)
    return nil;
  MTLTextureDescriptor *td =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                         width:w
                                                        height:h
                                                     mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:td];
}

- (BOOL)encodeFastMotionBlurFromSource:(id<MTLTexture>)source
                                  into:(id<MTLTexture>)dest
                       shutterFraction:(double)shutterFraction
                         commandBuffer:(id<MTLCommandBuffer>)cb {
  NSArray<KKBezierPath *> *layers = self.layers;
  if (!dest || !cb || layers.count == 0 || shutterFraction <= 0.0)
    return NO; // nothing to blur - let the caller render normally

  id<MTLDevice> device = cb.device;
  uint64_t regID = device.registryID;
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  NSString *kitBundleID =
      [NSBundle bundleForClass:[KKMotionBlurReconstruct class]].bundleIdentifier;

  id<MTLRenderPipelineState> velPS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.mini.velocity"
                                    registryID:regID
                                   pixelFormat:MTLPixelFormatRG16Float
                                      bundleID:kitBundleID
                                  vertexShader:@"KKVelocityVertexShader"
                                fragmentShader:@"KKVelocityFragment"
                                     blendMode:KKBlendModeNone];
  id<MTLRenderPipelineState> morphVelPS = [cache
      buildAndRegisterPipelineStateForPluginID:@"co.overpolish.keyframeless"
                                               @".Canvas.mini.velocity.morph"
                                    registryID:regID
                                   pixelFormat:MTLPixelFormatRG16Float
                                      bundleID:kitBundleID
                                  vertexShader:@"KKVelocityMorphVertexShader"
                                fragmentShader:@"KKVelocityFragment"
                                     blendMode:KKBlendModeNone];
  if (!velPS)
    return NO;

  NSUInteger w = dest.width, h = dest.height;
  _mbColorTex =
      CanvasMiniScratchTex(_mbColorTex, device, w, h, dest.pixelFormat);
  _mbVelocityTex = CanvasMiniScratchTex(_mbVelocityTex, device, w, h,
                                        MTLPixelFormatRG16Float);
  if (!_mbColorTex || !_mbVelocityTex)
    return NO;

  // 1. Colour: the ordinary composite, into scratch instead of dest. Unchanged
  // logic, so the blurred preview can never diverge from the unblurred one.
  if (![self encodeEffectFromSource:source into:_mbColorTex commandBuffer:cb])
    return NO;

  // 2. Velocity: displacement from the shutter start to now, in dest pixels.
  double frac = self.editFraction;
  double fPrev = MAX(0.0, frac - shutterFraction);
  float fw = (float)w, fh = (float)h;
  const float marginPx = 64.0f; // cover stroke width; smear handled by tiles
  float maxVel = 0.0f;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = _mbVelocityTex;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rpd];
  [e setViewport:(MTLViewport){0, 0, (double)fw, (double)fh, -1, 1}];
  simd_uint2 vp = {(unsigned)w, (unsigned)h};
  [e setVertexBytes:&vp length:sizeof(vp) atIndex:KKVertexInputIndex_ViewportSize];
  [e setRenderPipelineState:velPS];
  for (NSInteger i = 0; i < (NSInteger)layers.count; i++) {
    KKBezierPath *p = layers[i];
    if (p.isGroup || p.hidden)
      continue;
    maxVel = fmaxf(maxVel,
                   CanvasLayerMaxVelocityPx(layers, i, frac, fPrev, fw, fh, 0.0f,
                                            0.0f, self.selectedLayerID,
                                            self.timeline));
    // Same four passes, in the same order, as the render's velocity encode:
    // transform/morph, then stroke-width edges, then corner fillets, then a
    // draw-on marker. Each later pass deliberately overwrites the regions the
    // earlier ones can't describe.
    CanvasEncodeLayerVelocityQuad(layers, e, i, frac, fPrev, fw, fh, 0.0f, 0.0f,
                                  marginPx, morphVelPS, self.selectedLayerID,
                                  self.timeline);
    CanvasEncodeStrokeWidthVelocity(layers, e, i, frac, fPrev, fw, fh, 0.0f,
                                    0.0f, morphVelPS, self.selectedLayerID,
                                    self.timeline);
    CanvasEncodeCornerFilletVelocity(layers, e, i, frac, fPrev, fw, fh, 0.0f,
                                     0.0f, morphVelPS, self.selectedLayerID,
                                     self.timeline);
    CanvasEncodeMarkerVelocity(layers, e, i, frac, fPrev, fw, fh, 0.0f, 0.0f,
                               morphVelPS, self.selectedLayerID, self.timeline);
  }
  [e endEncoding];

  // 3. Reconstruct. Tile size bounds the blur reach, so scale it to the actual
  // motion the way the render does - a still frame reconstructs to a no-op at
  // the floor, and a fast one gets a longer trail instead of clamping.
  int tileSize = (int)fmaxf(8.0f, fminf(128.0f, ceilf(maxVel)));
  int taps = (int)fmaxf(9.0f, fminf(25.0f, ceilf((float)tileSize / 6.0f)));
  return [KKMotionBlurReconstruct encodeReconstructionToTexture:dest
                                                   colorTexture:_mbColorTex
                                                velocityTexture:_mbVelocityTex
                                                       tileSize:tileSize
                                                    sampleCount:taps
                                                     registryID:regID
                                                         device:device
                                                  commandBuffer:cb];
}

@end
