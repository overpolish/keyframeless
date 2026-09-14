/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKIconButtonOSC.h"
#import "KKOSCShaderTypes.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

static NSString *const kIconButtonPipelineID =
    @"com.keyframeless.kit.IconButton";
static const CGFloat kScale = 2.0;
static const CGFloat kSymbolSize = 19.0;
static const CGFloat kHitRadius = 16.0;
static const CGFloat kCanvasSize = 32.0;

static NSColor *iconButtonFillColor(void) {
  return [NSColor colorWithRed:0xC1 / 255.0
                         green:0xC1 / 255.0
                          blue:0xC1 / 255.0
                         alpha:1.0f];
}
static NSColor *iconButtonStrokeColor(void) {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.5f];
}

@implementation KKIconButtonOSC {
  id<PROAPIAccessing> __weak _apiManager;
  NSString *_cachedIconName;
  id<MTLTexture> _texture;
  CGSize _size;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _iconName = @"";
  }
  return self;
}

- (CGSize)size {
  return _size;
}

- (void)updateTextureForDevice:(id<MTLDevice>)device {
  if (_texture && [_cachedIconName isEqualToString:_iconName])
    return;

  NSImage *symbol = [NSImage imageWithSystemSymbolName:_iconName
                              accessibilityDescription:nil];
  if (!symbol)
    return;

  NSImageSymbolConfiguration *sizeConfig = [NSImageSymbolConfiguration
      configurationWithPointSize:kSymbolSize
                          weight:NSFontWeightMedium];
  NSImageSymbolConfiguration *strokeCfg = [NSImageSymbolConfiguration
      configurationWithPaletteColors:@[ iconButtonStrokeColor() ]];
  NSImageSymbolConfiguration *fillCfg = [NSImageSymbolConfiguration
      configurationWithPaletteColors:@[ iconButtonFillColor() ]];
  NSImage *strokeSymbol =
      [symbol imageWithSymbolConfiguration:
                  [sizeConfig configurationByApplyingConfiguration:strokeCfg]];
  NSImage *fillSymbol =
      [symbol imageWithSymbolConfiguration:
                  [sizeConfig configurationByApplyingConfiguration:fillCfg]];

  NSSize imageSize = fillSymbol.size;
  NSInteger logicalW = (NSInteger)kCanvasSize;
  NSInteger logicalH = (NSInteger)kCanvasSize;

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

  CGFloat originX = (logicalW - imageSize.width) / 2.0;
  CGFloat originY = (logicalH - imageSize.height) / 2.0;
  NSRect drawRect =
      NSMakeRect(originX, originY, imageSize.width, imageSize.height);

  // Outline: draw stroke symbol offset in 8 directions
  CGFloat strokeOffset = 1.5;
  for (CGFloat dx = -strokeOffset; dx <= strokeOffset; dx += strokeOffset) {
    for (CGFloat dy = -strokeOffset; dy <= strokeOffset; dy += strokeOffset) {
      if (dx == 0 && dy == 0)
        continue;
      [strokeSymbol drawInRect:NSOffsetRect(drawRect, dx, dy)
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0];
    }
  }

  // Fill symbol centered on top
  [fillSymbol drawInRect:drawRect
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0];

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
  _cachedIconName = [_iconName copy];
}

- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
            destinationImage:(FxImageTile *)destinationImage {
  if (_iconName.length == 0)
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
      buildAndRegisterPipelineStateForPluginID:kIconButtonPipelineID
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:@"com.keyframeless.KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLabelFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!ps)
    return;

  float halfW = _size.width / 2.0f;
  float halfH = _size.height / 2.0f;

  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];

  id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:registryID
                                                    pixelFormat:pixelFormat];
  if (!queue)
    return;

  id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
  cmdBuf.label = @"KKIconButtonOSC Command Buffer";
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
  [encoder setFragmentTexture:_texture atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

  [encoder endEncoding];
  [cmdBuf commit];
  [cmdBuf waitUntilScheduled];
  [cache returnCommandQueueToCache:queue];
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         center:(CGPoint)center {
  double dx = positionX - center.x;
  double dy = positionY - center.y;
  return sqrt(dx * dx + dy * dy) < kHitRadius;
}

@end
