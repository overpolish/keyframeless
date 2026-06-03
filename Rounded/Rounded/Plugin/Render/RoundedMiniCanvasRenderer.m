/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedMiniCanvasRenderer.h"

#import "RoundedOSCRadiusMath.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

NSString *const RoundedMiniCanvasDescriptorPath =
    @"/tmp/rounded-minicanvas.json";

NSString *const RoundedMiniCanvasRequestPath =
    @"/tmp/rounded-minicanvas-request.json";

// Mini-canvas analog of the viewer OSC's `oscSize` (KKPointOSC oscRadius +
// outline). Kept in sync with KKMiniCanvasView's kKKMiniHandleOuterPt so
// placement, hit-test and the drawn glyph all agree.
static inline CGFloat MiniOscSize(void) { return 4.5; }
static const CGFloat kHandleHitTolPt = 12.0;

@implementation RoundedMiniCanvasRenderer {
  id<MTLRenderPipelineState> _pipeline;
  MTLPixelFormat _pipelineFormat;
}

- (NSString *)cropLabel {
  return @"Crop";
}
- (NSString *)pointLabel {
  return @"Radius";
}
- (CGFloat)pointHandleSizeScale {
  // Match Magic Move's path-anchor KKPointOSC dot in the mini-canvas (0.6),
  // for both the radius handle and the crop corners.
  return 0.6;
}
- (NSInteger)valueTypeForLabel:(NSString *)label {
  return [label isEqualToString:@"Crop"] ? KKLaneValueTypeCrop
                                         : KKLaneValueTypeFloat;
}
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  if ([label isEqualToString:@"Crop"])
    return @[ @1.0, @1.0, @0.0, @0.0 ];
  if ([label isEqualToString:@"Radius"])
    return @[ @20.0 ];
  return [super defaultValuesForLabel:label];
}

- (BOOL)_ensurePipelineForDevice:(id<MTLDevice>)device
                     pixelFormat:(MTLPixelFormat)format {
  if (_pipeline && _pipelineFormat == format)
    return YES;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib) {
    KKLogError(@"RoundedMiniCanvasRenderer: no metal library: %@", err);
    return NO;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  pd.fragmentFunction = [lib newFunctionWithName:@"fragmentShader"];
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"RoundedMiniCanvasRenderer: pipeline failed: %@", err);
    return NO;
  }
  _pipeline = ps;
  _pipelineFormat = format;
  return YES;
}

- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  if (![self _ensurePipelineForDevice:dest.device pixelFormat:dest.pixelFormat])
    return NO;

  NSArray<NSNumber *> *cv = [self valuesForLabel:@"Crop"];
  float fragRadius =
      (float)[[self valuesForLabel:@"Radius"] firstObject].doubleValue;

  simd_float2 imageSize = {(float)dest.width, (float)dest.height};
  simd_float2 cropCenter, cropSize;
  KKCropModelToShader(cv[0].doubleValue, cv[1].doubleValue, cv[2].doubleValue,
                      cv[3].doubleValue, imageSize, &cropCenter, &cropSize);
  simd_float2 tileOffset = {0.0f, 0.0f};

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  float W = imageSize.x, H = imageSize.y;
  MTLViewport vp = {0, 0, W, H, -1.0, 1.0};
  [e setViewport:vp];
  KKVertex2D verts[4] = {
      {{-W / 2, H / 2}, {0, 0}},
      {{-W / 2, -H / 2}, {0, 1}},
      {{W / 2, H / 2}, {1, 0}},
      {{W / 2, -H / 2}, {1, 1}},
  };
  simd_uint2 vpSize = {(unsigned)W, (unsigned)H};
  [e setRenderPipelineState:_pipeline];
  [e setVertexBytes:verts
             length:sizeof(verts)
            atIndex:KKVertexInputIndex_Vertices];
  [e setVertexBytes:&vpSize
             length:sizeof(vpSize)
            atIndex:KKVertexInputIndex_ViewportSize];
  [e setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
  [e setFragmentBytes:&fragRadius
               length:sizeof(fragRadius)
              atIndex:FragmentIndex_Radius];
  [e setFragmentBytes:&imageSize
               length:sizeof(imageSize)
              atIndex:FragmentIndex_ImageSize];
  [e setFragmentBytes:&tileOffset
               length:sizeof(tileOffset)
              atIndex:FragmentIndex_TileOffsetPx];
  [e setFragmentBytes:&cropCenter
               length:sizeof(cropCenter)
              atIndex:FragmentIndex_CropCenter];
  [e setFragmentBytes:&cropSize
               length:sizeof(cropSize)
              atIndex:FragmentIndex_CropSize];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];
  return YES;
}

- (double)_currentRadius {
  return [[self valuesForLabel:@"Radius"] firstObject].doubleValue;
}

// The radius handle is linked to the crop box: inset diagonally from the
// crop rect's top-right corner by `MiniOscSize + paddingForRadius(radius,
// minDim)` (minDim = crop's min edge; the shader rounds corners relative to
// crop size). Full-image crop ⇒ crop rect == content rect ⇒ fixed corner.
- (CGRect)_anchorRectForContentRect:(CGRect)cr {
  CGRect crop = [self cropRectForContentRect:cr];
  return CGRectIsEmpty(crop) ? cr : crop;
}

- (CGPoint)_handlePointForContentRect:(CGRect)cr radius:(double)radius {
  CGRect a = [self _anchorRectForContentRect:cr];
  float minDim = (float)MIN(a.size.width, a.size.height);
  float off = (float)MiniOscSize() + paddingForRadius(radius, minDim);
  return CGPointMake(CGRectGetMaxX(a) - off, CGRectGetMaxY(a) - off);
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  *outCenter = [self _handlePointForContentRect:cr
                                         radius:[self _currentRadius]];
  return YES;
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)radius
           forContentRect:(CGRect)cr {
  *outCenter = [self _handlePointForContentRect:cr radius:radius];
  return YES;
}

- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  CGPoint hp = [self _handlePointForContentRect:cr
                                         radius:[self _currentRadius]];
  return hypot(p.x - hp.x, p.y - hp.y) <= kHandleHitTolPt;
}

- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniCanvasView *)canvas {
  CGRect a = [self _anchorRectForContentRect:cr];
  float minDim = (float)MIN(a.size.width, a.size.height);
  if (minDim <= 0)
    return;
  // Exact inverse of the viewer-OSC drag: project the cursor onto the corner
  // diagonal, then bisect paddingForRadius to recover the radius.
  double trx = CGRectGetMaxX(a), tryy = CGRectGetMaxY(a);
  double mouseDist = ((trx - p.x) + (tryy - p.y)) * 0.5 - MiniOscSize();
  float lo = 0.0f, hi = 100.0f;
  for (int i = 0; i < 32; i++) {
    float mid = (lo + hi) * 0.5f;
    if (paddingForRadius(mid, minDim) < mouseDist)
      lo = mid;
    else
      hi = mid;
  }
  double radius = MAX(0.0, MIN(100.0, (lo + hi) * 0.5));
  [self commitValues:@[ @(radius) ] forLabel:@"Radius" canvas:canvas];
}

@end
