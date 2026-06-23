/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerListController.h"
#import "CanvasLayerListView.h"
#import "CanvasLayerRender.h"
#import "Constants.h" // kParamLayerData
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKDataBlob.h> // KKWriteCustomParamString
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <KeyframelessKit/KKTokens.h>
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

@implementation CanvasLayerListController {
  NSPanel *_panel;
  __weak CanvasLayerListView *_listView;
  __weak NSWindow *_parentWindow; // also the pending target during the delay
  __weak NSView *_popoverContentView; // re-align source when the popover flips
  BOOL _visible;
  __weak id<PROAPIAccessing> _apiManager;
  // Layer to highlight in the list (a keypose popover's active layer). Stored
  // so it survives the panel being created lazily AFTER the highlight is
  // requested.
  NSString *_highlightLayerID;
  // The FULL multi-selection to highlight (every selected row), stored so it
  // survives the lazily-built panel - the single _highlightLayerID is just its
  // primary. Empty = no rows highlighted (a real deselect).
  NSArray<NSString *> *_highlightLayerIDs;
}

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
  [self _hide];
}

- (void)reload {
  [_listView reloadFromParam];
  // Re-assert the authoritative selection by ID after the blob refresh. A
  // structural change (path op, group) writes the new blob and the new selection
  // as two separate params; if the selection (UIState) arrived BEFORE this blob
  // reload, the list couldn't match the not-yet-present result row, so re-apply
  // the stored highlight now that the new rows exist. Stale IDs (consumed
  // operands) simply don't match and stay unselected.
  if (_highlightLayerIDs)
    [_listView setSelectionToLayerIDs:_highlightLayerIDs];
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
  [self writePaths:paths clearingSelectionInSameAction:NO];
}

- (void)writePaths:(NSArray<KKBezierPath *> *)paths
    clearingSelectionInSameAction:(BOOL)clear {
  id<PROAPIAccessing> api = _apiManager;
  if (!api)
    return;
  id<FxCustomParameterActionAPI_v4> action =
      [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action)
    return;
  id target = self.paramActionTarget ?: self;
  [action startAction:target];
  id<FxParameterSettingAPI_v5> setAPI =
      [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  KKWriteCustomParamString(setAPI, [blob base64EncodedStringWithOptions:0],
                           kParamLayerData);
  // Clear the selection in the SAME action so a delete undoes as one step. Read
  // -> patch -> write kParamUIState (mirrors KKPlugin -patchUIStateKeys, but
  // inside this action scope rather than its own).
  if (clear) {
    id<FxParameterRetrievalAPI_v6> getAPI =
        [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *existing = KKReadCustomParamString(getAPI, kParamUIState);
    NSMutableDictionary *state =
        (existing.length
             ? [[NSJSONSerialization
                   JSONObjectWithData:[existing
                                          dataUsingEncoding:NSUTF8StringEncoding]
                              options:0
                                error:nil] mutableCopy]
             : nil)
            ?: [NSMutableDictionary dictionary];
    state[@"selectedLayerID"] = @"";
    state[@"selectedLayerIDs"] = @[];
    NSString *json = [[NSString alloc]
        initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                     options:0
                                                       error:nil]
            encoding:NSUTF8StringEncoding];
    KKWriteCustomParamString(setAPI, json, kParamUIState);
  }
  [action endAction:target];
  // Rebuild the open panel from the just-written param (no-op when closed).
  [_listView reloadFromParam];
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
    glass.contentView = content;
    p.contentView = glass;
  } else {
    // Pre-26 fallback: flat vibrancy + rounded mask (mask drives the shadow,
    // so it stays rounded). No layer border.
    NSVisualEffectView *fx =
        [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    fx.material = NSVisualEffectMaterialContentBackground;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
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
  NSSet<NSString *> *nonSelectable = nil;
  if ([kind isEqualToString:@"keypose"])
    nonSelectable = [self _layersWithoutKeyposeAtFraction:frac];
  else if ([kind isEqualToString:@"constants"])
    nonSelectable = [self _layersWithoutConstant];
  else if ([kind isEqualToString:@"appliesTo"])
    nonSelectable = [self _layersWithoutAnimation];

  // Mirror the gating onto the mini-viewer's auto-select (and anything else the
  // host wires) so clicking a layer in the popover preview honors the same
  // keypose/constants rule as the layer list.
  if (self.onNonSelectableLayersChanged)
    self.onNonSelectableLayersChanged(nonSelectable);
  // The MARQUEE / body-drag (which select to MOVE) use a stricter set in the
  // constants popover: a move-lane-animated layer can't be positioned via
  // constants, so it's excluded from multi-select even though a single click can
  // still pick it to edit its other constants. Other kinds reuse the same set.
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

  // Mark this popover as the pending target, then show after a delay so the
  // popover's own entrance plays first.
  _parentWindow = popoverWindow;
  __weak typeof(self) weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShowDelay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || s->_parentWindow != popoverWindow || !popoverWindow.isVisible)
          return; // popover closed (or replaced) during the delay
        [s _showBesideCard:card
                  ofWindow:popoverWindow
             nonSelectable:nonSelectable];
      });
}

// Layers (by layerID) that have NO keypose at clip fraction `frac` in any of
// their animated lanes - they can't be the edit target of a keypose popover.
- (NSSet<NSString *> *)_layersWithoutKeyposeAtFraction:(double)frac {
  NSArray<KKBezierPath *> *paths = [self currentLayerPaths];
  // The Basic out-end boundary is EDGE-PARKED: its pill (and the popover's
  // reported fraction) sits at 1.0, but the keypose itself lands at
  // lastFrameFrac (<1.0). An exact match against 1.0 finds no keypose on ANY
  // layer, so the whole list dims (yet the layer is fully editable - navigating
  // to the same keypose shows it un-dimmed). Basic keypose times are shared
  // across layers, so snap `frac` to the nearest actual keypose time first,
  // then match against that. A genuinely-constant layer (no keyposes near the
  // snapped time) still dims correctly.
  double snapped = frac, bestD = INFINITY;
  for (KKBezierPath *p in paths) {
    if (!p.animationJSON.length)
      continue;
    KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
    for (KKLane *l in tl.lanes) {
      if (!l.enabled)
        continue;
      for (KKKeyPose *kp in l.keyposes) {
        double d = fabs(kp.time - frac);
        if (d < bestD) {
          bestD = d;
          snapped = kp.time;
        }
      }
    }
  }

  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKBezierPath *p in paths) {
    if (!p.layerID.length)
      continue;
    BOOL has = NO;
    if (p.animationJSON.length) {
      KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
      for (KKLane *l in tl.lanes) {
        if (!l.enabled)
          continue;
        for (KKKeyPose *kp in l.keyposes)
          if (fabs(kp.time - snapped) < 1.0e-4) {
            has = YES;
            break;
          }
        if (has)
          break;
      }
    }
    if (!has)
      [out addObject:p.layerID];
  }
  return out;
}

// Layers (by layerID) that are fully animated (no constant param) - they can't
// be the edit target of a Constants popover.
// Layers (by layerID) with NO animated lanes - nothing for a curve / modulation
// ("Applies to") popover to act on, so they can't be the target.
- (NSSet<NSString *> *)_layersWithoutAnimation {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKBezierPath *p in [self currentLayerPaths]) {
    if (!p.layerID.length)
      continue;
    if (p.animationJSON.length == 0) {
      [out addObject:p.layerID]; // no animation blob at all
      continue;
    }
    KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
    BOOL anyAnimated = NO;
    for (KKLane *l in tl.lanes)
      if (l.enabled) {
        anyAnimated = YES;
        break;
      }
    if (!anyAnimated)
      [out addObject:p.layerID];
  }
  return out;
}

// SINGLE-click / layer-list gating for the Constants popover: a layer is
// non-selectable only when FULLY animated (no constant lane to edit at all). A
// layer with any constant lane stays clickable - you can edit that constant.
- (NSSet<NSString *> *)_layersWithoutConstant {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKBezierPath *p in [self currentLayerPaths]) {
    if (!p.layerID.length || p.animationJSON.length == 0)
      continue; // no animationJSON => all constant => selectable
    KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
    NSUInteger animated = 0;
    for (KKLane *l in tl.lanes)
      if (l.enabled)
        animated++;
    if (animated >= _templateLaneCount)
      [out addObject:p.layerID]; // fully animated: no constants to edit
  }
  return out;
}

// STRICTER gating used only for the MARQUEE / body-drag in the Constants popover:
// a layer is non-selectable when its MOVE lane is animated - Points for a vector
// path, Position for an image / group. That lane is the ground truth for where
// the layer sits, so when it's animated the layer can't be positioned via
// constants (and a marquee selects to MOVE). Single-click stays lenient above.
- (NSSet<NSString *> *)_layersWithMoveLaneAnimated {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKBezierPath *p in [self currentLayerPaths]) {
    if (!p.layerID.length || p.animationJSON.length == 0)
      continue;
    NSString *moveLane = (p.isImage || p.isGroup) ? @"Position" : @"Points";
    KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
    for (KKLane *l in tl.lanes)
      if ([l.label isEqualToString:moveLane]) {
        if (l.enabled && l.keyposes.count >= 2)
          [out addObject:p.layerID];
        break;
      }
  }
  return out;
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
  startFrame.origin.x += kSlideDistance; // slide in toward the popover

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
  [_listView setNonSelectableLayerIDs:nonSelectable];
  // Apply the pending FULL selection (requested before the list view existed) so
  // every selected row highlights, not just the primary. Empty clears all.
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

// Panel frame for a popover card: pinned to the card's left edge with a gap,
// matching the card's top and height (so the arrow above/below is excluded).
- (NSRect)_panelFrameForCard:(NSRect)card {
  return NSMakeRect(card.origin.x - kPanelWidth - kPanelGap, card.origin.y,
                    kPanelWidth, card.size.height);
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
