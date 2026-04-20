/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKToolbar.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>

static NSString *const kToolbarPipelineID =
    @"co.overpolish.keyframelesskit.Toolbar";

static const CGFloat kIconSize = 28.0;
static const CGFloat kButtonSize = 48.0;
static const CGFloat kButtonHeight = 64.0;
static const CGFloat kButtonSpacing = 8.0;
static const CGFloat kToolbarPadding = 14.0;
static const CGFloat kToolbarMargin = 8.0;
static const CGFloat kScale = 2.0;
static const CGFloat kCornerRadius = 12.0;
static const CGFloat kHighlightCorner = 8.0;

@implementation KKToolbarItem

+ (instancetype)itemWithIcon:(NSString *)sfSymbolName
                         tag:(NSInteger)tag
               shortcutLabel:(NSString *)shortcutLabel {
  KKToolbarItem *item = [[KKToolbarItem alloc] init];
  item.iconName = sfSymbolName;
  item.tag = tag;
  item.shortcutLabel = shortcutLabel;
  return item;
}

@end

static const CGFloat kLabelFontSize = 15.0;
static const CGFloat kLabelHeight = 16.0;
static const CGFloat kIconShiftY = 8.0;

@implementation KKToolbar {
  id<PROAPIAccessing> __weak _apiManager;
  NSArray<KKToolbarItem *> *_items;
  NSMutableArray *_iconTextures;
  NSMutableArray<NSString *> *_cachedNames;
  NSMutableArray *_labelTextures;
  NSMutableArray<NSValue *> *_buttonCenters;
  NSMutableArray<NSValue *> *_buttonRects;
  id<MTLTexture> _bgTexture;
  id<MTLTexture> _highlightTexture;
  CGFloat _cachedToolbarW;
  CGFloat _cachedToolbarH;
}

@synthesize toolbarFrame = _toolbarFrame;
@synthesize items = _items;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                             items:(NSArray<KKToolbarItem *> *)items {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _items = [items copy];
    _activeTag = items.firstObject.tag;
    _iconTextures = [NSMutableArray arrayWithCapacity:items.count];
    _cachedNames = [NSMutableArray arrayWithCapacity:items.count];
    _labelTextures = [NSMutableArray arrayWithCapacity:items.count];
    _bottomMargin = kToolbarMargin;
    _rightMargin = -1;
    _buttonCenters = [NSMutableArray arrayWithCapacity:items.count];
    _buttonRects = [NSMutableArray arrayWithCapacity:items.count];
    for (NSUInteger i = 0; i < items.count; i++) {
      [_iconTextures addObject:[NSNull null]];
      [_cachedNames addObject:@""];
      [_labelTextures addObject:[NSNull null]];
      [_buttonCenters addObject:[NSValue valueWithPoint:NSZeroPoint]];
      [_buttonRects addObject:[NSValue valueWithRect:NSZeroRect]];
    }
  }
  return self;
}

static id<MTLTexture> renderRoundedRect(id<MTLDevice> device, CGFloat w,
                                        CGFloat h, CGFloat r, NSColor *color) {
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

- (id<MTLTexture>)textureForIcon:(NSString *)name
                          device:(id<MTLDevice>)device
                           index:(NSUInteger)idx {
  if (idx < _iconTextures.count && _iconTextures[idx] != (id)[NSNull null] &&
      [_cachedNames[idx] isEqualToString:name])
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

- (id<MTLTexture>)textureForLabel:(NSString *)label
                           device:(id<MTLDevice>)device
                            index:(NSUInteger)idx {
  if (!label.length)
    return nil;

  NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
  para.alignment = NSTextAlignmentCenter;
  para.maximumLineHeight = kLabelFontSize;
  para.lineSpacing = 0;
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:kLabelFontSize
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : [NSColor colorWithWhite:0.5 alpha:1.0],
    NSParagraphStyleAttributeName : para,
  };
  NSSize textSize = [label sizeWithAttributes:attrs];
  CGFloat canvasW = ceil(textSize.width + 4.0);
  CGFloat canvasH = ceil(MAX(textSize.height, kLabelHeight));
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

  BOOL multiline = [label containsString:@"\n"];
  CGFloat textY = multiline ? -3.0 : (canvasH - textSize.height) / 2.0;
  NSRect drawRect = NSMakeRect(0, textY, canvasW, textSize.height);
  [label drawInRect:drawRect withAttributes:attrs];

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
  _labelTextures[idx] = texture;
  return texture;
}

static void drawTexturedQuad(id<MTLRenderCommandEncoder> encoder,
                             id<MTLTexture> texture, CGPoint metalCenter,
                             float halfW, float halfH,
                             simd_uint2 viewportSize) {
  float l = metalCenter.x - halfW;
  float r = metalCenter.x + halfW;
  float b = metalCenter.y - halfH;
  float t = metalCenter.y + halfH;

  KKVertex2D verts[6] = {
      {{l, b}, {0, 0}}, {{r, b}, {1, 0}}, {{r, t}, {1, 1}},
      {{l, b}, {0, 0}}, {{r, t}, {1, 1}}, {{l, t}, {0, 1}},
  };
  [encoder setVertexBytes:verts
                   length:sizeof(verts)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setFragmentTexture:texture atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

- (void)drawWithDestinationImage:(FxImageTile *)destinationImage {
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

  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];

  NSInteger itemCount = (NSInteger)_items.count;
  CGFloat totalButtonsW = 0;
  for (NSInteger i = 0; i < itemCount; i++) {
    CGFloat iw =
        _items[i].customWidth > 0 ? _items[i].customWidth : kButtonSize;
    totalButtonsW += iw;
  }
  totalButtonsW += (itemCount - 1) * kButtonSpacing;
  CGFloat toolbarW = totalButtonsW + kToolbarPadding * 2;
  CGFloat toolbarH = kButtonHeight + kToolbarPadding * 2;
  CGFloat toolbarX =
      (_rightMargin >= 0) ? (ioW - _rightMargin - toolbarW / 2.0) : (ioW / 2.0);
  CGFloat toolbarY = ioH - _bottomMargin - toolbarH / 2.0;

  _toolbarFrame = NSMakeRect(toolbarX - toolbarW / 2.0,
                             toolbarY - toolbarH / 2.0, toolbarW, toolbarH);

  CGFloat curX = toolbarX - totalButtonsW / 2.0;
  for (NSInteger i = 0; i < itemCount; i++) {
    CGFloat iw =
        _items[i].customWidth > 0 ? _items[i].customWidth : kButtonSize;
    CGFloat ih =
        _items[i].customHeight > 0 ? _items[i].customHeight : kButtonHeight;
    CGFloat bx = curX + iw / 2.0;
    CGFloat by = toolbarY + _items[i].iconYOffset;
    _buttonCenters[i] = [NSValue valueWithPoint:NSMakePoint(bx, by)];
    _buttonRects[i] = [NSValue
        valueWithRect:NSMakeRect(bx - iw / 2.0, by - ih / 2.0, iw, ih)];
    curX += iw + kButtonSpacing;
  }

  id<MTLCommandQueue> queue = [cache commandQueueWithRegistryID:registryID
                                                    pixelFormat:pixelFormat];
  if (!queue)
    return;

  id<MTLTexture> outTex = [destinationImage metalTextureForDevice:device];

  id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
  cmdBuf.label = @"KKToolbar Command Buffer";
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

  // Cache rounded rect textures
  if (!_bgTexture || _cachedToolbarW != toolbarW ||
      _cachedToolbarH != toolbarH) {
    _bgTexture = renderRoundedRect(device, toolbarW, toolbarH, kCornerRadius,
                                   [NSColor colorWithRed:0.08
                                                   green:0.08
                                                    blue:0.08
                                                   alpha:0.92]);
    _highlightTexture =
        renderRoundedRect(device, kButtonSize, kButtonHeight, kHighlightCorner,
                          [NSColor colorWithRed:0.28
                                          green:0.28
                                           blue:0.28
                                          alpha:0.95]);
    _cachedToolbarW = toolbarW;
    _cachedToolbarH = toolbarH;
  }

  // Background
  CGPoint bgMetal = {toolbarX - ioW / 2.0f, ioH / 2.0f - toolbarY};
  drawTexturedQuad(encoder, _bgTexture, bgMetal, toolbarW / 2.0f,
                   toolbarH / 2.0f, viewportSize);

  // Highlight behind active items
  for (NSInteger i = 0; i < itemCount; i++) {
    if (_items[i].tag == _activeTag ||
        (_secondaryActiveTag != 0 && _items[i].tag == _secondaryActiveTag) ||
        (_tertiaryActiveTag != 0 && _items[i].tag == _tertiaryActiveTag)) {
      CGFloat iw =
          _items[i].customWidth > 0 ? _items[i].customWidth : kButtonSize;
      CGFloat ih =
          _items[i].customHeight > 0 ? _items[i].customHeight : kButtonHeight;
      CGPoint center = _buttonCenters[i].pointValue;
      CGPoint hlMetal = {center.x - ioW / 2.0f, ioH / 2.0f - center.y};
      drawTexturedQuad(encoder, _highlightTexture, hlMetal, iw / 2.0f,
                       ih / 2.0f, viewportSize);
    }
  }

  // Icons (shifted up to make room for labels)
  for (NSUInteger i = 0; i < (NSUInteger)itemCount; i++) {
    id<MTLTexture> iconTex = [self textureForIcon:_items[i].iconName
                                           device:device
                                            index:i];
    if (!iconTex)
      continue;

    CGFloat iw =
        _items[i].customWidth > 0 ? _items[i].customWidth : kButtonSize;
    CGFloat ih =
        _items[i].customHeight > 0 ? _items[i].customHeight : kButtonSize;
    CGPoint center = _buttonCenters[i].pointValue;
    BOOL hasLabel = _items[i].shortcutLabel.length > 0;
    CGFloat iconY = hasLabel ? center.y + kIconShiftY : center.y;
    CGPoint metalPos = {center.x - ioW / 2.0f, ioH / 2.0f - iconY};
    drawTexturedQuad(encoder, iconTex, metalPos, iw / 2.0f, ih / 2.0f,
                     viewportSize);
  }

  // Shortcut labels inside buttons, below icons
  for (NSUInteger i = 0; i < (NSUInteger)itemCount; i++) {
    NSString *label = _items[i].shortcutLabel;
    if (!label.length)
      continue;
    id<MTLTexture> labelTex = [self textureForLabel:label
                                             device:device
                                              index:i];
    if (!labelTex)
      continue;

    CGPoint center = _buttonCenters[i].pointValue;
    CGFloat labelY = center.y - kButtonHeight / 2.0 + kLabelHeight / 2.0 + 2.0;
    CGPoint metalPos = {center.x - ioW / 2.0f, ioH / 2.0f - labelY};
    float halfW = labelTex.width / (2.0f * kScale);
    float halfH = labelTex.height / (2.0f * kScale);
    drawTexturedQuad(encoder, labelTex, metalPos, halfW, halfH, viewportSize);
  }

  [encoder endEncoding];
  [cmdBuf commit];
  [cmdBuf waitUntilScheduled];
  [cache returnCommandQueueToCache:queue];
}

- (NSRect)buttonRectAtIndex:(NSUInteger)index {
  if (index >= _buttonRects.count)
    return NSZeroRect;
  return _buttonRects[index].rectValue;
}

- (NSInteger)hitTestAtX:(double)x y:(double)y {
  for (NSUInteger i = 0; i < _items.count; i++) {
    NSRect rect = _buttonRects[i].rectValue;
    if (CGRectContainsPoint(rect, CGPointMake(x, y)))
      return _items[i].tag;
  }
  // Background of toolbar: swallow click but don't select anything
  if (CGRectContainsPoint(_toolbarFrame, CGPointMake(x, y)))
    return -1;
  return 0;
}

@end
