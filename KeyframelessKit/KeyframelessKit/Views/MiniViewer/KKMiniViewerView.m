/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerView.h"

#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView_Private.h"
#import "KKOSCShaderTypes.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <IOSurface/IOSurface.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <simd/simd.h>

static const NSTimeInterval kPollInterval = 1.0 / 15.0;

@implementation KKMiniBox
+ (instancetype)boxWithRect:(CGRect)rect
              handleCenters:(NSArray<NSValue *> *)handleCenters
                    readout:(NSString *)readout
                 ghostAlpha:(CGFloat)ghostAlpha {
  KKMiniBox *b = [[KKMiniBox alloc] init];
  b.rect = rect;
  b.handleCenters = handleCenters ?: @[];
  b.readout = readout;
  b.ghostAlpha = ghostAlpha;
  return b;
}
@end

@implementation _KKMiniFilmSlot
- (void)dealloc {
  if (_surface)
    CFRelease(_surface);
}
@end

@implementation KKMiniViewerView

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

  _overlay = [[_KKMiniViewerOverlay alloc] initWithFrame:self.bounds];
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
  [self _teardownKeyMonitors];
  if (_sourceSurface)
    CFRelease(_sourceSurface);
}

- (void)_teardownKeyMonitors {
  if (_keyMon) {
    [NSEvent removeMonitor:_keyMon];
    _keyMon = nil;
  }
  if (_keyGlobalMon) {
    [NSEvent removeMonitor:_keyGlobalMon];
    _keyGlobalMon = nil;
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [_pollTimer invalidate];
  _pollTimer = nil;
  [self _teardownKeyMonitors];
  if (self.window) {
    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:kPollInterval
                                                  target:self
                                                selector:@selector(_poll)
                                                userInfo:nil
                                                 repeats:YES];
    [self _poll];
    [self _installKeyMonitor];
  }
}

// Cmd-0 snaps zoom/pan back to fit, matching double-click and the inspector's
// Reset Zoom button. Inside FCP's ViewBridge XPC, a command key-equivalent
// (Cmd-0) NEVER crosses into the plugin process: the host resolves key
// equivalents via performKeyEquivalent:/menu in its own process, and (verified)
// does not forward performKeyEquivalent: across the ViewBridge boundary, nor
// does the event reach a local keyDown monitor. The only thing that sees it is
// an observe-only GLOBAL monitor (same routing as the scroll/magnify quirk -
// see [[project_viewbridge_global_sendEvent]] /
// [[project_viewbridge_cmdkey_global]]). That means we can fire the reset but
// cannot SWALLOW the event - FCP still sees the Cmd-0 (harmless: it has no
// default Cmd-0 binding). The local monitor is kept for real-window contexts
// (e.g. a popped-out inspector NSWindow) where the event does arrive locally
// and `return nil` consumes it. Gate on the window being the visible key window
// so a stale/hidden instance or a Cmd-0 with focus elsewhere doesn't reset;
// skip while a value field (NSText) is editing.
- (BOOL)_handleResetKeyEvent:(NSEvent *)e {
  if (!self.window.isVisible || !self.window.isKeyWindow)
    return NO;
  NSEventModifierFlags m =
      e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  BOOL cmdOnly = (m & NSEventModifierFlagCommand) &&
                 !(m & (NSEventModifierFlagShift | NSEventModifierFlagOption |
                        NSEventModifierFlagControl));
  if (!cmdOnly || ![e.charactersIgnoringModifiers isEqualToString:@"0"])
    return NO;
  if ([self.window.firstResponder isKindOfClass:[NSText class]])
    return NO;
  [self resetView];
  return YES;
}

- (void)_installKeyMonitor {
  __weak typeof(self) weak = self;
  _keyMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(self) s = weak;
                                     return [s _handleResetKeyEvent:e] ? nil
                                                                       : e;
                                   }];
  _keyGlobalMon =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                             handler:^(NSEvent *e) {
                                               __strong typeof(self) s = weak;
                                               [s _handleResetKeyEvent:e];
                                             }];
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
      KKLogWarn(@"KKMiniViewerView: IOSurfaceLookup(%u) failed", sid);
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
      KKLogWarn(@"KKMiniViewerView: wrap IOSurface %u as texture failed", sid);
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
  id<KKMiniViewerDelegate> del = self.canvasDelegate;
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
  // Collapsed tied-hold slots represent a *range* [tag[i], tag[i+1]) rather
  // than a single point: opening the popover on the second KP of a linked
  // pair gives a `want` past tag[i] but still within the hold. Closest-by-
  // distance would jump to slot i+1 when want is past the midpoint; range-
  // containment correctly stays on the hold slot.
  const double kEps = 1e-6;
  for (NSInteger i = (NSInteger)_filmstripSlots.count - 1; i >= 0; i--) {
    if (_filmstripSlots[i].tag <= want + kEps)
      return (NSUInteger)i;
  }
  return 0;
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

static const NSUInteger kFilmstripGridCols = 5;

// Filmstrip layout: cells are packed in a 5-column grid centred on the
// active slot. The active cell always sits at the viewport centre (with
// pan offset) and is sized like `_contentRectInDrawable` - so default
// zoom shows the active frame full-size and OSC handles register against
// it just like the non-filmstrip case. Other cells fan out left/right
// and wrap to additional rows DOWNWARD (row 0 = active row, row 1 = one
// row below on screen, etc).
- (CGRect)_filmstripCellRectInDrawable:(NSUInteger)i ofTotal:(NSUInteger)n {
  CGRect active = [self _contentRectInDrawable];
  if (n <= 1)
    return active;
  // Onion mode: every slot draws into the ACTIVE cell rect (stacked).
  if (_renderMode == 2)
    return active;
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  CGFloat gap = kFilmstripGap * s;
  CGFloat cellW = active.size.width;
  CGFloat cellH = active.size.height;
  CGFloat strideX = cellW + gap;
  CGFloat strideY = cellH + gap;
  NSUInteger nCols = MIN((NSUInteger)kFilmstripGridCols, n);
  NSUInteger activeIdx = [self _activeSlotIndex];
  NSInteger colI = (NSInteger)(i % nCols);
  NSInteger rowI = (NSInteger)(i / nCols);
  NSInteger colA = (NSInteger)(activeIdx % nCols);
  NSInteger rowA = (NSInteger)(activeIdx / nCols);
  CGFloat activeCenterX = d.width / 2.0 + _panPixels.x;
  CGFloat activeCenterY = d.height / 2.0 + _panPixels.y;
  // Drawable Y is up - increasing `rowI` means a row visually BELOW the
  // active row, so subtract from centre y to move down on screen.
  CGFloat cellCenterX = activeCenterX + (CGFloat)(colI - colA) * strideX;
  CGFloat cellCenterY = activeCenterY - (CGFloat)(rowI - rowA) * strideY;
  return CGRectMake(cellCenterX - cellW / 2.0, cellCenterY - cellH / 2.0, cellW,
                    cellH);
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

@end
