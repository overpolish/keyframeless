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
#import <KeyframelessKit/KKPlugin.h> // KKPerformUndoable
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTimeline.h>
#import <QuartzCore/QuartzCore.h>

// Panel sits to the left of the popover card, ordered behind it. Width is fixed
// for now; height matches the popover card (KKCompanionPanelController).
static const CGFloat kPanelWidth = 200.0;

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
    // Arrowing between keyposes (or an in-place keypose <-> constants switch)
    // moves what the OPEN popover edits without reopening it, and the gray set
    // is a function of that kind + time. Deliberately a separate, narrower
    // handler than the open one: it must not re-run the panel show path (the
    // panel would re-slide on every arrow press).
    [nc addObserver:self
           selector:@selector(_popoverDidNavigate:)
               name:KKStaticValuesPopoverDidNavigateNotification
             object:lanesView];
    [nc addObserver:self
           selector:@selector(_sidebarVisibilityChanged:)
               name:KKStaticValuesSidebarVisibilityDidChangeNotification
             object:lanesView];
  }
  return self;
}

- (void)invalidate {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  // Teardown path (called from -[CanvasInspectorView dealloc]). Hiding fires
  // host callbacks (onNonSelectableLayersChanged / ...Marquee...) that are
  // blocks defined in the inspector's init and capture inspector state -
  // invoking them while the inspector is mid-dealloc reads freed memory
  // (SIGSEGV; also stalls the inspector reload after a popover edit ->
  // ViewBridge placeholder). Drop them first so the hide only tears the panel
  // down.
  self.onPrimaryLayerSelected = nil;
  self.onLayerHovered = nil;
  self.onAutoSelectToggled = nil;
  self.onNonSelectableLayersChanged = nil;
  self.onMarqueeNonSelectableLayersChanged = nil;
  [_panelController hide];
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

// The companion panel and everything about the window it lives in comes from
// the kit; this builds the content and reacts to attach / hide.
- (KKCompanionPanelController *)_ensurePanelController {
  if (_panelController)
    return _panelController;
  __weak typeof(self) weakSelf = self;
  KKCompanionPanelController *pc =
      [[KKCompanionPanelController alloc] initWithPanelWidth:kPanelWidth
                                                      logTag:@"LayerList"];
  // The Layers panel content (header + scrollable well + empty state). Fills
  // the panel; its own internal padding matches the popover's content inset.
  pc.contentBuilder = ^NSView * {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return nil;
    CanvasLayerListView *content =
        [[CanvasLayerListView alloc] initWithFrame:NSZeroRect];
    content.apiManager = s->_apiManager;
    content.paramActionTarget = s.paramActionTarget;
    content.onPrimaryLayerSelected = ^(NSString *layerID) {
      __strong typeof(weakSelf) inner = weakSelf;
      if (inner.onPrimaryLayerSelected)
        inner.onPrimaryLayerSelected(layerID);
    };
    content.onLayerHovered = ^(NSString *layerID) {
      __strong typeof(weakSelf) inner = weakSelf;
      if (inner.onLayerHovered)
        inner.onLayerHovered(layerID);
    };
    content.onAutoSelectToggled = ^(BOOL on) {
      __strong typeof(weakSelf) inner = weakSelf;
      if (!inner)
        return;
      inner->_autoSelect = on;
      if (inner.onAutoSelectToggled)
        inner.onAutoSelectToggled(on);
    };
    content.autoSelect = s->_autoSelect;
    s->_listView = content;
    return content;
  };
  pc.onDidAttach = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    // Keypose popover: gray the layers with no keypose at its time (can't be
    // selected). Constants: nil = every layer selectable.
    s->_listView.nonSelectableReason =
        [s _nonSelectableReasonForKind:s->_openPopoverKind];
    [s->_listView setNonSelectableLayerIDs:s->_pendingNonSelectable];
    // Apply the pending FULL selection (requested before the list view existed)
    // so every selected row highlights, not just the primary. Empty clears all.
    NSArray<NSString *> *pending =
        s->_highlightLayerIDs
            ?: (s->_highlightLayerID.length ? @[ s->_highlightLayerID ] : @[]);
    [s->_listView setSelectionToLayerIDs:pending];
    // Reflect the current toggle state (may have changed via undo/redo while
    // the panel was closed).
    [s->_listView setAutoSelect:s->_autoSelect];
  };
  pc.onPrepareHide = ^{
    __strong typeof(weakSelf) s = weakSelf;
    // popover gone: stop re-deriving its non-selectable set
    if (s)
      s->_openPopoverKind = nil;
  };
  pc.onDidHide = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    s->_highlightLayerID = nil;
    [s->_listView setNonSelectableLayerIDs:nil];
    if (s.onNonSelectableLayersChanged)
      s.onNonSelectableLayersChanged(nil);
    if (s.onMarqueeNonSelectableLayersChanged)
      s.onMarqueeNonSelectableLayersChanged(nil);
  };
  _panelController = pc;
  return pc;
}

- (void)_popoverDidOpen:(NSNotification *)note {
  NSNumber *sidebarVisible = note.userInfo[@"sidebarVisible"];
  // NSPopover-hosted structural surfaces (Animated/filter/OSC) do not carry
  // the editor-only sidebarVisible metadata. They still share the SAME global
  // sidebar preference: hiding Layers in Constants must not let Animated
  // resurrect it and take ownership of the child panel. Resolve the live lanes
  // view state when the notification omits the key.
  if (!sidebarVisible &&
      [note.object
          respondsToSelector:NSSelectorFromString(@"editorSidebarVisible")])
    sidebarVisible = [note.object valueForKey:@"editorSidebarVisible"];
  if (sidebarVisible && !sidebarVisible.boolValue) {
    _openGeneration++;
    _attachedContentView = nil;
    _overlayContentView = nil;
    _underlyingPopoverKind = nil;
    [_panelController hide];
    return;
  }
  NSWindow *popoverWindow = note.userInfo[@"window"];
  if (![popoverWindow isKindOfClass:[NSWindow class]])
    return;

  // Align to the visible popover card (the window frame includes shadow +
  // arrow padding, so it's taller/wider than the card).
  NSValue *cardVal = note.userInfo[@"contentRect"];
  NSRect card = cardVal ? cardVal.rectValue : popoverWindow.frame;
  // Hand the content view over too, so the panel can recompute the card if the
  // popover later resizes or flips edge (e.g. switching layers retargets it).
  NSView *contentView = note.userInfo[@"contentView"];

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

  // An option popover (Animated/filter/OSC) may sit over the persistent
  // keypose/constants editor. The layer list is already a child of that editor
  // panel. ViewBridge does not permit moving the same marshalled child window
  // straight onto the option popover and raises from addChildWindow: if we try.
  // Keep the window where it is and only borrow the option's logical scope;
  // closing the option restores the editor scope below.
  BOOL borrowsExistingPanel = _panelController.visible &&
                              _attachedContentView && contentView &&
                              contentView != _attachedContentView;
  if (borrowsExistingPanel) {
    if (!_overlayContentView) {
      _underlyingPopoverKind = [_openPopoverKind copy];
      _underlyingPopoverFraction = _openPopoverFraction;
    }
    _overlayContentView = contentView;
  }
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
  _pendingNonSelectable = nonSelectable;
  if (borrowsExistingPanel) {
    _listView.nonSelectableReason = [self _nonSelectableReasonForKind:kind];
    [_listView setNonSelectableLayerIDs:nonSelectable];
    return;
  }
  // Match Mirage's reliable template-browser path: hand the request directly
  // to the shared controller. It already waits/retries until the editor window
  // is visible and cancels a stale wait by content-view identity. Canvas used
  // to add a second dispatch/generation layer here; that extra lifecycle could
  // lose a reopen even though the persisted sidebar toggle still said ON.
  ++_openGeneration;
  _attachedContentView = contentView;
  _overlayContentView = nil;
  _underlyingPopoverKind = nil;
  [[self _ensurePanelController] openBesideCard:card
                                  popoverWindow:popoverWindow
                             popoverContentView:contentView];
}

- (void)_sidebarVisibilityChanged:(NSNotification *)note {
  if (![note.userInfo[@"visible"] boolValue]) {
    _openGeneration++;
    _attachedContentView = nil;
    _overlayContentView = nil;
    _underlyingPopoverKind = nil;
    [_panelController hide];
    return;
  }
  [self _popoverDidOpen:note];
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

- (void)_popoverDidNavigate:(NSNotification *)note {
  // No popover of ours is open (close already cleared the scope): nothing to
  // re-derive, and adopting a kind here would gray rows with no popover up.
  if (!_openPopoverKind.length)
    return;
  NSString *kind = note.userInfo[@"kind"];
  if (kind.length)
    _openPopoverKind = [kind copy];
  _openPopoverFraction = [note.userInfo[@"fraction"] doubleValue];
  KKLogDebug(@"[LayerList] popover navigated: kind=%@ fraction=%.4f",
             _openPopoverKind, _openPopoverFraction);
  [self _refreshNonSelectableForOpenPopover];
}

- (void)_popoverDidClose:(NSNotification *)note {
  NSView *closingContent = note.userInfo[@"contentView"];
  if (closingContent && closingContent == _overlayContentView) {
    _overlayContentView = nil;
    _openPopoverKind = [_underlyingPopoverKind copy];
    _openPopoverFraction = _underlyingPopoverFraction;
    _underlyingPopoverKind = nil;
    [self _refreshNonSelectableForOpenPopover];
    return;
  }
  if (closingContent && _attachedContentView &&
      closingContent != _attachedContentView)
    return;
  _openGeneration++;
  _attachedContentView = nil;
  _overlayContentView = nil;
  _underlyingPopoverKind = nil;
  [_panelController hide];
}

@end
