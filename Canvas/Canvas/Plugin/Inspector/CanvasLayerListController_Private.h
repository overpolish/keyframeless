/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared internals of CanvasLayerListController, split across category files
// (+NonSelectable). Holds the ivars so the category can read the open-popover
// scope and the layer list, and declares the cross-file method surface.

#import "CanvasLayerListController.h"
#import "CanvasLayerListView.h"
#import <KeyframelessKit/KKCompanionPanelController.h>

NS_ASSUME_NONNULL_BEGIN

@interface CanvasLayerListController () {
@protected
  // The panel beside the popover (construction, placement, entrance): kit
  // scaffold, shared with Mirage's template browser. This class supplies the
  // content and everything the content means.
  KKCompanionPanelController *_panelController;
  __weak CanvasLayerListView *_listView;
  // The non-selectable set for the popover currently opening, handed to the
  // list the moment the panel is attached (the panel is built lazily, so the
  // set is derived before the view it applies to exists).
  NSSet<NSString *> *_pendingNonSelectable;
  __weak id<PROAPIAccessing> _apiManager;
  // Layer to highlight in the list (a keypose popover's active layer). Stored
  // so it survives the panel being created lazily AFTER the highlight is
  // requested.
  NSString *_highlightLayerID;
  // The FULL multi-selection to highlight (every selected row), stored so it
  // survives the lazily-built panel - the single _highlightLayerID is just its
  // primary. Empty = no rows highlighted (a real deselect).
  NSArray<NSString *> *_highlightLayerIDs;
  // The currently-open popover's kind + fraction, so a reload (e.g. a path
  // drawn while a keypose popover is open) can re-derive the non-selectable set
  // against the NEW layer stack - otherwise a freshly-added layer stays
  // selectable. Cleared on close.
  NSString *_openPopoverKind;
  double _openPopoverFraction;
  // The content surface the layer-list window is physically attached to.
  // A temporary option popover can open over a persistent editor; in that
  // case the list borrows the option's selection scope without reparenting its
  // NSPanel (ViewBridge raises if the same child window is reparented there).
  __weak NSView *_attachedContentView;
  __weak NSView *_overlayContentView;
  NSString *_underlyingPopoverKind;
  double _underlyingPopoverFraction;
  // Backs the public templateLaneCount property; declared here so the
  // +NonSelectable category can read it.
  NSUInteger _templateLaneCount;
  // Bumped by every open AND every close, so a panel build deferred out of the
  // notification turn can tell whether the popover it was for is still the one
  // on screen. Main-thread only.
  NSInteger _openGeneration;
}
@end

// Scope-gating analyzers: derive the set of layers a given popover kind can't
// act on (no keypose at the time, fully animated, move-lane animated, etc.) and
// push it onto the list / mini-viewer.
@interface CanvasLayerListController (NonSelectable)
- (nullable NSSet<NSString *> *)_nonSelectableForKind:(NSString *)kind
                                             fraction:(double)frac;
/// Tooltip explaining WHY a row is grayed for the given popover `kind`. nil for
/// kinds with no gating.
- (nullable NSString *)_nonSelectableReasonForKind:(NSString *)kind;
- (void)_refreshNonSelectableForOpenPopover;
- (NSSet<NSString *> *)_layersWithoutKeyposeAtFraction:(double)frac;
- (NSSet<NSString *> *)_layersWithoutAnimation;
- (NSSet<NSString *> *)_layersWithoutConstant;
- (NSSet<NSString *> *)_layersWithMoveLaneAnimated;
@end

NS_ASSUME_NONNULL_END
