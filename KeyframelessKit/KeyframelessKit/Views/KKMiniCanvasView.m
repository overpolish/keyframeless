/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasView.h"

#import "../OSC/Base/KKOSCShaderTypes.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKMiniCanvasRenderer.h"
#import <IOSurface/IOSurface.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <simd/simd.h>

// Outer radius (points) of the shared KKPointOSC handle glyph. Smaller than
// the viewer OSC's oscSize - the mini canvas is a compact preview. Must stay
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
  // just below its bottom edge - same placement as the in-viewer crop OSC.
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

// One filmstrip slot: a resolved IOSurface from the feed's `slots[]` array,
// wrapped as the source texture and a per-slot persistent processed texture.
// Slot 0 is the single-slot fast path; the multi-slot ivars below alias it.
@interface _KKMiniFilmSlot : NSObject
@property(nonatomic) uint32_t sid;
@property(nonatomic) uint64_t generation;
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic, strong) id<MTLTexture> sourceTexture;
@property(nonatomic, strong) id<MTLTexture> processedTexture;
@property(nonatomic) double tag; // the slot's clip fraction
@end

@implementation _KKMiniFilmSlot
- (void)dealloc {
  if (_surface)
    CFRelease(_surface);
}
@end

@implementation KKMiniCanvasView {
  id<MTLRenderPipelineState> _pipeline;
  id<MTLRenderPipelineState> _onionPipeline;
  id<MTLCommandQueue> _queue;
  // Slot 0 aliases - keep the existing names so the handle/border/OSC code
  // paths (which always target the editable slot) don't need to change.
  // The aliases point at `_filmstripSlots.firstObject`'s textures/surface.
  id<MTLTexture> _sourceTexture;
  id<MTLTexture> _processedTexture;
  IOSurfaceRef _sourceSurface;
  uint32_t _resolvedSurfaceID;
  uint64_t _resolvedGeneration;
  // Multi-slot bookkeeping. Always has at least 1 entry (slot 0); onion-skin
  // grows it to N when the descriptor's `slots[]` is published with N>1.
  NSMutableArray<_KKMiniFilmSlot *> *_filmstripSlots;
  NSTimer *_pollTimer;
  id<MTLRenderPipelineState> _pointPipeline;
  id<MTLRenderPipelineState> _arcPipeline;
  id<MTLRenderPipelineState> _linePipeline;
  _KKMiniCanvasOverlay *_overlay;

  CGFloat _zoom;           // 1 == aspect-fit
  CGPoint _panPixels;      // drawable-space pan offset
  CGSize _sourceMediaSize; // original media px (from descriptor srcW/H)
}

- (CGSize)sourceMediaSize {
  return _sourceMediaSize;
}

- (void)setRenderMode:(NSInteger)mode {
  if (_renderMode == mode)
    return;
  _renderMode = mode;
  [self setNeedsDisplay:YES];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  self = [super initWithFrame:frameRect device:device];
  if (!self)
    return nil;

  _clipAspect = 16.0 / 9.0;
  _zoom = kKKMiniInitialZoom;
  _panPixels = CGPointZero;
  _filmstripSlots = [NSMutableArray array];
  [_filmstripSlots addObject:[[_KKMiniFilmSlot alloc] init]];

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

  // Onion-skin: tint+alpha texture pass, premultiplied alpha blending so
  // overlaid ghost frames composite over the active opaque base.
  MTLRenderPipelineDescriptor *op = [[MTLRenderPipelineDescriptor alloc] init];
  op.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  op.fragmentFunction = [lib newFunctionWithName:@"KKTextureTintFragment"];
  op.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  op.colorAttachments[0].blendingEnabled = YES;
  op.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  op.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  op.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
  op.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  op.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  op.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _onionPipeline = [device newRenderPipelineStateWithDescriptor:op error:&err];
  if (!_onionPipeline)
    KKLogError(@"KKMiniCanvasView: onion pipeline failed: %@", err);

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

  // Arc glyph pipeline - opt-in via the renderer's pointHandleStyle. Same
  // blend mode as the point pipeline, different fragment.
  MTLRenderPipelineDescriptor *ap = [[MTLRenderPipelineDescriptor alloc] init];
  ap.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  ap.fragmentFunction = [lib newFunctionWithName:@"KKArcOSCFragment"];
  ap.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  ap.colorAttachments[0].blendingEnabled = YES;
  ap.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  ap.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  ap.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  ap.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  ap.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  ap.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _arcPipeline = [device newRenderPipelineStateWithDescriptor:ap error:&err];
  if (!_arcPipeline)
    KKLogError(@"KKMiniCanvasView: arc pipeline failed: %@", err);

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

- (BOOL)_resolveSlot:(_KKMiniFilmSlot *)slot
                 sid:(uint32_t)sid
                 gen:(uint64_t)gen
                 tag:(double)tag {
  if (sid == 0)
    return NO;
  if (sid == slot.sid && gen == slot.generation && slot.sourceTexture) {
    slot.tag = tag; // tag may change even when surface/gen are stable
    return YES;
  }

  if (sid != slot.sid || !slot.sourceTexture) {
    IOSurfaceRef surf = IOSurfaceLookup((IOSurfaceID)sid);
    if (!surf) {
      KKLogWarn(@"KKMiniCanvasView: IOSurfaceLookup(%u) failed", sid);
      return NO;
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
      return NO;
    }
    if (slot.surface)
      CFRelease(slot.surface);
    slot.surface = surf;
    slot.sourceTexture = tex;
    slot.processedTexture = nil; // size changed - rebuilt lazily in draw
  }
  slot.sid = sid;
  slot.generation = gen;
  slot.tag = tag;
  return YES;
}

// Active slot = the cell the OSC handles + content rect target. With one
// slot, always 0. With many, it's the slot whose tag is closest to the
// renderer's editFraction (= the KP whose popover the user opened).
- (NSUInteger)_activeSlotIndex {
  if (_filmstripSlots.count <= 1)
    return 0;
  id<KKMiniCanvasDelegate> del = self.canvasDelegate;
  NSNumber *editFrac = nil;
  if (del) {
    @try {
      editFrac = [(NSObject *)del valueForKey:@"editFraction"];
    } @catch (...) {
    }
  }
  if (!editFrac)
    return 0;
  double want = editFrac.doubleValue;
  NSUInteger best = 0;
  double bestDt = INFINITY;
  for (NSUInteger i = 0; i < _filmstripSlots.count; i++) {
    double dt = fabs(_filmstripSlots[i].tag - want);
    if (dt < bestDt) {
      bestDt = dt;
      best = i;
    }
  }
  return best;
}

// Aliases follow the ACTIVE slot - that's the one OSC code paths edit /
// inspect. With N=1, active is slot 0 and behavior matches single-slot mode.
- (void)_syncSlot0Aliases {
  NSUInteger active = [self _activeSlotIndex];
  if (active >= _filmstripSlots.count)
    return;
  _KKMiniFilmSlot *s = _filmstripSlots[active];
  _sourceTexture = s.sourceTexture;
  _processedTexture = s.processedTexture;
  _sourceSurface = s.surface;
  _resolvedSurfaceID = s.sid;
  _resolvedGeneration = s.generation;
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

  // Walk the multi-slot array if present; fall back to the top-level
  // single-slot keys (descriptor format pre-onion-skin).
  NSArray *slotEntries = desc[@"slots"];
  if (![slotEntries isKindOfClass:NSArray.class] || slotEntries.count == 0) {
    NSDictionary *one = @{
      @"ioSurfaceID" : desc[@"ioSurfaceID"] ?: @0,
      @"generation" : desc[@"generation"] ?: @0,
      @"tag" : @0,
    };
    slotEntries = @[ one ];
  }

  NSUInteger n = slotEntries.count;
  while (_filmstripSlots.count < n)
    [_filmstripSlots addObject:[[_KKMiniFilmSlot alloc] init]];
  while (_filmstripSlots.count > n)
    [_filmstripSlots removeLastObject];

  BOOL anyChange = NO;
  for (NSUInteger i = 0; i < n; i++) {
    NSDictionary *e = slotEntries[i];
    uint32_t sid = (uint32_t)[e[@"ioSurfaceID"] unsignedIntValue];
    uint64_t gen = (uint64_t)[e[@"generation"] unsignedLongLongValue];
    double tag = [e[@"tag"] doubleValue];
    _KKMiniFilmSlot *slot = _filmstripSlots[i];
    if (sid != slot.sid || gen != slot.generation || tag != slot.tag) {
      if ([self _resolveSlot:slot sid:sid gen:gen tag:tag])
        anyChange = YES;
    }
  }

  // Clip aspect tracks slot 0.
  _KKMiniFilmSlot *s0 = _filmstripSlots.firstObject;
  if (s0.surface) {
    NSUInteger w = IOSurfaceGetWidth(s0.surface);
    NSUInteger h = IOSurfaceGetHeight(s0.surface);
    if (h > 0)
      _clipAspect = (CGFloat)w / (CGFloat)h;
  }
  [self _syncSlot0Aliases];
  if (anyChange)
    [self setNeedsDisplay:YES];
}

// Slot 0's content rect - the editable cell when onion-skin is on, and the
// single rectangle when it's off. Layout for the filmstrip is then computed
// as N cells of this width laid horizontally, with `kFilmstripGap` between
// (drawable space).
static const CGFloat kFilmstripGap = 16.0;

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

// Filmstrip layout: the ACTIVE slot's cell sits at the viewport centre (so
// pan=0 frames it like the single-slot case + all OSC handle code reads
// `_contentRectInDrawable` and naturally targets the active cell). Other
// cells fan out left/right of active, kFilmstripGap apart.
- (CGRect)_filmstripCellRectInDrawable:(NSUInteger)i ofTotal:(NSUInteger)n {
  CGRect r = [self _contentRectInDrawable];
  if (n <= 1)
    return r;
  // Onion mode: every slot draws into the ACTIVE cell rect (stacked).
  if (_renderMode == 2)
    return r;
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  CGFloat gap = kFilmstripGap * s;
  CGFloat cellW = r.size.width;
  CGFloat stride = cellW + gap;
  NSUInteger active = [self _activeSlotIndex];
  CGFloat activeCenterX = d.width / 2.0 + _panPixels.x;
  CGFloat cellCenterX = activeCenterX + ((CGFloat)i - (CGFloat)active) * stride;
  return CGRectMake(cellCenterX - cellW / 2.0, r.origin.y, cellW,
                    r.size.height);
}

- (void)_ensureProcessedTextureForSlot:(_KKMiniFilmSlot *)slot {
  if (!slot.sourceTexture)
    return;
  if (slot.processedTexture &&
      slot.processedTexture.width == slot.sourceTexture.width &&
      slot.processedTexture.height == slot.sourceTexture.height)
    return;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:slot.sourceTexture.width
                                  height:slot.sourceTexture.height
                               mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  td.storageMode = MTLStorageModePrivate;
  slot.processedTexture = [self.device newTextureWithDescriptor:td];
}

- (void)_ensureProcessedTexture {
  _KKMiniFilmSlot *s0 = _filmstripSlots.firstObject;
  [self _ensureProcessedTextureForSlot:s0];
  _processedTexture = s0.processedTexture;
}

// Encodes one shared KKArcOSC glyph centered at `centerPts`. Used by
// renderers that opt into `KKMiniHandleStyleArc` so the mini-canvas handle
// matches the viewer-side ring. Matches KKArcOSC's defaults at a smaller
// mini-canvas scale: 0xC1 gray fill, ring ratio 13/23 (inner = 0.43),
// outline width derived from KKBorderWidthXS. When `isActive` is YES the
// outer radius grows (mirroring KKArcOSC's 23→31 expansion) and a small
// "plus" indicator is drawn in the centre.
- (void)_encodeArcHandleGlyphAt:(CGPoint)centerPts
                       isActive:(BOOL)isActive
                        encoder:(id<MTLRenderCommandEncoder>)enc {
  if (!_arcPipeline)
    return;
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  CGPoint centered = CGPointMake(centerPts.x * s - d.width / 2.0,
                                 centerPts.y * s - d.height / 2.0);
  // Base outer radius in canvas points; active state expands it (matches the
  // viewer KKArcOSC 23→31 hit-grow). Stroke is held constant across states
  // (viewer KKArcOSC keeps strokeWidth=10 fixed while radius grows); the
  // inner ratio is derived so the visible ring stays the same thickness.
  CGFloat outerPt = isActive ? 12.0 : 9.0;
  CGFloat strokePt =
      4.5; // proportional to viewer: 3.5pt @ 270pt → 2.5pt @ 195pt
  float sizePx = (float)(outerPt * s);
  KKVertex2D quad[6];
  [KKRenderPrimitives generateQuadVertices:quad center:centered size:sizePx];
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  float innerRatio = (float)((outerPt - strokePt) / outerPt);
  float outline = (float)(KKBorderWidthXS / outerPt);
  // Crosshair (+ inside the ring on active). Viewer ratios at 270pt height:
  // arm length 6.5pt (~0.024), arm width 0.5pt (~0.0019). Mini @195.5pt
  // → ~4.7pt long, ~0.37pt wide. Normalized to outerPt = 12.
  float plusHalf = isActive ? (2.25f / 12.0f) : 0.0f; // phl + pow = ~2.35pt
  float plusFill = isActive ? (0.15f / 12.0f) : 0.0f; // pfhw + pow = ~0.25pt
  float plusOutl = isActive ? (0.1f / 12.0f) : 0.0f;
  KKArcOSCParams params = {
      .innerRadius = innerRatio,
      .outlineWidth = outline,
      .plusHalfLen = plusHalf,
      .plusFillHalfWidth = plusFill,
      .plusOutlineWidth = plusOutl,
      // 0xC1 gray fill, matching KKArcOSC's `arcFillColor`.
      .fillColor = {193.0f / 255.0f, 193.0f / 255.0f, 193.0f / 255.0f, 1.0f},
      .strokeColor = {0.0f, 0.0f, 0.0f, 0.8f},
  };
  [enc setRenderPipelineState:_arcPipeline];
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

  // Per-slot effect pass - the plugin's renderer reads its `editFraction`
  // property to pick which keypose's params to apply, so we mutate it
  // around each slot's process call. KVC because the view only knows the
  // canvasDelegate via its protocol (the renderer's concrete class lives in
  // the same KK module, so this stays cheap).
  id<KKMiniCanvasDelegate> del = self.canvasDelegate;
  NSUInteger n = _filmstripSlots.count;
  BOOL canProcess =
      (del && [del respondsToSelector:@selector(miniCanvas:processSourceTexture:
                                                intoTexture:commandBuffer:)]);
  NSNumber *savedFrac =
      canProcess && n > 1
          ? [(NSObject *)del valueForKey:@"editFraction"] // nil if absent
          : nil;
  if (canProcess) {
    for (NSUInteger i = 0; i < n; i++) {
      _KKMiniFilmSlot *slot = _filmstripSlots[i];
      if (!slot.sourceTexture)
        continue;
      [self _ensureProcessedTextureForSlot:slot];
      if (!slot.processedTexture)
        continue;
      if (n > 1) {
        @try {
          [(NSObject *)del setValue:@(slot.tag) forKey:@"editFraction"];
        } @catch (...) {
        }
      }
      [del miniCanvas:self
          processSourceTexture:slot.sourceTexture
                   intoTexture:slot.processedTexture
                 commandBuffer:cb];
    }
    if (savedFrac) {
      @try {
        [(NSObject *)del setValue:savedFrac forKey:@"editFraction"];
      } @catch (...) {
      }
    }
  }
  // Slot 0 alias kept fresh for the OSC / handle / border code paths.
  _processedTexture = _filmstripSlots.firstObject.processedTexture;

  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];

  if (_pipeline) {
    CGSize d = self.drawableSize;
    simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
    BOOL onion = (_renderMode == 2 && n > 1);
    NSUInteger activeIdx = onion ? [self _activeSlotIndex] : 0;

    // Helper: emit one textured quad for slot `i` at its cell rect, using
    // the currently-bound pipeline (texture / tint / alpha bound by caller).
    void (^drawSlotQuad)(NSUInteger, id<MTLTexture>) =
        ^(NSUInteger i, id<MTLTexture> tex) {
          CGRect r = [self _filmstripCellRectInDrawable:i ofTotal:n];
          float cx = (float)(CGRectGetMidX(r) - d.width / 2.0);
          float cy = (float)(CGRectGetMidY(r) - d.height / 2.0);
          float hw = (float)(r.size.width / 2.0);
          float hh = (float)(r.size.height / 2.0);
          KKVertex2D verts[4] = {
              {{cx - hw, cy + hh}, {0, 1}},
              {{cx - hw, cy - hh}, {0, 0}},
              {{cx + hw, cy + hh}, {1, 1}},
              {{cx + hw, cy - hh}, {1, 0}},
          };
          [enc setVertexBytes:verts
                       length:sizeof(verts)
                      atIndex:KKVertexInputIndex_Vertices];
          [enc setFragmentTexture:tex atIndex:KKTextureIndex_InputImage];
          [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                  vertexStart:0
                  vertexCount:4];
        };

    [enc setRenderPipelineState:_pipeline];
    [enc setVertexBytes:&vp
                 length:sizeof(vp)
                atIndex:KKVertexInputIndex_ViewportSize];

    if (_renderMode == 0) {
      // Off: only the active slot, even if the descriptor still has the
      // old multi-slot list - avoids a fan-out flash on a Filmstrip→Off
      // pill flip before the descriptor poll resyncs to a single slot.
      NSUInteger ai = (n > 1) ? [self _activeSlotIndex] : 0;
      _KKMiniFilmSlot *slot = _filmstripSlots[ai];
      id<MTLTexture> tex = slot.processedTexture ?: slot.sourceTexture;
      if (tex)
        drawSlotQuad(ai, tex);
    } else if (!onion) {
      // Filmstrip: passthrough for every slot, each in its own cell.
      for (NSUInteger i = 0; i < n; i++) {
        _KKMiniFilmSlot *slot = _filmstripSlots[i];
        id<MTLTexture> tex = slot.processedTexture ?: slot.sourceTexture;
        if (!tex)
          continue;
        drawSlotQuad(i, tex);
      }
    } else if (_onionPipeline) {
      // Onion: active frame opaque first, then prev (red) / next (blue)
      // ghosts on top with a low alpha so the active still reads through.
      // (Drawing active LAST would fully cover the ghosts - they paint
      // every pixel, not just outlines, so they'd be invisible.)
      _KKMiniFilmSlot *aSlot = _filmstripSlots[activeIdx];
      id<MTLTexture> aTex = aSlot.processedTexture ?: aSlot.sourceTexture;
      if (aTex)
        drawSlotQuad(activeIdx, aTex);

      [enc setRenderPipelineState:_onionPipeline];
      [enc setVertexBytes:&vp
                   length:sizeof(vp)
                  atIndex:KKVertexInputIndex_ViewportSize];
      for (NSInteger side = -1; side <= 1; side += 2) {
        NSInteger idx = (NSInteger)activeIdx + side;
        if (idx < 0 || idx >= (NSInteger)n)
          continue;
        _KKMiniFilmSlot *slot = _filmstripSlots[idx];
        id<MTLTexture> tex = slot.processedTexture ?: slot.sourceTexture;
        if (!tex)
          continue;
        simd_float4 tintRGBA = (side < 0)
                                   ? (simd_float4){1.0f, 0.2f, 0.2f, 0.7f}
                                   : (simd_float4){0.2f, 0.4f, 1.0f, 0.7f};
        float outAlpha = 0.35f;
        [enc setFragmentBytes:&tintRGBA length:sizeof(tintRGBA) atIndex:0];
        [enc setFragmentBytes:&outAlpha length:sizeof(outAlpha) atIndex:1];
        drawSlotQuad((NSUInteger)idx, tex);
      }
    }
  }

  // Crop border - drawn here (before the glyphs) so the handles sit on
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
        [del miniCanvas:self
            pointHandleCenter:&handleCenterPts
                  contentRect:cr]) {
      KKMiniHandleStyle style = KKMiniHandleStylePoint;
      BOOL isActive = NO;
      if ([del isKindOfClass:[KKMiniCanvasRenderer class]]) {
        style = [(KKMiniCanvasRenderer *)del pointHandleStyle];
        isActive = [(KKMiniCanvasRenderer *)del pointHandleIsActive];
      }
      if (style == KKMiniHandleStyleArc)
        [self _encodeArcHandleGlyphAt:handleCenterPts
                             isActive:isActive
                              encoder:enc];
      else
        [self _encodeHandleGlyphAt:handleCenterPts
                         fillColor:accentFill
                           encoder:enc];
    }

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

  // Content rect may have shifted (pan/zoom/resolve) - keep handles aligned.
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
  if (event.clickCount == 2) {
    [self resetView];
    return;
  }
  // Filmstrip: a click in an INACTIVE cell asks the host to swap the popover
  // to that KP. Single-slot mode (or click in the active cell) falls through.
  // Onion stacks every cell on the active rect - there's no spatial way to
  // pick a specific KP, so we suppress here and let the header's prev/next
  // buttons drive navigation instead.
  NSUInteger n = _filmstripSlots.count;
  if (n > 1 && self.onFilmstripCellActivated && _renderMode != 2) {
    NSPoint vp = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat s = self.window.backingScaleFactor;
    if (s <= 0)
      s = 2.0;
    NSUInteger active = [self _activeSlotIndex];
    for (NSUInteger i = 0; i < n; i++) {
      if (i == active)
        continue;
      CGRect cellDrawable = [self _filmstripCellRectInDrawable:i ofTotal:n];
      // Convert drawable px → view points so it lines up with `vp` (which is
      // in view points). The MTKView itself isn't flipped, so the Y origin
      // already matches; we just rescale.
      CGRect cell =
          CGRectMake(cellDrawable.origin.x / s, cellDrawable.origin.y / s,
                     cellDrawable.size.width / s, cellDrawable.size.height / s);
      if (CGRectContainsPoint(cell, vp)) {
        // Reset pan so the newly-activated cell lands centred - otherwise
        // the existing pan stays applied to the new layout and the strip
        // visually jumps even further off-centre.
        _panPixels = CGPointZero;
        self.onFilmstripCellActivated(_filmstripSlots[i].tag);
        return;
      }
    }
  }
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
