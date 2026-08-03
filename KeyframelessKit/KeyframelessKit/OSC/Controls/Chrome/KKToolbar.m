/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKToolbar.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>

static NSString *const kToolbarPipelineID =
    @"com.keyframeless.kit.Toolbar";

static const CGFloat kIconSize = 28.0;
static const CGFloat kButtonSize = 48.0;
static const CGFloat kButtonHeight = 64.0;
static const CGFloat kButtonSpacing = 8.0;
static const CGFloat kToolbarPadding = 14.0;
static const CGFloat kToolbarMargin = 8.0;
static const CGFloat kScale = 2.0;
static const CGFloat kCornerRadius = 12.0;
static const CGFloat kHighlightCorner = 8.0;
static const CGFloat kSeparatorWidth = 13.0; // slot width for a divider
static const CGFloat kSeparatorLineW = 2.0;  // the drawn line thickness

// The toolbar (and tooltip) background fill - kept in one place so the tooltip
// bubble matches the bar exactly.
static NSColor *toolbarBackgroundColor(void) {
  return [NSColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:0.92];
}

static CGFloat itemWidth(KKToolbarItem *item, CGFloat scale) {
  if (item.isSeparator)
    return kSeparatorWidth * scale;
  return (item.customWidth > 0 ? item.customWidth : kButtonSize) * scale;
}

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

+ (instancetype)separator {
  KKToolbarItem *item = [[KKToolbarItem alloc] init];
  item.isSeparator = YES;
  item.iconName = @"";
  return item;
}

@end

static const CGFloat kLabelFontSize = 15.0;
static const CGFloat kLabelHeight = 16.0;
static const CGFloat kIconShiftY = 8.0;
static const CGFloat kTooltipFontSize = 15.0;
static const CGFloat kTooltipPadX = 10.0;   // horizontal text inset
static const CGFloat kTooltipPadY = 6.0;    // vertical text inset
static const CGFloat kTooltipGap = 8.0;     // gap above the toolbar top edge
static const CGFloat kTooltipCorner = 7.0;

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
  id<MTLTexture> _separatorTexture;
  CGFloat _cachedToolbarW;
  CGFloat _cachedToolbarH;
  id<MTLTexture> _tooltipTexture; // cached for the last-rendered tooltip text
  NSString *_tooltipText;
}

@synthesize toolbarFrame = _toolbarFrame;
@synthesize items = _items;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                             items:(NSArray<KKToolbarItem *> *)items {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _items = [items copy];
    _uiScale = 1.0;
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

// A tooltip bubble: light text on a dark rounded background, rendered to one
// texture sized to the text + padding. No width constraint (unlike the inline
// button labels), so localized strings of any length fit.
static id<MTLTexture> renderTooltip(id<MTLDevice> device, NSString *text) {
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:kTooltipFontSize
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : [NSColor colorWithWhite:0.95 alpha:1.0],
  };
  NSSize textSize = [text sizeWithAttributes:attrs];
  CGFloat w = ceil(textSize.width) + kTooltipPadX * 2.0;
  CGFloat h = ceil(textSize.height) + kTooltipPadY * 2.0;
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

  NSBezierPath *bg =
      [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, w, h)
                                      xRadius:kTooltipCorner
                                      yRadius:kTooltipCorner];
  [toolbarBackgroundColor() setFill];
  [bg fill];
  [text drawInRect:NSMakeRect(kTooltipPadX, (h - textSize.height) / 2.0,
                              textSize.width, textSize.height)
      withAttributes:attrs];

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

  KKToolbarItem *item = idx < _items.count ? _items[idx] : nil;
  CGFloat pointSize = item.iconPointSize > 0 ? item.iconPointSize : kIconSize;
  NSColor *tint = item.iconColor ?: [NSColor colorWithWhite:0.85 alpha:1.0];
  NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration
      configurationWithPointSize:pointSize
                          weight:NSFontWeightMedium];
  NSImageSymbolConfiguration *colorCfg =
      [NSImageSymbolConfiguration configurationWithPaletteColors:@[ tint ]];
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

static void drawTexturedQuadFlip(id<MTLRenderCommandEncoder> encoder,
                                 id<MTLTexture> texture, CGPoint metalCenter,
                                 float halfW, float halfH,
                                 simd_uint2 viewportSize, BOOL flipY,
                                 float flipAxisY) {
  (void)flipAxisY;
  // The mini-viewer's Metal pass is fully Y-mirrored vs the FxPlug surface this
  // bar was authored for: glyph content samples upside-down AND the vertical
  // geometry (bar position, icon-over-label layout) inverts. So mirror BOTH -
  // negate the vertical position (mirror about the viewport centre) and swap the
  // V texcoord (keep each glyph upright). (Symmetric OSC glyphs never revealed
  // this; the asymmetric toolbar does.)
  float cy = flipY ? -(float)metalCenter.y : (float)metalCenter.y;
  float l = metalCenter.x - halfW;
  float r = metalCenter.x + halfW;
  float b = cy - halfH;
  float t = cy + halfH;
  float v0 = flipY ? 1.0f : 0.0f, v1 = flipY ? 0.0f : 1.0f;
  KKVertex2D verts[6] = {
      {{l, b}, {0, v0}}, {{r, b}, {1, v0}}, {{r, t}, {1, v1}},
      {{l, b}, {0, v0}}, {{r, t}, {1, v1}}, {{l, t}, {0, v1}},
  };
  [encoder setVertexBytes:verts
                   length:sizeof(verts)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setFragmentTexture:texture atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

// FxPlug surface (the viewer OSC): set up Metal from the destination tile, then
// run the shared content draw. The mini-viewer reuses -drawInEncoder:... below
// to render the SAME toolbar into its own MTKView pass (like the shared OSC
// glyph pipelines), so there's one drawing path for both surfaces.
- (void)setSeparatorColor:(NSColor *)separatorColor {
  _separatorColor = separatorColor;
  _separatorTexture = nil; // force a rebuild on the next draw
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
                                      bundleID:@"com.keyframeless.KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLabelFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!ps)
    return;

  float ioW = [destinationImage.ioSurface width];
  float ioH = [destinationImage.ioSurface height];

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
  [self drawInEncoder:encoder device:device pipeline:ps viewportWidth:ioW height:ioH];
  [encoder endEncoding];
  [cmdBuf commit];
  [cmdBuf waitUntilScheduled];
  [cache returnCommandQueueToCache:queue];
}

// Lays the bar out for a viewport (ioSurface px), filling _toolbarFrame +
// _buttonCenters + _buttonRects (the hit-test reads the latter between draws).
- (void)_layoutForViewportWidth:(float)ioW height:(float)ioH {
  CGFloat sc = _uiScale > 0 ? _uiScale : 1.0;
  NSInteger itemCount = (NSInteger)_items.count;
  CGFloat totalButtonsW = 0;
  for (NSInteger i = 0; i < itemCount; i++)
    totalButtonsW += itemWidth(_items[i], sc);
  totalButtonsW += (itemCount - 1) * kButtonSpacing * sc;
  CGFloat toolbarW = totalButtonsW + kToolbarPadding * 2 * sc;
  CGFloat toolbarH = kButtonHeight * sc + kToolbarPadding * 2 * sc;
  CGFloat toolbarX, toolbarY;
  if (_usesAnchorCenter) {
    // Free position: clamp the centre so the whole frame stays on-screen.
    CGFloat halfW = toolbarW / 2.0, halfH = toolbarH / 2.0;
    toolbarX = fmax(halfW, fmin(ioW - halfW, _anchorCenter.x));
    toolbarY = fmax(halfH, fmin(ioH - halfH, _anchorCenter.y));
  } else {
    toolbarX = (_rightMargin >= 0) ? (ioW - _rightMargin - toolbarW / 2.0)
                                   : (ioW / 2.0);
    toolbarY = ioH - _bottomMargin - toolbarH / 2.0;
  }

  _toolbarFrame = NSMakeRect(toolbarX - toolbarW / 2.0,
                             toolbarY - toolbarH / 2.0, toolbarW, toolbarH);

  CGFloat curX = toolbarX - totalButtonsW / 2.0;
  for (NSInteger i = 0; i < itemCount; i++) {
    CGFloat iw = itemWidth(_items[i], sc);
    CGFloat ih = (_items[i].customHeight > 0 ? _items[i].customHeight
                                             : kButtonHeight) *
                 sc;
    CGFloat bx = curX + iw / 2.0;
    CGFloat by = toolbarY + _items[i].iconYOffset * sc;
    _buttonCenters[i] = [NSValue valueWithPoint:NSMakePoint(bx, by)];
    _buttonRects[i] = [NSValue
        valueWithRect:NSMakeRect(bx - iw / 2.0, by - ih / 2.0, iw, ih)];
    curX += iw + kButtonSpacing * sc;
  }
}

// Shared content draw into a render encoder that's already in a pass. The caller
// supplies a KKVertexShader/KKLabelFragment pipeline matching the target's pixel
// format. Used by both the FxPlug path above and the mini-viewer's Metal pass.
- (void)drawInEncoder:(id<MTLRenderCommandEncoder>)encoder
               device:(id<MTLDevice>)device
             pipeline:(id<MTLRenderPipelineState>)ps
        viewportWidth:(float)ioW
               height:(float)ioH {
  if (!encoder || !device || !ps)
    return;
  MTLViewport viewport = {0, 0, ioW, ioH, -1.0, 1.0};
  [encoder setViewport:viewport];
  [encoder setRenderPipelineState:ps];
  [self _layoutForViewportWidth:ioW height:ioH];

  NSInteger itemCount = (NSInteger)_items.count;
  CGFloat toolbarW = _toolbarFrame.size.width;
  CGFloat toolbarH = _toolbarFrame.size.height;
  CGFloat toolbarX = NSMidX(_toolbarFrame);
  CGFloat toolbarY = NSMidY(_toolbarFrame);

  CGFloat sc = _uiScale > 0 ? _uiScale : 1.0;
  BOOL fl = _flipVertical;
  float flipAxisY = (float)(ioH / 2.0 - toolbarY); // bar centre in metal Y
  simd_uint2 viewportSize = {(unsigned int)ioW, (unsigned int)ioH};
  [encoder setVertexBytes:&viewportSize
                   length:sizeof(viewportSize)
                  atIndex:KKVertexInputIndex_ViewportSize];

  // Cache rounded rect textures (regenerated when the scaled bar size changes,
  // which also covers a uiScale change).
  if (!_bgTexture || _cachedToolbarW != toolbarW ||
      _cachedToolbarH != toolbarH) {
    _bgTexture = renderRoundedRect(device, toolbarW, toolbarH, kCornerRadius * sc,
                                   toolbarBackgroundColor());
    _highlightTexture = renderRoundedRect(
        device, kButtonSize * sc, kButtonHeight * sc, kHighlightCorner * sc,
        [NSColor colorWithRed:0.28 green:0.28 blue:0.28 alpha:0.95]);
    // Same grey as the shortcut labels by default; a custom separatorColor lets
    // a caller match the dividers to its handle/icon tint.
    _separatorTexture = renderRoundedRect(
        device, kSeparatorLineW * sc, kButtonHeight * 0.5 * sc, 0.0,
        _separatorColor ?: [NSColor colorWithWhite:0.5 alpha:1.0]);
    _cachedToolbarW = toolbarW;
    _cachedToolbarH = toolbarH;
  }

  // Background
  CGPoint bgMetal = {toolbarX - ioW / 2.0f, ioH / 2.0f - toolbarY};
  drawTexturedQuadFlip(encoder, _bgTexture, bgMetal, toolbarW / 2.0f,
                       toolbarH / 2.0f, viewportSize, fl, flipAxisY);

  // Divider lines (ON TOP of the background - the bg is semi-transparent, so
  // drawing these under it would wash them out).
  for (NSInteger i = 0; i < itemCount; i++) {
    if (!_items[i].isSeparator || !_separatorTexture)
      continue;
    CGPoint center = _buttonCenters[i].pointValue;
    CGPoint sMetal = {center.x - ioW / 2.0f, ioH / 2.0f - center.y};
    drawTexturedQuadFlip(encoder, _separatorTexture, sMetal,
                         kSeparatorLineW * sc / 2.0f, kButtonHeight * 0.25f * sc,
                         viewportSize, fl, flipAxisY);
  }

  // Highlight behind active items
  for (NSInteger i = 0; i < itemCount; i++) {
    if (_items[i].isSeparator)
      continue;
    if (_items[i].tag == _activeTag ||
        (_secondaryActiveTag != 0 && _items[i].tag == _secondaryActiveTag) ||
        (_tertiaryActiveTag != 0 && _items[i].tag == _tertiaryActiveTag) ||
        (_activeTags && [_activeTags containsObject:@(_items[i].tag)])) {
      CGFloat iw =
          (_items[i].customWidth > 0 ? _items[i].customWidth : kButtonSize) * sc;
      CGFloat ih =
          (_items[i].customHeight > 0 ? _items[i].customHeight : kButtonHeight) *
          sc;
      CGPoint center = _buttonCenters[i].pointValue;
      CGPoint hlMetal = {center.x - ioW / 2.0f, ioH / 2.0f - center.y};
      drawTexturedQuadFlip(encoder, _highlightTexture, hlMetal, iw / 2.0f,
                           ih / 2.0f, viewportSize, fl, flipAxisY);
    }
  }

  // Icons (shifted up to make room for labels)
  for (NSUInteger i = 0; i < (NSUInteger)itemCount; i++) {
    if (_items[i].isSeparator)
      continue;
    id<MTLTexture> iconTex = [self textureForIcon:_items[i].iconName
                                           device:device
                                            index:i];
    if (!iconTex)
      continue;

    CGFloat iw =
        (_items[i].customWidth > 0 ? _items[i].customWidth : kButtonSize) * sc;
    CGFloat ih =
        (_items[i].customHeight > 0 ? _items[i].customHeight : kButtonSize) * sc;
    CGPoint center = _buttonCenters[i].pointValue;
    BOOL hasLabel = _items[i].shortcutLabel.length > 0;
    CGFloat iconY = hasLabel ? center.y + kIconShiftY * sc : center.y;
    CGPoint metalPos = {center.x - ioW / 2.0f, ioH / 2.0f - iconY};
    drawTexturedQuadFlip(encoder, iconTex, metalPos, iw / 2.0f, ih / 2.0f,
                         viewportSize, fl, flipAxisY);
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
    CGFloat labelY =
        center.y - kButtonHeight * sc / 2.0 + kLabelHeight * sc / 2.0 + 2.0 * sc;
    CGPoint metalPos = {center.x - ioW / 2.0f, ioH / 2.0f - labelY};
    float halfW = labelTex.width / (2.0f * kScale) * sc;
    float halfH = labelTex.height / (2.0f * kScale) * sc;
    drawTexturedQuadFlip(encoder, labelTex, metalPos, halfW, halfH, viewportSize,
                         fl, flipAxisY);
  }

  // Hover tooltip: a localized bubble centred above the hovered button (clamped
  // horizontally to stay on-screen). Drawn last so it sits over everything.
  if (_hoveredTag != 0) {
    for (NSInteger i = 0; i < itemCount; i++) {
      if (_items[i].isSeparator || _items[i].tag != _hoveredTag ||
          !_items[i].tooltip.length)
        continue;
      if (![_tooltipText isEqualToString:_items[i].tooltip] || !_tooltipTexture) {
        _tooltipTexture = renderTooltip(device, _items[i].tooltip);
        _tooltipText = [_items[i].tooltip copy];
      }
      if (!_tooltipTexture)
        break;
      float halfW = _tooltipTexture.width / (2.0f * kScale);
      float halfH = _tooltipTexture.height / (2.0f * kScale);
      CGPoint center = _buttonCenters[i].pointValue;
      CGFloat tipX = fmax(halfW, fmin(ioW - halfW, center.x)); // on-screen X
      // Prefer above the bar; flip below if it would clip the top edge, and
      // clamp so it stays fully on-screen either way (ioSurface coords, Y-down).
      CGFloat barTop = _toolbarFrame.origin.y;
      CGFloat barBottom = _toolbarFrame.origin.y + _toolbarFrame.size.height;
      CGFloat tipY = barTop - kTooltipGap - halfH;
      if (tipY - halfH < 0.0)
        tipY = barBottom + kTooltipGap + halfH;
      tipY = fmax(halfH, fmin(ioH - halfH, tipY));
      CGPoint metalPos = {tipX - ioW / 2.0f, ioH / 2.0f - tipY};
      drawTexturedQuadFlip(encoder, _tooltipTexture, metalPos, halfW, halfH,
                           viewportSize, fl, flipAxisY);
      break;
    }
  }
}

- (NSRect)buttonRectAtIndex:(NSUInteger)index {
  if (index >= _buttonRects.count)
    return NSZeroRect;
  return _buttonRects[index].rectValue;
}

- (NSInteger)hitTestAtX:(double)x y:(double)y {
  for (NSUInteger i = 0; i < _items.count; i++) {
    if (_items[i].isSeparator)
      continue;
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
