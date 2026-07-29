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
// During live playback the feed streams new source frames up to 60fps; the idle
// 15fps poll would stutter the footage, so poll near the feed's rate while it
// plays and drop back to idle when it stops.
static const NSTimeInterval kPollIntervalLive = 1.0 / 60.0;

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

@implementation KKMiniRotation
+ (instancetype)rotationWithCenter:(CGPoint)center
                          radiusPx:(CGFloat)radiusPx
                            params:(KKRotationOSCParams)params {
  KKMiniRotation *r = [[KKMiniRotation alloc] init];
  r.center = center;
  r.radiusPx = radiusPx;
  r.params = params;
  return r;
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

- (id<MTLTexture>)channel1Texture {
  return _channel1Slot.sourceTexture;
}

- (void)setRenderMode:(NSInteger)mode {
  if (_renderMode == mode)
    return;
  _renderMode = mode;
  // A generator drives its own slot count from keypose fractions (no feed), so
  // the filmstrip/onion fan-out must be (re)built the instant the pill flips
  // rather than waiting for the next descriptor poll.
  if ([self _isGeneratorDelegate])
    [self _rebuildGeneratorSlots];
  [self setNeedsDisplay:YES];
}

- (BOOL)_isGeneratorDelegate {
  // A generator is any delegate that implements -generateIntoTexture:. Do NOT
  // also require !processSourceTexture: - the base KKMiniViewerRenderer
  // provides processSourceTexture: as a passthrough default, so EVERY renderer
  // responds to it; only a real source-less generator (Mirage) implements
  // generateIntoTexture: (the base does not).
  id<KKMiniViewerDelegate> del = self.canvasDelegate;
  return del &&
         [del respondsToSelector:
                  @selector(miniViewer:generateIntoTexture:commandBuffer:)];
}

- (BOOL)_rebuildGeneratorSlots {
  if (![self _isGeneratorDelegate])
    return NO;
  id<KKMiniViewerDelegate> del = self.canvasDelegate;
  NSArray<NSNumber *> *fracs = nil;
  if (_renderMode != 0 &&
      [del respondsToSelector:@selector(miniViewerKeyposeFractions:)])
    fracs = [del miniViewerKeyposeFractions:self];
  if (fracs.count == 0)
    fracs = @[ @0.0 ]; // Off, or a constant-only timeline: a single cell
  NSUInteger n = fracs.count;
  BOOL changed = (_filmstripSlots.count != n);
  while (_filmstripSlots.count < n)
    [_filmstripSlots addObject:[[_KKMiniFilmSlot alloc] init]];
  while (_filmstripSlots.count > n)
    [_filmstripSlots removeLastObject];
  for (NSUInteger i = 0; i < n; i++) {
    _KKMiniFilmSlot *s = _filmstripSlots[i];
    double tag = fracs[i].doubleValue;
    if (fabs(s.tag - tag) > 1e-9)
      changed = YES;
    s.tag = tag;
    // Surfaceless: the generate path fills processedTexture per slot. Clear any
    // stale source so a slot never wanders down the effect path.
    if (s.surface) {
      CFRelease(s.surface);
      s.surface = NULL;
    }
    s.sourceTexture = nil;
    s.sid = 0;
    s.generation = 0;
  }
  [self _syncSlot0Aliases];
  return changed;
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

- (CGFloat)oscSizingHeight {
  return _oscReferenceHeight > 0 ? _oscReferenceHeight
                                 : self.bounds.size.height;
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

// Only accept first responder when a plugin opted in (so its NSPopover mini can
// become key for bare-key handling). Default minis stay non-first-responder, so
// host keyboard shortcuts keep working while interacting with them.
- (BOOL)acceptsFirstResponder {
  return _grabsKeyFocusOnClick;
}

// Interact on the FIRST click even when the popover window isn't key yet (it's
// a nonactivating panel, so clicking in from the layer panel / FCP would
// otherwise be swallowed just to make it key, needing a second click to
// actually drag an OSC). The mini is a transient editing surface - a single
// click should act.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)endFieldEditingGrabbingFocusIfNeeded {
  [self.window
      makeFirstResponder:(_grabsKeyFocusOnClick ? (NSResponder *)self : nil)];
}

- (void)reportHandleValueForLabel:(NSString *)laneLabel
                           values:(NSArray<NSNumber *> *)values {
  if (self.onHandleValue)
    self.onHandleValue(laneLabel, values);
}

- (void)dealloc {
  [_pollTimer invalidate];
  [self _teardownKeyMonitors];
  // NOTE: do NOT CFRelease(_sourceSurface) here. It is only ever an unowned
  // alias of the active filmstrip slot's surface (-_selectActiveSlot:); the
  // slot owns that +1 and releases it in -[_KKMiniFilmSlot dealloc]. Releasing
  // it here too is an over-release - latent for as long as this view leaked
  // (never deallocated), and the crash that surfaced once the popover-close
  // path started freeing the view.
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
  if (_magnifyMon) {
    [NSEvent removeMonitor:_magnifyMon];
    _magnifyMon = nil;
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self _teardownKeyMonitors];
  [self _startPollTimer];
  if (self.window) {
    [self _poll];
    [self _installKeyMonitor];
  }
}

// (Re)arm the descriptor poll at the rate for the current playback state. Also
// called when live playback flips so the footage keeps up (see
// kPollIntervalLive).
- (void)_startPollTimer {
  [_pollTimer invalidate];
  _pollTimer = nil;
  if (!self.window)
    return;
  // Weak block (NOT target:self) - a target:self repeating timer retains the
  // view, so it only deallocs when the timer is invalidated (window-leave /
  // dealloc). The guide's popover juggling (content moving to the overlay /
  // passthrough window, deferred closes) can leave the view in a window with
  // a live timer, so it never deallocs and its MTKView CAMetalLayer drawables
  // (multi-MB IOSurfaces) leak, accumulating per guide run. A weak block lets
  // the view dealloc as soon as its popover releases it; dealloc invalidates
  // the timer.
  __weak typeof(self) weakSelf = self;
  NSTimeInterval iv = _livePlaybackActive ? kPollIntervalLive : kPollInterval;
  _pollTimer = [NSTimer scheduledTimerWithTimeInterval:iv
                                               repeats:YES
                                                 block:^(NSTimer *t) {
                                                   [weakSelf _poll];
                                                 }];
}

- (void)setLivePlaybackActive:(BOOL)active {
  if (_livePlaybackActive == active)
    return;
  _livePlaybackActive = active;
  [self _startPollTimer];
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

// Toolbar tool shortcuts (Control+letter). Same XPC routing caveat as the reset
// key: in FCP's ViewBridge the event may only reach the GLOBAL monitor, so we
// can fire but not always swallow it. Gate on the mini being the visible key
// window and skip while a value field (NSText) is editing.
- (BOOL)_handleToolbarKeyEvent:(NSEvent *)e {
  if (!self.window.isVisible || !self.window.isKeyWindow)
    return NO;
  if ([self.window.firstResponder isKindOfClass:[NSText class]])
    return NO;
  if (![self.canvasDelegate
          respondsToSelector:@selector(
                                 miniViewer:toolbarKeyDownChars:modifiers:)])
    return NO;
  NSString *chars = e.charactersIgnoringModifiers;
  if (chars.length == 0)
    return NO;
  return [self.canvasDelegate miniViewer:self
                     toolbarKeyDownChars:chars
                               modifiers:e.modifierFlags];
}

// Esc / Return etc. for an active drawing tool (pen), via the same monitor as
// the reset + toolbar shortcuts. Gated on the mini being the key window + not
// editing a field. Drawing-tool keys require a drawing tool active; Delete /
// Backspace is forwarded in ANY tool so the cursor can remove a selection.
- (BOOL)_handleToolKeyEvent:(NSEvent *)e {
  if (!self.window.isVisible || !self.window.isKeyWindow)
    return NO;
  if ([self.window.firstResponder isKindOfClass:[NSText class]])
    return NO;
  if (![self.canvasDelegate
          respondsToSelector:@selector(miniViewer:toolKeyDown:)])
    return NO;
  NSString *chars = e.charactersIgnoringModifiers;
  if (chars.length == 0)
    return NO;
  unichar ch = [chars characterAtIndex:0];
  BOOL isDelete = (ch == NSDeleteCharacter || ch == NSBackspaceCharacter);
  BOOL drawingActive =
      [self.canvasDelegate
          respondsToSelector:@selector(miniViewerToolDrawingActive:)] &&
      [self.canvasDelegate miniViewerToolDrawingActive:self];
  if (!drawingActive && !isDelete)
    return NO;
  BOOL handled = [self.canvasDelegate miniViewer:self toolKeyDown:ch];
  if (handled)
    [self setNeedsDisplay:YES]; // redraw the tool overlay (Metal pass) after
                                // the key
  return handled;
}

- (void)_installKeyMonitor {
  __weak typeof(self) weak = self;
  _keyMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(self) s = weak;
                                     if ([s _handleResetKeyEvent:e] ||
                                         [s _handleToolbarKeyEvent:e] ||
                                         [s _handleToolKeyEvent:e])
                                       return nil;
                                     return e;
                                   }];
  // Global monitor = events delivered to OTHER apps (the local monitor above
  // covers our own process). It exists only because FCP handles its Cmd-key
  // equivalents in the host process and doesn't forward them across ViewBridge
  // - so it's limited to those equivalents (reset / toolbar). The tool keys,
  // which include the DESTRUCTIVE Delete, are NOT handled here: a key typed
  // into another app (e.g. backspace in an editor) must never delete a layer.
  // Those go through the local monitor only (i.e. when FCP itself has the
  // event).
  _keyGlobalMon =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                             handler:^(NSEvent *e) {
                                               __strong typeof(self) s = weak;
                                               if ([s _handleResetKeyEvent:e])
                                                 return;
                                               [s _handleToolbarKeyEvent:e];
                                             }];
  // Pinch-to-zoom via a LOCAL magnify monitor instead of the magnifyWithEvent:
  // responder (which AppKit only calls on the key window - so a pinch over the
  // mini does nothing while the companion layer list holds key). The monitor
  // fires for the app's magnify events regardless of key window and routes by
  // pointer location; applyMagnifyEvent: reads the global mouse position. Gated
  // on pointerOverCanvas so it ignores pinches over other views (e.g. the
  // timeline graph keeps its own zoom). Swallow when handled so no other
  // responder double-zooms.
  _magnifyMon =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                            handler:^NSEvent *(NSEvent *e) {
                                              __strong typeof(self) s = weak;
                                              if ([s pointerOverCanvas]) {
                                                [s applyMagnifyEvent:e];
                                                return nil;
                                              }
                                              return e;
                                            }];
}

- (BOOL)_resolveSlot:(_KKMiniFilmSlot *)slot
                 sid:(uint32_t)sid
                 gen:(uint64_t)gen
                 tag:(double)tag
         pixelFormat:(NSString *)format {
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
    MTLPixelFormat pixelFormat = [format isEqualToString:@"rgba16Float"]
                                     ? MTLPixelFormatRGBA16Float
                                     : MTLPixelFormatBGRA8Unorm;
    MTLTextureDescriptor *td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:pixelFormat
                                     width:w
                                    height:h
                                 mipmapped:NO];
    // PixelFormatView so a renderer can take an sRGB view for a linear-light
    // working pass (e.g. a blur runs in linear, not gamma-encoded, space).
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
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

  // Where the PLAYHEAD was when this descriptor was published, or < 0 when the
  // publisher had no fresh sample / wasn't playing. Live playback evaluates the
  // effect at this rather than the frame's own tag - see the +Draw.m note.
  NSNumber *phNum = desc[@"playheadFrac"];
  _feedPlayheadFrac =
      [phNum isKindOfClass:NSNumber.class] ? phNum.doubleValue : -1.0;

  CGSize prevMedia = _sourceMediaSize;
  _sourceMediaSize = CGSizeMake([desc[@"srcWidth"] doubleValue],
                                [desc[@"srcHeight"] doubleValue]);
  if (!CGSizeEqualToSize(prevMedia, _sourceMediaSize) &&
      _sourceMediaSize.width > 0 && self.onSourceResolved)
    self.onSourceResolved();

  // A second texture (Shader's "To" image well), independent of the slots and
  // of the generator/filter split - resolve it before either path returns.
  // Absent from the descriptor for every feed that never publishes one.
  NSDictionary *ch1 = desc[@"channel1"];
  if ([ch1 isKindOfClass:NSDictionary.class]) {
    if (!_channel1Slot)
      _channel1Slot = [[_KKMiniFilmSlot alloc] init];
    uint32_t sid = (uint32_t)[ch1[@"ioSurfaceID"] unsignedIntValue];
    uint64_t gen = (uint64_t)[ch1[@"generation"] unsignedLongLongValue];
    if (sid != _channel1Slot.sid || gen != _channel1Slot.generation)
      [self _resolveSlot:_channel1Slot
                     sid:sid
                     gen:gen
                     tag:0.0
             pixelFormat:ch1[@"pixelFormat"]];
  } else if (_channel1Slot) {
    _channel1Slot = nil; // feed stopped publishing it
  }

  // Generator: the descriptor carries only the media size (empty `slots`),
  // because there is no source feed. Build the filmstrip/onion slots from the
  // delegate's keypose fractions instead of the descriptor, and take the clip
  // aspect from the published media size (no slot-0 surface to read it from).
  if ([self _isGeneratorDelegate]) {
    if (_sourceMediaSize.width > 0 && _sourceMediaSize.height > 0)
      _clipAspect = _sourceMediaSize.width / _sourceMediaSize.height;
    if ([self _rebuildGeneratorSlots])
      [self setNeedsDisplay:YES];
    return;
  }

  // Walk the multi-slot array if present; fall back to the top-level
  // single-slot keys (descriptor format pre-onion-skin).
  NSArray *slotEntries = desc[@"slots"];
  if (![slotEntries isKindOfClass:NSArray.class] || slotEntries.count == 0) {
    NSDictionary *one = @{
      @"ioSurfaceID" : desc[@"ioSurfaceID"] ?: @0,
      @"generation" : desc[@"generation"] ?: @0,
      @"tag" : @0,
      @"pixelFormat" : desc[@"pixelFormat"] ?: @"bgra8",
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
      if ([self _resolveSlot:slot
                         sid:sid
                         gen:gen
                         tag:tag
                 pixelFormat:e[@"pixelFormat"]])
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

- (BOOL)_ensureProcessedTextureForSlot:(_KKMiniFilmSlot *)slot {
  if (!slot.sourceTexture) {
    // Generator path: no source frame. Size the target to the content rect's
    // pixel size (clip aspect) so the delegate can render straight into it.
    id<KKMiniViewerDelegate> genDel = self.canvasDelegate;
    if (![genDel respondsToSelector:
                     @selector(miniViewer:generateIntoTexture:commandBuffer:)])
      return NO;
    CGRect content = [self _contentRectInDrawable];
    // Cap to the drawable (visible) size. Zooming in grows the content rect
    // without bound; sizing the texture to it would exceed Metal's max texture
    // dimension and abort in -[MTLTextureDescriptorInternal
    // validateWithDevice:] (the zoom-in crash). The gradient is smooth, so
    // rendering at viewport resolution and mapping it across the (larger)
    // content-rect quad is visually identical. Zoomed out, content < drawable,
    // so use content.
    CGSize dr = self.drawableSize;
    double capW = dr.width > 0 ? dr.width : content.size.width;
    double capH = dr.height > 0 ? dr.height : content.size.height;
    NSUInteger gW = (NSUInteger)MAX(1.0, round(MIN(content.size.width, capW)));
    NSUInteger gH = (NSUInteger)MAX(1.0, round(MIN(content.size.height, capH)));
    if (slot.processedTexture && slot.processedTexture.width == gW &&
        slot.processedTexture.height == gH)
      return NO;
    MTLTextureDescriptor *gtd = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:gW
                                    height:gH
                                 mipmapped:NO];
    gtd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget |
                MTLTextureUsagePixelFormatView;
    gtd.storageMode = MTLStorageModePrivate;
    slot.processedTexture = [self.device newTextureWithDescriptor:gtd];
    return YES;
  }
  // Render the effect at DISPLAY resolution (the content rect's pixel size in
  // the drawable), aspect-preserved and capped at the source size so we never
  // upscale. The processed texture is only ever blitted 1:1 into its cell, so
  // rendering it at full source res and then minifying into the small popover
  // throws away the soft falloff of soft/bounds effects - making the preview read
  // as a tighter/dimmer glow than the viewer. Rendering at the size it's shown
  // keeps it faithful. (Handles/OSC use the content rect, not these pixels, so
  // this is display-only.)
  //
  // OPT-IN: only soft/bounds effects benefit. A renderer that normalizes by the
  // dest texture's own pixel size (e.g. a transform shader divides
  // the framebuffer position by the texture dims) would zoom in by source/dest
  // if the dest shrank, so it keeps the full source size (the pre-display-res
  // default). Renderers opt in via -prefersDisplayResolutionProcessing.
  NSUInteger srcW = slot.sourceTexture.width, srcH = slot.sourceTexture.height;
  CGRect content = [self _contentRectInDrawable];
  NSUInteger tW = srcW, tH = srcH;
  id<KKMiniViewerDelegate> del = self.canvasDelegate;
  BOOL displayRes =
      [del respondsToSelector:@selector(prefersDisplayResolutionProcessing)] &&
      [(id)del prefersDisplayResolutionProcessing];
  if (displayRes && content.size.width >= 1.0 && content.size.height >= 1.0 &&
      srcW > 0 && srcH > 0) {
    double s = MIN(content.size.width / (double)srcW,
                   content.size.height / (double)srcH);
    s = MIN(s, 1.0); // never upscale past the source
    tW = (NSUInteger)MAX(1.0, round((double)srcW * s));
    tH = (NSUInteger)MAX(1.0, round((double)srcH * s));
  }
  if (slot.processedTexture && slot.processedTexture.width == tW &&
      slot.processedTexture.height == tH)
    return NO;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:tW
                                  height:tH
                               mipmapped:NO];
  td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget |
             MTLTextureUsagePixelFormatView;
  td.storageMode = MTLStorageModePrivate;
  slot.processedTexture = [self.device newTextureWithDescriptor:td];
  return YES;
}

- (void)_ensureProcessedTexture {
  _KKMiniFilmSlot *s0 = _filmstripSlots.firstObject;
  [self _ensureProcessedTextureForSlot:s0];
  _processedTexture = s0.processedTexture;
}

@end
