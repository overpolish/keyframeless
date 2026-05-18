/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasView.h"

#import "../OSC/Base/KKOSCShaderTypes.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import <IOSurface/IOSurface.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <simd/simd.h>

// Outer radius (points) of the shared KKPointOSC handle glyph. Smaller than
// the viewer OSC's oscSize — the mini canvas is a compact preview. Must stay
// in sync with RoundedMiniCanvasRenderer's MiniOscSize() (placement/hit).
static const CGFloat kKKMiniHandleOuterPt = 4.5;

// Initial / double-click-reset zoom. Slightly < 1 (aspect-fit) so there's a
// margin around the image and the corner handles are clear of the view edge
// (and the rounded-corner mask) and easy to grab from the start.
static const CGFloat kKKMiniInitialZoom = 0.85;

// KKPointOSCFragment's bevel is lighter where texcoord.y is negative. Our
// drawable's NDC handedness vs. the viewer OSC can't be derived analytically
// (the image's UV flip masks it), so this is an explicit knob: YES = lighter
// at the top of the dot (the requested look). Flip if it ever inverts.
static const BOOL kPointShadingLighterTop = YES;

static const NSTimeInterval kPollInterval = 1.0 / 15.0;

@interface KKMiniCanvasView () <MTKViewDelegate>
- (CGRect)contentRectInViewPoints;
- (CGSize)sourceMediaSize;
@end

/// Transparent AppKit layer over the Metal content. Draws plugin handles and
/// owns handle hit-testing/dragging; passes non-handle clicks through to the
/// canvas (so pan/zoom/double-click-reset still work).
@interface _KKMiniCanvasOverlay : NSView
@property(nonatomic, weak) KKMiniCanvasView *canvas;
@end

@implementation _KKMiniCanvasOverlay {
  BOOL _dragging;
}

- (BOOL)isFlipped {
  return NO;
}

- (NSView *)hitTest:(NSPoint)pt {
  KKMiniCanvasView *c = self.canvas;
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  if (![d respondsToSelector:@selector(
                                 miniCanvas:handleHitAtPoint:contentRect:)])
    return nil;
  NSPoint p = [self convertPoint:pt fromView:self.superview];
  return [d miniCanvas:c
             handleHitAtPoint:p
                  contentRect:[c contentRectInViewPoints]]
             ? self
             : nil;
}

// Handles are drawn by the canvas's Metal pass (shared KKPointOSC shader).
// The crop border is a thin stroke and is cheaper/sharper drawn here in
// Core Graphics than via a Metal line pipeline.
- (void)drawRect:(NSRect)dirtyRect {
  KKMiniCanvasView *c = self.canvas;
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  if (![d respondsToSelector:@selector(miniCanvas:borderRect:forContentRect:)])
    return;
  CGRect cr = [c contentRectInViewPoints];
  CGRect br;
  if (![d miniCanvas:c borderRect:&br forContentRect:cr])
    return;
  // The border line itself is drawn in the Metal pass (under the handle
  // glyphs); this overlay only adds the size readout on top.

  // Size readout in pixels: trailing edge aligned to the crop's right edge,
  // just below its bottom edge — same placement as the in-viewer crop OSC.
  // The crop fraction is border/content; × the source media size.
  CGSize media = [c sourceMediaSize];
  if (media.width <= 0 || media.height <= 0 || cr.size.width <= 0 ||
      cr.size.height <= 0)
    return;
  long pxW = lround(br.size.width / cr.size.width * media.width);
  long pxH = lround(br.size.height / cr.size.height * media.height);
  NSString *txt = [NSString stringWithFormat:@"%ld x %ld", pxW, pxH];
  NSDictionary *attrs = @{
    NSFontAttributeName :
        [NSFont monospacedDigitSystemFontOfSize:9.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : [NSColor colorWithWhite:1.0 alpha:0.9],
  };
  NSSize ts = [txt sizeWithAttributes:attrs];
  // Trailing edge aligned to the crop's right edge; y-up overlay so "below
  // the bottom edge" == smaller y.
  NSPoint at = NSMakePoint(CGRectGetMaxX(br) - ts.width,
                           CGRectGetMinY(br) - ts.height - 4.0);
  [txt drawAtPoint:at withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)e {
  KKMiniCanvasView *c = self.canvas;
  // A double-click is always "reset view", even when it lands on the crop
  // box / a handle (the overlay's hitTest swallows those clicks, so the
  // canvas's own -mouseDown: never sees them otherwise).
  if (e.clickCount == 2) {
    [self.window makeFirstResponder:nil];
    [c resetView];
    return;
  }
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  if (![d respondsToSelector:
              @selector(miniCanvas:beginHandleDragAtPoint:contentRect:)])
    return;
  // Interacting with the canvas commits/ends any focused value field so its
  // stale text can't clobber the drag's value on focus loss.
  [self.window makeFirstResponder:nil];
  _dragging = YES;
  if (c.onHandleDragBegin)
    c.onHandleDragBegin();
  [d miniCanvas:c
      beginHandleDragAtPoint:[self convertPoint:e.locationInWindow fromView:nil]
                 contentRect:[c contentRectInViewPoints]];
}

- (void)mouseDragged:(NSEvent *)e {
  if (!_dragging)
    return;
  KKMiniCanvasView *c = self.canvas;
  [c.canvasDelegate miniCanvas:c
             dragHandleToPoint:[self convertPoint:e.locationInWindow
                                         fromView:nil]
                   contentRect:[c contentRectInViewPoints]];
}

- (void)mouseUp:(NSEvent *)e {
  if (!_dragging)
    return;
  _dragging = NO;
  KKMiniCanvasView *c = self.canvas;
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  if ([d respondsToSelector:@selector(miniCanvasEndHandleDrag:)])
    [d miniCanvasEndHandleDrag:c];
  if (c.onHandleDragEnd)
    c.onHandleDragEnd();
}

@end

@implementation KKMiniCanvasView {
  id<MTLRenderPipelineState> _pipeline;
  id<MTLCommandQueue> _queue;
  id<MTLTexture> _sourceTexture;
  id<MTLTexture> _processedTexture;
  IOSurfaceRef _sourceSurface;
  uint32_t _resolvedSurfaceID;
  uint64_t _resolvedGeneration;
  NSTimer *_pollTimer;
  id<MTLRenderPipelineState> _pointPipeline;
  id<MTLRenderPipelineState> _linePipeline;
  _KKMiniCanvasOverlay *_overlay;

  CGFloat _zoom;           // 1 == aspect-fit
  CGPoint _panPixels;      // drawable-space pan offset
  CGSize _sourceMediaSize; // original media px (from descriptor srcW/H)
}

- (CGSize)sourceMediaSize {
  return _sourceMediaSize;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  self = [super initWithFrame:frameRect device:device];
  if (!self)
    return nil;

  _clipAspect = 16.0 / 9.0;
  _zoom = kKKMiniInitialZoom;
  _panPixels = CGPointZero;

  self.delegate = self;
  self.paused = YES;
  self.enableSetNeedsDisplay = YES;
  self.framebufferOnly = YES;
  self.clearColor = MTLClearColorMake(0.12, 0.12, 0.13, 1.0);
  self.layer.opaque = YES;

  [self _buildPipeline];

  _queue = [device newCommandQueue];

  _overlay = [[_KKMiniCanvasOverlay alloc] initWithFrame:self.bounds];
  _overlay.canvas = self;
  _overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:_overlay];

  return self;
}

- (CGRect)contentRectInViewPoints {
  CGRect r = [self _contentRectInDrawable];
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  return CGRectMake(r.origin.x / s, r.origin.y / s, r.size.width / s,
                    r.size.height / s);
}

- (void)setHandlesNeedDisplay {
  [_overlay setNeedsDisplay:YES];
}

- (void)reportHandleValueForLabel:(NSString *)laneLabel
                           values:(NSArray<NSNumber *> *)values {
  if (self.onHandleValue)
    self.onHandleValue(laneLabel, values);
}

- (void)dealloc {
  [_pollTimer invalidate];
  if (_sourceSurface)
    CFRelease(_sourceSurface);
}

- (void)_buildPipeline {
  id<MTLDevice> device = self.device;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib) {
    KKLogError(@"KKMiniCanvasView: no default metal library: %@", err);
    return;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  pd.fragmentFunction =
      [lib newFunctionWithName:@"KKTexturePassthroughFragment"];
  pd.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  _pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!_pipeline)
    KKLogError(@"KKMiniCanvasView: pipeline build failed: %@", err);

  // Shared KKPointOSC glyph, alpha-blended over the composited image.
  MTLRenderPipelineDescriptor *pp = [[MTLRenderPipelineDescriptor alloc] init];
  pp.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  pp.fragmentFunction = [lib newFunctionWithName:@"KKPointOSCFragment"];
  pp.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  pp.colorAttachments[0].blendingEnabled = YES;
  pp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  pp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  pp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  pp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  pp.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  pp.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _pointPipeline = [device newRenderPipelineStateWithDescriptor:pp error:&err];
  if (!_pointPipeline)
    KKLogError(@"KKMiniCanvasView: point pipeline failed: %@", err);

  // Flat-color pipeline for the crop border, drawn before the glyphs so the
  // handles sit on top of the line.
  MTLRenderPipelineDescriptor *lp = [[MTLRenderPipelineDescriptor alloc] init];
  lp.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  lp.fragmentFunction = [lib newFunctionWithName:@"KKSolidColorFragment"];
  lp.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  lp.colorAttachments[0].blendingEnabled = YES;
  lp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  lp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  lp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  lp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  lp.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  lp.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _linePipeline = [device newRenderPipelineStateWithDescriptor:lp error:&err];
  if (!_linePipeline)
    KKLogError(@"KKMiniCanvasView: line pipeline failed: %@", err);
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [_pollTimer invalidate];
  _pollTimer = nil;
  if (self.window) {
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:kPollInterval
                                                  target:self
                                                selector:@selector(_poll)
                                                userInfo:nil
                                                 repeats:YES];
    [self _poll];
  }
}

- (void)_poll {
  NSString *path = self.sourceDescriptorPath;
  if (path.length == 0)
    return;
  NSData *data = [NSData dataWithContentsOfFile:path];
  if (!data)
    return;
  NSDictionary *desc = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:nil];
  if (![desc isKindOfClass:NSDictionary.class])
    return;

  CGSize prevMedia = _sourceMediaSize;
  _sourceMediaSize = CGSizeMake([desc[@"srcWidth"] doubleValue],
                                [desc[@"srcHeight"] doubleValue]);
  if (!CGSizeEqualToSize(prevMedia, _sourceMediaSize) &&
      _sourceMediaSize.width > 0 && self.onSourceResolved)
    self.onSourceResolved();
  uint32_t sid = (uint32_t)[desc[@"ioSurfaceID"] unsignedIntValue];
  uint64_t gen = (uint64_t)[desc[@"generation"] unsignedLongLongValue];
  if (sid == 0)
    return;
  if (sid == _resolvedSurfaceID && gen == _resolvedGeneration && _sourceTexture)
    return;

  if (sid != _resolvedSurfaceID || !_sourceTexture) {
    IOSurfaceRef surf = IOSurfaceLookup((IOSurfaceID)sid);
    if (!surf) {
      KKLogWarn(@"KKMiniCanvasView: IOSurfaceLookup(%u) failed", sid);
      return;
    }
    NSUInteger w = IOSurfaceGetWidth(surf);
    NSUInteger h = IOSurfaceGetHeight(surf);
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [self.device newTextureWithDescriptor:td
                                                     iosurface:surf
                                                         plane:0];
    if (!tex) {
      KKLogWarn(@"KKMiniCanvasView: wrap IOSurface %u as texture failed", sid);
      CFRelease(surf);
      return;
    }
    if (_sourceSurface)
      CFRelease(_sourceSurface);
    _sourceSurface = surf;
    _sourceTexture = tex;
    _processedTexture = nil; // size changed — rebuilt lazily in draw
    if (h > 0)
      _clipAspect = (CGFloat)w / (CGFloat)h;
  }
  _resolvedSurfaceID = sid;
  _resolvedGeneration = gen;
  [self setNeedsDisplay:YES];
}

- (CGRect)_contentRectInDrawable {
  CGSize d = self.drawableSize;
  if (d.width <= 0 || d.height <= 0)
    return CGRectZero;
  CGFloat viewAspect = d.width / d.height;
  CGFloat a = _clipAspect > 0 ? _clipAspect : (16.0 / 9.0);
  CGFloat w, h;
  if (a >= viewAspect) {
    w = d.width;
    h = d.width / a;
  } else {
    h = d.height;
    w = d.height * a;
  }
  w *= _zoom;
  h *= _zoom;
  CGFloat cx = d.width / 2.0 + _panPixels.x;
  CGFloat cy = d.height / 2.0 + _panPixels.y;
  return CGRectMake(cx - w / 2.0, cy - h / 2.0, w, h);
}

- (void)_ensureProcessedTexture {
  if (!_sourceTexture)
    return;
  if (_processedTexture && _processedTexture.width == _sourceTexture.width &&
      _processedTexture.height == _sourceTexture.height)
    return;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:_sourceTexture.width
                                  height:_sourceTexture.height
                               mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  td.storageMode = MTLStorageModePrivate;
  _processedTexture = [self.device newTextureWithDescriptor:td];
}

// Encodes one shared KKPointOSC glyph centered at `centerPts` (overlay
// points, y-up). `enc` must already be a valid render encoder for this pass.
- (void)_encodeHandleGlyphAt:(CGPoint)centerPts
                   fillColor:(simd_float4)fillColor
                     encoder:(id<MTLRenderCommandEncoder>)enc {
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  CGPoint centered = CGPointMake(centerPts.x * s - d.width / 2.0,
                                 centerPts.y * s - d.height / 2.0);
  float sizePx = (float)(kKKMiniHandleOuterPt * s);
  KKVertex2D quad[6];
  [KKRenderPrimitives generateQuadVertices:quad center:centered size:sizePx];
  // generateQuadVertices puts tc.y=+1 on the higher-position (screen-top)
  // vertices; KKPointOSCFragment is lighter at tc.y<0. Negating tc.y →
  // lighter at the top of the dot. Gated by the explicit knob.
  if (kPointShadingLighterTop)
    for (int i = 0; i < 6; i++)
      quad[i].textureCoordinate.y = -quad[i].textureCoordinate.y;
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  KKPointOSCParams params = {
      .outlineWidth = (float)(KKBorderWidthXS / kKKMiniHandleOuterPt),
      .fillColor = fillColor,
      .strokeColor = {0.0f, 0.0f, 0.0f, 0.75f},
  };
  [enc setRenderPipelineState:_pointPipeline];
  [enc setVertexBytes:quad
               length:sizeof(quad)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setFragmentBytes:&params
                 length:sizeof(params)
                atIndex:KKOSCFragmentIndex_DrawColor];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

- (void)drawInMTKView:(MTKView *)view {
  id<CAMetalDrawable> drawable = self.currentDrawable;
  MTLRenderPassDescriptor *rpd = self.currentRenderPassDescriptor;
  if (!drawable || !rpd)
    return;

  id<MTLCommandBuffer> cb = [_queue commandBuffer];

  // Let the plugin run its effect into an offscreen at source size first;
  // fall back to the raw source if no delegate handles it.
  id<MTLTexture> displayTex = _sourceTexture;
  id<KKMiniCanvasDelegate> del = self.canvasDelegate;
  if (_sourceTexture && del &&
      [del respondsToSelector:@selector(miniCanvas:processSourceTexture:
                                        intoTexture:commandBuffer:)]) {
    [self _ensureProcessedTexture];
    if (_processedTexture && [del miniCanvas:self
                                 processSourceTexture:_sourceTexture
                                          intoTexture:_processedTexture
                                        commandBuffer:cb])
      displayTex = _processedTexture;
  }

  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];

  if (displayTex && _pipeline) {
    CGRect r = [self _contentRectInDrawable];
    CGSize d = self.drawableSize;
    float cx = (float)(CGRectGetMidX(r) - d.width / 2.0);
    float cy = (float)(CGRectGetMidY(r) - d.height / 2.0);
    float hw = (float)(r.size.width / 2.0);
    float hh = (float)(r.size.height / 2.0);

    // Source arrives vertically flipped relative to view space (FCP Y-down
    // image origin + the MPS blit), so V is flipped; U stays normal.
    KKVertex2D verts[4] = {
        {{cx - hw, cy + hh}, {0, 1}}, // top-left
        {{cx - hw, cy - hh}, {0, 0}}, // bottom-left
        {{cx + hw, cy + hh}, {1, 1}}, // top-right
        {{cx + hw, cy - hh}, {1, 0}}, // bottom-right
    };
    simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};

    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:verts
                 length:sizeof(verts)
                atIndex:KKVertexInputIndex_Vertices];
    [enc setVertexBytes:&vp
                 length:sizeof(vp)
                atIndex:KKVertexInputIndex_ViewportSize];
    [enc setFragmentTexture:displayTex atIndex:KKTextureIndex_InputImage];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:4];
  }

  // Crop border — drawn here (before the glyphs) so the handles sit on
  // top of the line, not under it.
  if (_linePipeline && del &&
      [del respondsToSelector:@selector(
                                  miniCanvas:borderRect:forContentRect:)]) {
    CGRect cr = [self contentRectInViewPoints];
    CGRect br;
    if ([del miniCanvas:self borderRect:&br forContentRect:cr]) {
      CGSize d = self.drawableSize;
      CGFloat s = self.window.backingScaleFactor;
      if (s <= 0)
        s = 2.0;
      float L = (float)(CGRectGetMinX(br) * s - d.width / 2.0);
      float R = (float)(CGRectGetMaxX(br) * s - d.width / 2.0);
      float B = (float)(CGRectGetMinY(br) * s - d.height / 2.0);
      float T = (float)(CGRectGetMaxY(br) * s - d.height / 2.0);
      float lw = (float)(1.0 * s);
      simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
      simd_float4 lineColor = {1.0f, 1.0f, 1.0f, 0.9f};
      [enc setRenderPipelineState:_linePipeline];
      [enc setVertexBytes:&vp
                   length:sizeof(vp)
                  atIndex:KKVertexInputIndex_ViewportSize];
      [enc setFragmentBytes:&lineColor length:sizeof(lineColor) atIndex:0];
      // bottom, top, left, right edges as thin filled quads.
      float edges[4][4] = {
          {L, B, R, B + lw},
          {L, T - lw, R, T},
          {L, B, L + lw, T},
          {R - lw, B, R, T},
      };
      for (int e = 0; e < 4; e++) {
        float x0 = edges[e][0], y0 = edges[e][1], x1 = edges[e][2],
              y1 = edges[e][3];
        KKVertex2D q[4] = {
            {{x0, y1}, {0, 0}},
            {{x0, y0}, {0, 0}},
            {{x1, y1}, {0, 0}},
            {{x1, y0}, {0, 0}},
        };
        [enc setVertexBytes:q
                     length:sizeof(q)
                    atIndex:KKVertexInputIndex_Vertices];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
      }
    }
  }

  if (_pointPipeline && del) {
    CGRect cr = [self contentRectInViewPoints];
    // Radius handle uses the host accent (same as Canvas's Rotate OSC) so
    // it's distinguishable from the white crop handles.
    NSColor *a =
        [[NSColor accent] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat ar = 1, ag = 1, ab = 1, aa = 1;
    [a getRed:&ar green:&ag blue:&ab alpha:&aa];
    simd_float4 accentFill = {(float)ar, (float)ag, (float)ab, (float)aa};
    simd_float4 whiteFill = {1.0f, 1.0f, 1.0f, 1.0f};

    CGPoint handleCenterPts;
    if ([del respondsToSelector:
                 @selector(miniCanvas:pointHandleCenter:contentRect:)] &&
        [del miniCanvas:self pointHandleCenter:&handleCenterPts contentRect:cr])
      [self _encodeHandleGlyphAt:handleCenterPts
                       fillColor:accentFill
                         encoder:enc];

    if ([del respondsToSelector:
                 @selector(miniCanvas:extraHandleCentersForContentRect:)]) {
      for (NSValue *v in [del miniCanvas:self
               extraHandleCentersForContentRect:cr])
        [self _encodeHandleGlyphAt:v.pointValue
                         fillColor:whiteFill
                           encoder:enc];
    }
  }

  [enc endEncoding];
  [cb presentDrawable:drawable];
  [cb commit];

  // Content rect may have shifted (pan/zoom/resolve) — keep handles aligned.
  [_overlay setNeedsDisplay:YES];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
  [self setNeedsDisplay:YES];
}

- (CGFloat)_backingScale {
  CGFloat s = self.window.backingScaleFactor;
  return s > 0 ? s : 2.0;
}

// Cursor-anchored zoom: keep the image point under `viewPt` (view points,
// y-up) fixed while scaling to `newZoom`.
- (void)_zoomTo:(CGFloat)newZoom aboutViewPoint:(NSPoint)viewPt {
  newZoom = MAX(0.2, MIN(8.0, newZoom));
  CGFloat s = [self _backingScale];
  CGPoint c = CGPointMake(viewPt.x * s, viewPt.y * s);
  CGRect r0 = [self _contentRectInDrawable];
  if (r0.size.width <= 0 || r0.size.height <= 0 || _zoom <= 0) {
    _zoom = newZoom;
    [self setNeedsDisplay:YES];
    [self _didChangeViewTransform];
    return;
  }
  CGFloat fx = (c.x - r0.origin.x) / r0.size.width;
  CGFloat fy = (c.y - r0.origin.y) / r0.size.height;
  CGFloat k = newZoom / _zoom;
  CGFloat newW = r0.size.width * k, newH = r0.size.height * k;
  CGSize d = self.drawableSize;
  // origin = (d/2 + pan) - newSize/2  ⇒  pan = origin - d/2 + newSize/2
  CGFloat originX = c.x - fx * newW, originY = c.y - fy * newH;
  _panPixels.x = originX - d.width / 2.0 + newW / 2.0;
  _panPixels.y = originY - d.height / 2.0 + newH / 2.0;
  _zoom = newZoom;
  [self setNeedsDisplay:YES];
  [self _didChangeViewTransform];
}

// Exact mechanism copied from the old KKStageSequencerView+InteractionZoomPan
// (which had working pinch/pan): plain responder overrides, scrollWheel:
// forwards to super first for a coherent NSScrollView event stream.
- (void)magnifyWithEvent:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  [self _zoomTo:_zoom * (1.0 + event.magnification) aboutViewPoint:p];
}

- (void)scrollWheel:(NSEvent *)event {
  [super scrollWheel:event];
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  if (event.hasPreciseScrollingDeltas) {
    // Trackpad two-finger → pan.
    CGFloat s = [self _backingScale];
    _panPixels.x += event.scrollingDeltaX * s;
    _panPixels.y -= event.scrollingDeltaY * s; // drawable y is up; delta y-down
    [self setNeedsDisplay:YES];
    [self _didChangeViewTransform];
  } else {
    // Mouse wheel → zoom toward cursor.
    CGFloat factor = 1.0 - event.scrollingDeltaY * 0.05;
    [self _zoomTo:_zoom * factor aboutViewPoint:p];
  }
}

- (void)mouseDown:(NSEvent *)event {
  // End any focused value field (see _KKMiniCanvasOverlay -mouseDown:).
  [self.window makeFirstResponder:nil];
  if (event.clickCount == 2)
    [self resetView];
}

- (void)resetView {
  _zoom = kKKMiniInitialZoom;
  _panPixels = CGPointZero;
  [self setNeedsDisplay:YES];
  if (self.onViewReset)
    self.onViewReset();
}

- (void)_didChangeViewTransform {
  if (self.onViewTransformChanged)
    self.onViewTransformChanged();
}

- (NSPoint)_viewPointForScreenPoint:(NSPoint)screenPoint {
  NSWindow *w = self.window;
  if (!w)
    return NSZeroPoint;
  return [self convertPoint:[w convertPointFromScreen:screenPoint]
                   fromView:nil];
}

- (void)beginPointHandleDragAtScreenPoint:(NSPoint)screenPoint {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:
              @selector(miniCanvas:beginHandleDragAtPoint:contentRect:)])
    return;
  [self.window makeFirstResponder:nil];
  if (self.onHandleDragBegin)
    self.onHandleDragBegin();
  [d miniCanvas:self
      beginHandleDragAtPoint:[self _viewPointForScreenPoint:screenPoint]
                 contentRect:[self contentRectInViewPoints]];
}

- (void)dragPointHandleToScreenPoint:(NSPoint)screenPoint {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:@selector(
                                 miniCanvas:dragHandleToPoint:contentRect:)])
    return;
  [d miniCanvas:self
      dragHandleToPoint:[self _viewPointForScreenPoint:screenPoint]
            contentRect:[self contentRectInViewPoints]];
}

- (void)endPointHandleDrag {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if ([d respondsToSelector:@selector(miniCanvasEndHandleDrag:)])
    [d miniCanvasEndHandleDrag:self];
  if (self.onHandleDragEnd)
    self.onHandleDragEnd();
}

// `ctr` is overlay points, y-up, in the canvas's own coordinate space (the
// overlay fills the canvas bounds 1:1) → glyph rect in screen space.
- (NSRect)_screenRectForHandleCenter:(CGPoint)ctr {
  NSWindow *w = self.window;
  if (!w)
    return NSZeroRect;
  CGFloat r = kKKMiniHandleOuterPt;
  NSRect inView = NSMakeRect(ctr.x - r, ctr.y - r, 2 * r, 2 * r);
  return [w convertRectToScreen:[self convertRect:inView toView:nil]];
}

- (NSRect)pointHandleScreenRect {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:@selector(
                                 miniCanvas:pointHandleCenter:contentRect:)])
    return NSZeroRect;
  CGPoint ctr;
  if (![d miniCanvas:self
          pointHandleCenter:&ctr
                contentRect:[self contentRectInViewPoints]])
    return NSZeroRect;
  return [self _screenRectForHandleCenter:ctr];
}

- (NSRect)pointHandleScreenRectForValue:(double)value {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:
              @selector(miniCanvas:pointHandleCenter:forValue:contentRect:)])
    return NSZeroRect;
  CGPoint ctr;
  if (![d miniCanvas:self
          pointHandleCenter:&ctr
                   forValue:value
                contentRect:[self contentRectInViewPoints]])
    return NSZeroRect;
  return [self _screenRectForHandleCenter:ctr];
}

- (NSRect)_screenRectForHandleCenters:(NSArray<NSValue *> *)centers
                              atIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)centers.count)
    return NSZeroRect;
  return [self _screenRectForHandleCenter:centers[index].pointValue];
}

- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:@selector(
                                 miniCanvas:extraHandleCentersForContentRect:)])
    return NSZeroRect;
  return [self
      _screenRectForHandleCenters:
          [d miniCanvas:self
              extraHandleCentersForContentRect:[self contentRectInViewPoints]]
                          atIndex:index];
}

- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index
                        forCropValues:(NSArray<NSNumber *> *)values {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:
              @selector(miniCanvas:cropHandleCentersForValues:contentRect:)])
    return NSZeroRect;
  return
      [self _screenRectForHandleCenters:
                [d miniCanvas:self
                    cropHandleCentersForValues:values
                                   contentRect:[self contentRectInViewPoints]]
                                atIndex:index];
}

- (void)mouseDragged:(NSEvent *)event {
  CGFloat s = [self _backingScale];
  _panPixels.x += event.deltaX * s;
  _panPixels.y -= event.deltaY * s; // deltaY is y-down
  [self setNeedsDisplay:YES];
  [self _didChangeViewTransform];
}

- (BOOL)_pointFromGlobalEvent:(NSPoint *)outViewPt {
  NSWindow *w = self.window;
  if (!w)
    return NO;
  NSPoint winPt = [w convertPointFromScreen:NSEvent.mouseLocation];
  NSPoint p = [self convertPoint:winPt fromView:nil];
  if (!NSPointInRect(p, self.bounds))
    return NO;
  *outViewPt = p;
  return YES;
}

- (BOOL)pointerOverCanvas {
  NSPoint p;
  return [self _pointFromGlobalEvent:&p];
}

- (BOOL)applyScrollEvent:(NSEvent *)event {
  NSPoint p;
  if (![self _pointFromGlobalEvent:&p])
    return NO;
  if (event.hasPreciseScrollingDeltas) {
    CGFloat s = [self _backingScale];
    _panPixels.x += event.scrollingDeltaX * s;
    _panPixels.y -= event.scrollingDeltaY * s;
    [self setNeedsDisplay:YES];
    [self _didChangeViewTransform];
  } else {
    [self _zoomTo:_zoom * (1.0 - event.scrollingDeltaY * 0.05)
        aboutViewPoint:p];
  }
  return YES;
}

- (BOOL)applyMagnifyEvent:(NSEvent *)event {
  NSPoint p;
  if (![self _pointFromGlobalEvent:&p])
    return NO;
  [self _zoomTo:_zoom * (1.0 + event.magnification) aboutViewPoint:p];
  return YES;
}

@end
