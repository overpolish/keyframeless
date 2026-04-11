/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "CanvasToolbar.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>

static NSString *const kToolbarPipelineID =
    @"co.overpolish.keyframeless.Canvas.Toolbar";

// Layout constants
static const CGFloat kIconSize = 28.0;       // SF Symbol point size
static const CGFloat kButtonSize = 48.0;     // Clickable button area
static const CGFloat kButtonSpacing = 8.0;   // Gap between buttons
static const CGFloat kToolbarPadding = 14.0; // Padding inside pill
static const CGFloat kToolbarMargin = 8.0;   // Margin from top edge
static const CGFloat kScale = 2.0;           // Retina scale
static const CGFloat kCornerRadius = 12.0;   // Background corner radius
static const CGFloat kHighlightCorner = 8.0; // Highlight corner radius

typedef struct {
  NSString *iconName;
  CanvasToolMode mode;
  NSInteger partID;
} ToolbarItem;

@implementation CanvasToolbar {
  id<PROAPIAccessing> __weak _apiManager;
  id<MTLTexture> _iconTextures[2];
  NSString *_cachedNames[2];
  CGPoint _buttonCenters[2];
  CGRect _buttonRects[2];
  NSInteger _itemCount;
  ToolbarItem _items[2];
  id<MTLTexture> _bgTexture;
  id<MTLTexture> _highlightTexture;
  CGFloat _cachedToolbarW;
  CGFloat _cachedToolbarH;
}

- (id<MTLTexture>)roundedRectTextureWithDevice:(id<MTLDevice>)device
                                         width:(CGFloat)w
                                        height:(CGFloat)h
                                        radius:(CGFloat)r
                                         color:(NSColor *)color {
  NSInteger pixelW = (NSInteger)(w * kScale);
  NSInteger pixelH = (NSInteger)(h * kScale);

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, pixelW, pixelH, 8, pixelW * 4, cs,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx)
    return nil;

  CGContextScaleCTM(ctx, kScale, kScale);

  NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx
                                                                  flipped:NO];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:gc];

  NSBezierPath *path =
      [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, w, h)
                                      xRadius:r
                                      yRadius:r];
  [color setFill];
  [path fill];

  [NSGraphicsContext restoreGraphicsState];

  MTLTextureDescriptor *desc = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:pixelW
                                  height:pixelH
                               mipmapped:NO];
  desc.usage = MTLTextureUsageShaderRead;
  id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
  [texture replaceRegion:MTLRegionMake2D(0, 0, pixelW, pixelH)
             mipmapLevel:0
               withBytes:CGBitmapContextGetData(ctx)
             bytesPerRow:pixelW * 4];

  CGContextRelease(ctx);
  return texture;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _activeToolMode = CanvasToolPen;
    _itemCount = 2;
    _items[0] =
        (ToolbarItem){@"pencil.and.outline", CanvasToolPen, kOSCToolbarPen};
    _items[1] = (ToolbarItem){@"rectangle", CanvasToolRect, kOSCToolbarRect};
  }
  return self;
}

- (id<MTLTexture>)textureForIcon:(NSString *)name
                          device:(id<MTLDevice>)device
                           index:(NSInteger)idx {
  if (_iconTextures[idx] && [_cachedNames[idx] isEqualToString:name])
    return _iconTextures[idx];

  NSImage *symbol = [NSImage imageWithSystemSymbolName:name
                              accessibilityDescription:nil];
  if (!symbol)
    return nil;

  NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
      configurationWithPointSize:kIconSize
                          weight:NSFontWeightMedium];
  NSImageSymbolConfiguration *colorCfg = [NSImageSymbolConfiguration
      configurationWithPaletteColors:@[ [NSColor colorWithWhite:0.85
                                                          alpha:1.0] ]];
  NSImage *styled =
      [symbol imageWithSymbolConfiguration:
                  [config configurationByApplyingConfiguration:colorCfg]];

  NSSize imageSize = styled.size;
  NSInteger canvasW = (NSInteger)kButtonSize;
  NSInteger canvasH = (NSInteger)kButtonSize;
  NSInteger pixelW = (NSInteger)(canvasW * kScale);
  NSInteger pixelH = (NSInteger)(canvasH * kScale);

  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(
      NULL, pixelW, pixelH, 8, pixelW * 4, cs,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx)
    return nil;

  CGContextScaleCTM(ctx, kScale, kScale);

  NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx
                                                                  flipped:NO];
  [NSGraphicsContext saveGraphicsState];
  [NSGraphicsContext setCurrentContext:gc];

  CGFloat originX = (canvasW - imageSize.width) / 2.0;
  CGFloat originY = (canvasH - imageSize.height) / 2.0;
  NSRect drawRect =
      NSMakeRect(originX, originY, imageSize.width, imageSize.height);

  [styled drawInRect:drawRect
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
  id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
  [texture replaceRegion:MTLRegionMake2D(0, 0, pixelW, pixelH)
             mipmapLevel:0
               withBytes:CGBitmapContextGetData(ctx)
             bytesPerRow:pixelW * 4];

  CGContextRelease(ctx);
  _iconTextures[idx] = texture;
  _cachedNames[idx] = [name copy];
  return texture;
}

- (void)drawWithWidth:(NSInteger)width
               height:(NSInteger)height
     destinationImage:(FxImageTile *)destinationImage {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  if (!device)
    return;

  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];

  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:kToolbarPipelineID
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

  // Use IOSurface dimensions for consistent layout and rendering
  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];

  // Calculate toolbar layout
  CGFloat totalButtonsW =
      _itemCount * kButtonSize + (_itemCount - 1) * kButtonSpacing;
  CGFloat toolbarW = totalButtonsW + kToolbarPadding * 2;
  CGFloat toolbarH = kButtonSize + kToolbarPadding * 2;
  CGFloat toolbarX = ioW / 2.0;
  // Canvas Y=0 is bottom, top = ioH - offset
  CGFloat toolbarY = ioH - kToolbarMargin - toolbarH / 2.0;

  // Calculate button centers
  CGFloat startX = toolbarX - totalButtonsW / 2.0 + kButtonSize / 2.0;
  for (NSInteger i = 0; i < _itemCount; i++) {
    CGFloat bx = startX + i * (kButtonSize + kButtonSpacing);
    _buttonCenters[i] = CGPointMake(bx, toolbarY);
    _buttonRects[i] =
        CGRectMake(bx - kButtonSize / 2.0, toolbarY - toolbarH / 2.0,
                   kButtonSize, toolbarH);
  }

  id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:registryID
                                                    pixelFormat:pixelFormat];
  if (!queue)
    return;

  id<MTLTexture> outTex = [destinationImage metalTextureForDevice:device];

  id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
  cmdBuf.label = @"CanvasToolbar Command Buffer";
  [cmdBuf enqueue];

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = outTex;
  rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> encoder =
      [cmdBuf renderCommandEncoderWithDescriptor:rpd];

  MTLViewport viewport = {0, 0, ioW, ioH, -1.0, 1.0};
  [encoder setViewport:viewport];
  [encoder setRenderPipelineState:ps];

  simd_uint2 viewportSize = {(unsigned int)ioW, (unsigned int)ioH};
  [encoder setVertexBytes:&viewportSize
                   length:sizeof(viewportSize)
                  atIndex:KKVertexInputIndex_ViewportSize];

  // Create/cache rounded rect textures
  if (!_bgTexture || _cachedToolbarW != toolbarW ||
      _cachedToolbarH != toolbarH) {
    NSColor *bgColor = [NSColor colorWithRed:0.08
                                       green:0.08
                                        blue:0.08
                                       alpha:0.92];
    _bgTexture = [self roundedRectTextureWithDevice:device
                                              width:toolbarW
                                             height:toolbarH
                                             radius:kCornerRadius
                                              color:bgColor];
    NSColor *hlColor = [NSColor colorWithRed:0.28
                                       green:0.28
                                        blue:0.28
                                       alpha:0.95];
    _highlightTexture = [self roundedRectTextureWithDevice:device
                                                     width:kButtonSize
                                                    height:kButtonSize
                                                    radius:kHighlightCorner
                                                     color:hlColor];
    _cachedToolbarW = toolbarW;
    _cachedToolbarH = toolbarH;
  }

  // Draw background
  {
    CGPoint metalCenter = {toolbarX - ioW / 2.0f, ioH / 2.0f - toolbarY};
    float halfW = toolbarW / 2.0f;
    float halfH = toolbarH / 2.0f;
    float l = metalCenter.x - halfW;
    float r = metalCenter.x + halfW;
    float b = metalCenter.y - halfH;
    float t = metalCenter.y + halfH;

    KKVertex2D bgVerts[6] = {
        {{l, b}, {0, 0}}, {{r, b}, {1, 0}}, {{r, t}, {1, 1}},
        {{l, b}, {0, 0}}, {{r, t}, {1, 1}}, {{l, t}, {0, 1}},
    };
    [encoder setVertexBytes:bgVerts
                     length:sizeof(bgVerts)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setFragmentTexture:_bgTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
  }

  // Draw highlight behind active tool
  {
    CGFloat activeX = 0;
    for (NSInteger i = 0; i < _itemCount; i++) {
      if (_items[i].mode == _activeToolMode)
        activeX = _buttonCenters[i].x;
    }
    CGPoint metalCenter = {activeX - ioW / 2.0f, ioH / 2.0f - toolbarY};
    float halfW = kButtonSize / 2.0f;
    float halfH = kButtonSize / 2.0f;
    float l = metalCenter.x - halfW;
    float r = metalCenter.x + halfW;
    float b = metalCenter.y - halfH;
    float t = metalCenter.y + halfH;

    KKVertex2D hlVerts[6] = {
        {{l, b}, {0, 0}}, {{r, b}, {1, 0}}, {{r, t}, {1, 1}},
        {{l, b}, {0, 0}}, {{r, t}, {1, 1}}, {{l, t}, {0, 1}},
    };
    [encoder setVertexBytes:hlVerts
                     length:sizeof(hlVerts)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setFragmentTexture:_highlightTexture atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
  }

  // Draw icon textures
  for (NSInteger i = 0; i < _itemCount; i++) {
    id<MTLTexture> iconTex = [self textureForIcon:_items[i].iconName
                                           device:device
                                            index:i];
    if (!iconTex)
      continue;

    CGPoint metalPos = {_buttonCenters[i].x - ioW / 2.0f,
                        ioH / 2.0f - _buttonCenters[i].y};
    float halfW = kButtonSize / 2.0f;
    float halfH = kButtonSize / 2.0f;
    float l = metalPos.x - halfW;
    float r = metalPos.x + halfW;
    float b = metalPos.y - halfH;
    float t = metalPos.y + halfH;

    KKVertex2D verts[6] = {
        {{l, b}, {0, 0}}, {{r, b}, {1, 0}}, {{r, t}, {1, 1}},
        {{l, b}, {0, 0}}, {{r, t}, {1, 1}}, {{l, t}, {0, 1}},
    };
    [encoder setVertexBytes:verts
                     length:sizeof(verts)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setFragmentTexture:iconTex atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
  }

  [encoder endEncoding];
  [cmdBuf commit];
  [cmdBuf waitUntilScheduled];
  [cache returnCommandQueueToCache:queue];
}

- (NSInteger)hitTestAtX:(double)x y:(double)y {
  for (NSInteger i = 0; i < _itemCount; i++) {
    if (CGRectContainsPoint(_buttonRects[i], CGPointMake(x, y)))
      return _items[i].partID;
  }
  return 0;
}

@end
