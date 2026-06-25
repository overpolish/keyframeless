/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared internals of CanvasLayerListController, split across category files
// (+NonSelectable). Holds the ivars so the category can read the open-popover
// scope and the layer list, and declares the cross-file method surface.

#import "CanvasLayerListController.h"
#import "CanvasLayerListView.h"

NS_ASSUME_NONNULL_BEGIN

@interface CanvasLayerListController () {
@protected
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
  // The currently-open popover's kind + fraction, so a reload (e.g. a path drawn
  // while a keypose popover is open) can re-derive the non-selectable set
  // against the NEW layer stack - otherwise a freshly-added layer stays
  // selectable. Cleared on close.
  NSString *_openPopoverKind;
  double _openPopoverFraction;
  // Backs the public templateLaneCount property; declared here so the
  // +NonSelectable category can read it.
  NSUInteger _templateLaneCount;
}
@end

// Scope-gating analyzers: derive the set of layers a given popover kind can't
// act on (no keypose at the time, fully animated, move-lane animated, etc.) and
// push it onto the list / mini-viewer.
@interface CanvasLayerListController (NonSelectable)
- (nullable NSSet<NSString *> *)_nonSelectableForKind:(NSString *)kind
                                             fraction:(double)frac;
- (void)_refreshNonSelectableForOpenPopover;
- (NSSet<NSString *> *)_layersWithoutKeyposeAtFraction:(double)frac;
- (NSSet<NSString *> *)_layersWithoutAnimation;
- (NSSet<NSString *> *)_layersWithoutConstant;
- (NSSet<NSString *> *)_layersWithMoveLaneAnimated;
@end

NS_ASSUME_NONNULL_END
