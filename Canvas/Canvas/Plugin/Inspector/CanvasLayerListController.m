/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerListController_Private.h"
#import "CanvasLayerListView.h"
#import "CanvasLayerRender.h"
#import "Constants.h" // kParamLayerData
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKDataBlob.h> // KKWriteCustomParamString
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPlugin.h>   // KKPerformUndoable
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <QuartzCore/QuartzCore.h>

// Panel sits to the left of the popover card with a small gap, ordered behind
// the popover. Width is fixed for now; height matches the popover card.
static const CGFloat kPanelWidth = 200.0;
static const CGFloat kPanelGap = 8.0;
// Corner radius of the macOS popover chrome we're matching (tweak to taste).
static const CGFloat kPanelCornerRadius = 9.0;
// Hold off until the popover has nearly finished its own entrance, so the two
// don't animate on top of each other.
static const NSTimeInterval kShowDelay = 0.1;
static const NSTimeInterval kFadeDuration = 0.28;
static const CGFloat kSlideDistance = 12.0;

// Borderless panels can't become key by default, which blocks text editing
// (inline layer rename). `becomesKeyOnlyIfNeeded` keeps button clicks from
// stealing focus while still letting a text field become key when edited.
@interface CanvasLayerPanel : NSPanel
@end
@implementation CanvasLayerPanel
- (BOOL)canBecomeKeyWindow {
  return YES;
}
@end

@implementation CanvasLayerListController

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView
                       apiManager:(id<PROAPIAccessing>)apiManager {
  if ((self = [super init])) {
    _apiManager = apiManager;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self
           selector:@selector(_popoverDidOpen:)
               name:KKStaticValuesPopoverDidOpenNotification
             object:lanesView];
    [nc addObserver:self
           selector:@selector(_popoverDidClose:)
               name:KKStaticValuesPopoverDidCloseNotification
             object:lanesView];
  }
  return self;
}

- (void)invalidate {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  // Teardown path (called from -[CanvasInspectorView dealloc]). _hide fires
  // host callbacks (onNonSelectableLayersChanged / ...Marquee...) that are
  // blocks defined in the inspector's init and capture inspector state -
  // invoking them while the inspector is mid-dealloc reads freed memory
  // (SIGSEGV; also stalls the inspector reload after a popover edit ->
  // ViewBridge placeholder). Drop them first so _hide only tears the panel
  // down.
  self.onPrimaryLayerSelected = nil;
  self.onLayerHovered = nil;
  self.onAutoSelectToggled = nil;
  self.onNonSelectableLayersChanged = nil;
  self.onMarqueeNonSelectableLayersChanged = nil;
  [self _hide];
}

- (void)reload {
  [_listView reloadFromParam];
  // Re-assert the authoritative selection by ID after the blob refresh. A
  // structural change (path op, group) writes the new blob and the new
  // selection as two separate params; if the selection (UIState) arrived BEFORE
  // this blob reload, the list couldn't match the not-yet-present result row,
  // so re-apply the stored highlight now that the new rows exist. Stale IDs
  // (consumed operands) simply don't match and stay unselected.
  if (_highlightLayerIDs)
    [_listView setSelectionToLayerIDs:_highlightLayerIDs];
  // A reload can change the layer stack while a popover is open (e.g. a path
  // drawn during a keypose popover): re-grey the layers it can't act on against
  // the new stack so the freshly-added layer isn't clickable.
  [self _refreshNonSelectableForOpenPopover];
}

- (void)highlightLayerID:(NSString *)layerID {
  _highlightLayerID = [layerID copy];
  _highlightLayerIDs = layerID.length ? @[ layerID ] : @[];
  [_listView highlightLayerID:layerID]; // no-op until the panel/list exists
}

- (void)setAutoSelect:(BOOL)autoSelect {
  _autoSelect = autoSelect;
  [_listView setAutoSelect:autoSelect]; // no-op until the panel/list exists
}

- (NSArray<KKBezierPath *> *)currentLayerPaths {
  return CanvasReadLayerPaths(_apiManager, self.paramActionTarget ?: self);
}

- (NSArray<NSString *> *)currentSelectionLayerIDs {
  return [_listView selectedLayerIDs] ?: @[]; // empty until the panel exists
}

- (void)setSelectionLayerIDs:(NSArray<NSString *> *)layerIDs {
  // Store the full set so a panel built LATER (lazily, beside a popover)
  // restores every highlighted row - not just the primary. Empty clears.
  _highlightLayerIDs = [layerIDs copy] ?: @[];
  _highlightLayerID = [layerIDs.firstObject copy];
  [_listView setSelectionToLayerIDs:layerIDs]; // no-op until the panel exists
}

- (void)writePaths:(NSArray<KKBezierPath *> *)paths {
  [self writePaths:paths selectingLayerIDs:nil];
}

- (void)writePaths:(NSArray<KKBezierPath *> *)paths
    clearingSelectionInSameAction:(BOOL)clear {
  [self writePaths:paths selectingLayerIDs:(clear ? @[] : nil)];
}

- (void)writePaths:(NSArray<KKBezierPath *> *)paths
    selectingLayerIDs:(NSArray<NSString *> *)ids {
  id<PROAPIAccessing> api = _apiManager;
  if (!api)
    return;
  KKPerformUndoable(
      api, self.paramActionTarget ?: self, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        NSData *blob = [KKBezierPath blobFromPaths:paths];
        KKWriteCustomParamString(
            setAPI, [blob base64EncodedStringWithOptions:0], kParamLayerData);
        // Set the selection in the SAME action so a blob+selection change
        // undoes as one step. Read -> patch -> write kParamUIState (mirrors
        // KKPlugin -patchUIStateKeys, but inside this action scope rather than
        // its own). nil ids = leave selection untouched (blob-only write).
        if (ids) {
          NSString *existing = KKReadCustomParamString(getAPI, kParamUIState);
          NSMutableDictionary *state =
              (existing.length
                   ? [[NSJSONSerialization
                         JSONObjectWithData:
                             [existing dataUsingEncoding:NSUTF8StringEncoding]
                                    options:0
                                      error:nil] mutableCopy]
                   : nil)
                  ?: [NSMutableDictionary dictionary];
          state[@"selectedLayerID"] = ids.firstObject ?: @"";
          state[@"selectedLayerIDs"] = ids;
          NSString *json = [[NSString alloc]
              initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                           options:0
                                                             error:nil]
                  encoding:NSUTF8StringEncoding];
          KKWriteCustomParamString(setAPI, json, kParamUIState);
        }
      });
  // Rebuild the open panel from the just-written param (no-op when closed).
  [self->_listView reloadFromParam];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

// Resizable rounded-rect mask. NSVisualEffectView uses this both to clip the
// vibrancy AND to shape the window shadow, so the shadow follows the corners.
+ (NSImage *)_roundedMaskImageWithRadius:(CGFloat)radius {
  CGFloat dim = radius * 2.0 + 1.0;
  NSImage *image =
      [NSImage imageWithSize:NSMakeSize(dim, dim)
                     flipped:NO
              drawingHandler:^BOOL(NSRect rect) {
                [[NSColor blackColor] set];
                [[NSBezierPath bezierPathWithRoundedRect:rect
                                                 xRadius:radius
                                                 yRadius:radius] fill];
                return YES;
              }];
  image.capInsets = NSEdgeInsetsMake(radius, radius, radius, radius);
  image.resizingMode = NSImageResizingModeStretch;
  return image;
}

- (NSPanel *)_ensurePanel {
  if (_panel)
    return _panel;
  NSPanel *p = [[CanvasLayerPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, kPanelWidth, 300)
                styleMask:NSWindowStyleMaskBorderless |
                          NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:YES];
  // Take key so a text field (inline rename) can capture keyboard.
  // (Nonactivating means it does so WITHOUT activating our XPC process /
  // deactivating FCP.)
  p.becomesKeyOnlyIfNeeded = NO;
  p.hasShadow = YES;
  p.releasedWhenClosed = NO;
  // NSPanel defaults this to YES, and in a ViewBridge process activation
  // churns constantly: each deactivation orders the panel out, which ALSO
  // drops the parent/child link and orphans it until the popover is reopened.
  // Same fix as Mirage's template browser panel.
  p.hidesOnDeactivate = NO;
  p.backgroundColor = NSColor.clearColor;
  p.opaque = NO;
  // We drive the fade ourselves; suppress AppKit's default order-in animation.
  p.animationBehavior = NSWindowAnimationBehaviorNone;

  // The Layers panel content (header + scrollable well + empty state). Fills
  // the panel; its own internal padding matches the popover's content inset.
  CanvasLayerListView *content =
      [[CanvasLayerListView alloc] initWithFrame:NSZeroRect];
  content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  content.apiManager = _apiManager;
  content.paramActionTarget = self.paramActionTarget;
  __weak typeof(self) weakSelf = self;
  content.onPrimaryLayerSelected = ^(NSString *layerID) {
    __strong typeof(weakSelf) s = weakSelf;
    if (s.onPrimaryLayerSelected)
      s.onPrimaryLayerSelected(layerID);
  };
  content.onLayerHovered = ^(NSString *layerID) {
    __strong typeof(weakSelf) s = weakSelf;
    if (s.onLayerHovered)
      s.onLayerHovered(layerID);
  };
  content.onAutoSelectToggled = ^(BOOL on) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    s->_autoSelect = on;
    if (s.onAutoSelectToggled)
      s.onAutoSelectToggled(on);
  };
  content.autoSelect = _autoSelect;
  _listView = content;

  if (@available(macOS 26.0, *)) {
    // Match the popover: it's drawn with the new Liquid Glass material
    // (NSGlassEffectView). cornerRadius gives a soft glass edge - no hard
    // outline, no maskImage seam. Appearance is copied from the popover at
    // show time so the tint matches.
    NSGlassEffectView *glass =
        [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
    glass.cornerRadius = kPanelCornerRadius;
    // Opaque inspector-matched fill so the layer list reads like the popovers
    // beside it, not see-through liquid glass. The glass clips it to the corner
    // radius, so the panel keeps its rounded shape and shadow.
    content.wantsLayer = YES;
    content.layer.backgroundColor =
        [NSColor.inspectorBackground colorWithAlphaComponent:0.5].CGColor;
    glass.contentView = content;
    p.contentView = glass;
  } else {
    // Pre-26 fallback: flat vibrancy + rounded mask (mask drives the shadow,
    // so it stays rounded). The mask alone doesn't stroke an outline, so on
    // Sequoia the panel edge melts into the background - add a hairline border
    // (clipped to the same rounded shape by the mask) to give it the same
    // defined edge the Tahoe glass path and system windows have.
    NSVisualEffectView *fx =
        [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    fx.material = NSVisualEffectMaterialContentBackground;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
    fx.wantsLayer = YES;
    fx.layer.cornerRadius = kPanelCornerRadius;
    fx.layer.borderColor = NSColor.separatorColor.CGColor;
    fx.layer.borderWidth = 1.0;
    fx.maskImage = [CanvasLayerListController
        _roundedMaskImageWithRadius:kPanelCornerRadius];
    content.frame = fx.bounds;
    [fx addSubview:content];
    p.contentView = fx;
  }

  _panel = p;
  return _panel;
}

- (void)_popoverDidOpen:(NSNotification *)note {
  NSWindow *popoverWindow = note.userInfo[@"window"];
  if (![popoverWindow isKindOfClass:[NSWindow class]])
    return;

  // Align to the visible popover card (the window frame includes shadow +
  // arrow padding, so it's taller/wider than the card).
  NSValue *cardVal = note.userInfo[@"contentRect"];
  NSRect card = cardVal ? cardVal.rectValue : popoverWindow.frame;
  // Keep the content view so we can recompute the card if the popover later
  // resizes or flips edge (e.g. switching layers retargets the popover).
  _popoverContentView = note.userInfo[@"contentView"];

  // A keypose popover edits one moment in time: layers with no keypose at that
  // time can't be selected (grayed). The Constants popover (isBoundary NO)
  // leaves every layer selectable.
  // Gray the layers you can't act on for this popover kind:
  //  - keypose: layers with no keypose at this time;
  //  - constants: layers whose MOVE lane (Points / Position) is animated - they
  //    can't be positioned via constants (that lane isn't shown there);
  //  - manage (Animated dropdown): none - any layer's params can be animated.
  NSString *kind = note.userInfo[@"kind"] ?: @"constants";
  double frac = [note.userInfo[@"fraction"] doubleValue];
  _openPopoverKind = [kind copy];
  _openPopoverFraction = frac;
  NSSet<NSString *> *nonSelectable = [self _nonSelectableForKind:kind
                                                        fraction:frac];

  // Mirror the gating onto the mini-viewer's auto-select (and anything else the
  // host wires) so clicking a layer in the popover preview honors the same
  // keypose/constants rule as the layer list.
  if (self.onNonSelectableLayersChanged)
    self.onNonSelectableLayersChanged(nonSelectable);
  // The MARQUEE / body-drag (which select to MOVE) use a stricter set in the
  // constants popover: a move-lane-animated layer can't be positioned via
  // constants, so it's excluded from multi-select even though a single click
  // can still pick it to edit its other constants. Other kinds reuse the same
  // set.
  NSSet<NSString *> *marqueeNonSelectable =
      [kind isEqualToString:@"constants"] ? [self _layersWithMoveLaneAnimated]
                                          : nonSelectable;
  if (self.onMarqueeNonSelectableLayersChanged)
    self.onMarqueeNonSelectableLayersChanged(marqueeNonSelectable);

  // Pre-highlight the selected layer unless the popover already drove the
  // highlight itself (keypose/constants set it before this notification).
  if (!_highlightLayerID && _selectedLayerID.length) {
    _highlightLayerID = [_selectedLayerID copy];
    if (!_highlightLayerIDs)
      _highlightLayerIDs = @[ _selectedLayerID ];
  }

  // Mark this popover as the pending target, then show once it is actually on
  // screen - the delay also lets the popover's own entrance play first.
  _parentWindow = popoverWindow;
  [self _showWhenVisibleWithCard:card
                   nonSelectable:nonSelectable
                         attempt:0];
}

// Wait for the popover window to actually be on screen, RETRYING rather than
// checking once.
//
// The first time a popover opens its views are built from scratch, so on a cold
// FCP boot it is routinely still invisible when a single fixed delay elapses.
// The old one-shot check just returned, and the layer list then never appeared
// until the popover was closed and reopened - by which point the window was warm
// and made the deadline, which is why it only ever looked broken on the first
// try. Bounded, so a popover that never appears stops the chain instead of
// polling forever.
//
// The window is re-read from the CONTENT VIEW on every attempt: at cold boot the
// notification can carry a window that is not the one the view ends up in, and
// holding the original meant waiting on a window that would never show.
- (void)_showWhenVisibleWithCard:(NSRect)card
                   nonSelectable:(NSSet<NSString *> *)nonSelectable
                         attempt:(NSInteger)attempt {
  static const NSInteger kMaxAttempts = 100; // ~10s at kShowDelay
  NSView *pending = _popoverContentView;
  NSWindow *window = pending.window ?: _parentWindow;
  if (window && window.isVisible) {
    _parentWindow = window;
    [self _showBesideCard:card ofWindow:window nonSelectable:nonSelectable];
    return;
  }
  if (attempt + 1 >= kMaxAttempts) {
    KKLogWarn(@"[LayerList] popover never became visible, no panel");
    return;
  }
  __weak typeof(self) weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShowDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        // A different popover took over, or this one closed.
        if (!s || s->_popoverContentView != pending)
          return;
        [s _showWhenVisibleWithCard:card
                      nonSelectable:nonSelectable
                            attempt:attempt + 1];
      });
}

// NO when a popover is open AND `layerID` is non-selectable in it (e.g. a new
// constant path has no keypose for a keypose popover) - so the host doesn't
// adopt it as the selection. YES when no popover is open (no scope).
- (BOOL)isLayerSelectableInOpenPopover:(NSString *)layerID {
  if (_openPopoverKind.length == 0 || layerID.length == 0)
    return YES;
  NSSet<NSString *> *ns = [self _nonSelectableForKind:_openPopoverKind
                                             fraction:_openPopoverFraction];
  return ![ns containsObject:layerID];
}

- (void)_showBesideCard:(NSRect)card
               ofWindow:(NSWindow *)popoverWindow
          nonSelectable:(NSSet<NSString *> *)nonSelectable {
  if (_visible)
    [self _hide];

  NSPanel *panel = [self _ensurePanel];
  // Inherit the popover's appearance (FCP's NOXInspector) so the glass tints
  // the same instead of rendering under the default system appearance.
  panel.appearance = popoverWindow.appearance;
  // Prefer the LIVE card over the open-time snapshot: the popover may have
  // settled or flipped edge during the show delay (before our move/resize
  // observers existed), which would otherwise leave the panel at the wrong
  // height/position.
  NSView *cv = _popoverContentView;
  if (cv.window) {
    NSRect live = [cv.window convertRectToScreen:[cv convertRect:cv.bounds
                                                          toView:nil]];
    if (!NSIsEmptyRect(live))
      card = live;
  }
  NSRect finalFrame = [self _panelFrameForCard:card];
  NSRect startFrame = finalFrame;
  // Emerge from UNDER the popover: a left-placed panel starts to its right (the
  // popover side) and slides left into place; a right-placed panel mirrors it.
  BOOL panelOnLeft = NSMidX(finalFrame) < NSMidX(card);
  startFrame.origin.x += panelOnLeft ? kSlideDistance : -kSlideDistance;

  // Follow the popover if it later resizes or flips edge (e.g. switching layers
  // retargets the popover above<->below the anchor). The card is recomputed
  // from the live content view, so the height always excludes the arrow.
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc removeObserver:self name:NSWindowDidMoveNotification object:nil];
  [nc removeObserver:self name:NSWindowDidResizeNotification object:nil];
  [nc addObserver:self
         selector:@selector(_popoverFrameChanged:)
             name:NSWindowDidMoveNotification
           object:popoverWindow];
  [nc addObserver:self
         selector:@selector(_popoverFrameChanged:)
             name:NSWindowDidResizeNotification
           object:popoverWindow];

  // Fade the CONTENT view, not the window: window alphaValue doesn't animate
  // for a ViewBridge child window (only the frame does), and the glass material
  // ignores it too. View-level alpha (layer opacity) animates reliably.
  panel.alphaValue = 1.0;
  panel.contentView.alphaValue = 0.0;
  [panel setFrame:startFrame display:NO];

  // Child window ordered BELOW the popover (tucks under it, no seam) but still
  // above FCP; keep-alive so a click inside it doesn't trip the popover's
  // outside-click dismissal.
  _parentWindow = popoverWindow;
  [popoverWindow addChildWindow:panel ordered:NSWindowBelow];
  KKPopoverAddKeepAliveWindow(panel);
  // Keypose popover: gray the layers with no keypose at its time (can't be
  // selected). Constants: nil = every layer selectable.
  _listView.nonSelectableReason =
      [self _nonSelectableReasonForKind:_openPopoverKind];
  [_listView setNonSelectableLayerIDs:nonSelectable];
  // Apply the pending FULL selection (requested before the list view existed)
  // so every selected row highlights, not just the primary. Empty clears all.
  NSArray<NSString *> *pending =
      _highlightLayerIDs
          ?: (_highlightLayerID.length ? @[ _highlightLayerID ] : @[]);
  [_listView setSelectionToLayerIDs:pending];
  // Reflect the current toggle state (may have changed via undo/redo while the
  // panel was closed).
  [_listView setAutoSelect:_autoSelect];
  _visible = YES;

  // Animate on the next runloop tick - once the window is actually on screen,
  // so the alpha tween isn't dropped (animating it in the same callstack as
  // orderFront only slid the frame, never faded).
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
      ctx.duration = kFadeDuration;
      ctx.timingFunction = [CAMediaTimingFunction
          functionWithName:kCAMediaTimingFunctionEaseOut];
      panel.contentView.animator.alphaValue = 1.0;
      [panel.animator setFrame:finalFrame display:YES];
    }];
  });
}

// Panel frame for a popover card: pinned beside the card, matching its top and
// height (so the arrow above/below is excluded). Prefers the LEFT of the card,
// but flips to the RIGHT when the left placement would run off the screen (a
// narrow FCP window puts the popover near the left edge, so the companion would
// otherwise clip). Clamps into the visible frame as a last resort.
- (NSRect)_panelFrameForCard:(NSRect)card {
  NSRect vis = [self _screenVisibleFrameForCard:card];
  CGFloat left = card.origin.x - kPanelWidth - kPanelGap;
  CGFloat right = NSMaxX(card) + kPanelGap;
  CGFloat x = left;
  if (left < NSMinX(vis) && right + kPanelWidth <= NSMaxX(vis))
    x = right; // left clips but the right side has room - flip beside the card
  x = MAX(NSMinX(vis), MIN(x, NSMaxX(vis) - kPanelWidth)); // last-resort clamp
  return NSMakeRect(x, card.origin.y, kPanelWidth, card.size.height);
}

// Visible frame of the screen the popover card sits on (so flip/clamp respects
// the Dock/menu-bar insets). Falls back to the main screen.
- (NSRect)_screenVisibleFrameForCard:(NSRect)card {
  NSPoint center = NSMakePoint(NSMidX(card), NSMidY(card));
  for (NSScreen *s in NSScreen.screens)
    if (NSPointInRect(center, s.frame))
      return s.visibleFrame;
  NSScreen *fallback = _popoverContentView.window.screen ?: NSScreen.mainScreen;
  return fallback.visibleFrame;
}

// Snap the panel to the popover's current card (live content view -> screen, so
// the arrow is always excluded whichever edge it's on).
- (void)_alignPanelToPopover {
  NSView *cv = _popoverContentView;
  if (!_visible || !cv.window)
    return;
  NSRect card = [cv.window convertRectToScreen:[cv convertRect:cv.bounds
                                                        toView:nil]];
  if (NSIsEmptyRect(card))
    return;
  [_panel setFrame:[self _panelFrameForCard:card] display:YES];
}

// The popover moved or resized (incl. flipping above<->below when re-anchoring
// to the new layer's keypose row). DEFER the re-align: AppKit applies the
// parent->child move as a delta to our panel AFTER this notification, and the
// popover's reposition may still be settling, so aligning synchronously here
// gets overwritten by exactly the popover's move distance (the symptom: the
// panel ends up offset by an amount that tracks the keypose row). A
// next-runloop snap runs after the delta + layout land, and a short settle pass
// catches an animated reposition.
- (void)_popoverFrameChanged:(NSNotification *)note {
  if (!_visible)
    return;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weak _alignPanelToPopover];
  });
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [weak _alignPanelToPopover];
      });
}

- (void)_popoverDidClose:(NSNotification *)note {
  [self _hide];
}

- (void)_hide {
  NSWindow *parent = _parentWindow;
  _parentWindow = nil;
  _openPopoverKind =
      nil; // popover gone: stop re-deriving its non-selectable set
  if (!_visible)
    return;
  _visible = NO;
  _highlightLayerID = nil;
  _popoverContentView = nil;
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  [nc removeObserver:self name:NSWindowDidMoveNotification object:nil];
  [nc removeObserver:self name:NSWindowDidResizeNotification object:nil];
  [_listView setNonSelectableLayerIDs:nil];
  if (self.onNonSelectableLayersChanged)
    self.onNonSelectableLayersChanged(nil);
  if (self.onMarqueeNonSelectableLayersChanged)
    self.onMarqueeNonSelectableLayersChanged(nil);
  KKPopoverRemoveKeepAliveWindow(_panel);
  [parent removeChildWindow:_panel];
  [_panel orderOut:nil];
}

@end
