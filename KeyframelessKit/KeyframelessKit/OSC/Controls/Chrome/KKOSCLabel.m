/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCLabel.h"
#import "KKOSCShaderTypes.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

static NSString *const kLabelPipelineID =
    @"co.overpolish.keyframelesskit.Label";
static const CGFloat kScale = 2.0;
static const CGFloat kFontSize = 20.0;
static const CGFloat kStrokePt = 3.0;

static NSColor *labelFillColor(void) {
  return [NSColor colorWithRed:0xC1 / 255.0
                         green:0xC1 / 255.0
                          blue:0xC1 / 255.0
                         alpha:1.0f];
}
static NSColor *labelStrokeColor(void) {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.8f];
}

@implementation KKOSCLabel {
  id<PROAPIAccessing> __weak _apiManager;
  NSString *_cachedText;
  BOOL _cachedMonospaced;
  id<MTLTexture> _texture;
  CGSize _size;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _text = @"";
  }
  return self;
}

- (CGSize)size {
  return _size;
}

- (void)updateTextureForDevice:(id<MTLDevice>)device {
  if (_texture && [_cachedText isEqualToString:_text] &&
      _cachedMonospaced == _monospaced)
    return;

  NSFont *font = _monospaced
                     ? [NSFont monospacedSystemFontOfSize:kFontSize
                                                   weight:NSFontWeightMedium]
                     : [NSFont systemFontOfSize:kFontSize
                                         weight:NSFontWeightMedium];
  NSDictionary *strokeAttrs = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : labelStrokeColor(),
    NSStrokeColorAttributeName : labelStrokeColor(),
    NSStrokeWidthAttributeName : @(kStrokePt / kFontSize * 100.0)
  };
  NSDictionary *fillAttrs = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : labelFillColor(),
  };
  NSSize textSize = [_text sizeWithAttributes:fillAttrs];

  NSInteger logicalW = (NSInteger)ceil(textSize.width) + 4;
  NSInteger logicalH = (NSInteger)ceil(textSize.height) + 2;
  if (logicalW < 1)
    logicalW = 1;
  if (logicalH < 1)
    logicalH = 1;

  _size = CGSizeMake(logicalW, logicalH);

  NSInteger pixelW = (NSInteger)(logicalW * kScale);
  NSInteger pixelH = (NSInteger)(logicalH * kScale);

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, pixelW, pixelH, 8, pixelW * 4, cs,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx)
    return;

  CGContextScaleCTM(ctx, kScale, kScale);

  NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx
                                                                  flipped:NO];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:gc];
  [_text drawAtPoint:NSMakePoint(2, 1) withAttributes:strokeAttrs];
  [_text drawAtPoint:NSMakePoint(2, 1) withAttributes:fillAttrs];
  [NSGraphicsContext restoreGraphicsState];

  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:pixelW
                                  height:pixelH
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  _texture = [device newTextureWithDescriptor:desc];
  [_texture replaceRegion:MTLRegionMake2D(0, 0, pixelW, pixelH)
              mipmapLevel:0
                withBytes:CGBitmapContextGetData(ctx)
              bytesPerRow:pixelW * 4];

  CGContextRelease(ctx);
  _cachedText = [_text copy];
  _cachedMonospaced = _monospaced;
}

- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
            destinationImage:(FxImageTile *)destinationImage {
  if (_text.length == 0)
    return;

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  if (!device)
    return;

  [self updateTextureForDevice:device];
  if (!_texture)
    return;

  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:kLabelPipelineID
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:@"co.overpolish"
                                                ".keyframeless"
                                                ".KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLabelFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!ps)
    return;

  float halfW = _size.width / 2.0f;
  float halfH = _size.height / 2.0f;
  id<MTLTexture> tex = _texture;

  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];

  id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:registryID
                                                    pixelFormat:pixelFormat];
  if (!queue)
    return;

  id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
  cmdBuf.label = @"KKOSCLabel Command Buffer";
  [cmdBuf enqueue];

  id<MTLTexture> outTex = [destinationImage
      metalTextureForDevice:[cache deviceWithRegistryID:registryID]];

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = outTex;
  rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> encoder =
      [cmdBuf renderCommandEncoderWithDescriptor:rpd];

  MTLViewport viewport = {0, 0, ioW, ioH, -1.0, 1.0};
  [encoder setViewport:viewport];

  CGPoint metalPos = {canvasPosition.x - ioW / 2.0f,
                      ioH / 2.0f - canvasPosition.y};

  float l = metalPos.x - halfW;
  float r = metalPos.x + halfW;
  float b = metalPos.y - halfH;
  float t = metalPos.y + halfH;
  KKVertex2D verts[6] = {
      {{l, b}, {0, 0}}, {{r, b}, {1, 0}}, {{r, t}, {1, 1}},
      {{l, b}, {0, 0}}, {{r, t}, {1, 1}}, {{l, t}, {0, 1}},
  };

  simd_uint2 viewportSize = {(unsigned int)ioW, (unsigned int)ioH};

  [encoder setRenderPipelineState:ps];
  [encoder setVertexBytes:verts
                   length:sizeof(verts)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setVertexBytes:&viewportSize
                   length:sizeof(viewportSize)
                  atIndex:KKVertexInputIndex_ViewportSize];
  [encoder setFragmentTexture:tex atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

  [encoder endEncoding];
  [cmdBuf commit];
  [cmdBuf waitUntilScheduled];
  [cache returnCommandQueueToCache:queue];
}

@end
