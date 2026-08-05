/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MirageShaderRackView.h"

#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

@class MirageShaderRackView;

/// Box height and the width the arrow between two boxes occupies. Shared with
/// the +DragDrop category's drop-line maths.
FOUNDATION_EXPORT const CGFloat kMirageRackBoxHeight;
FOUNDATION_EXPORT const CGFloat kMirageRackConnectorWidth;
/// Pointer travel before a press on a box becomes a reorder drag.
FOUNDATION_EXPORT const CGFloat kMirageRackDragThreshold;
/// Pasteboard type carrying the dragged box's index.
FOUNDATION_EXPORT NSPasteboardType const kMirageRackBoxDragType;

/// One box. A stack view rather than a plain view so the columns lay themselves
/// out, and the drag source for reorder (the whole box body is grabbable - the
/// glyph and the name label are passthrough on purpose).
@interface MirageRackBox : NSStackView <NSDraggingSource>
@property(nonatomic, weak) MirageShaderRackView *owner;
@property(nonatomic) NSInteger boxIndex;
@end

/// The arrow between two boxes: an `arrow.right` symbol, centred in a view
/// whose height IS the box height, so it lines up with the boxes it joins
/// rather than with the strip's padded band. Faded when the box FEEDING it is
/// disabled, so a bypassed shader reads as a weakened link in the pipeline
/// rather than as a greyed label you have to go looking for.
@interface MirageRackConnectorView : NSImageView
@property(nonatomic) BOOL dimmed;
@end

/// The scroll view's document view: the drop target that draws the vertical
/// insertion line between two boxes.
@interface MirageRackDocView : NSView
@property(nonatomic, weak) MirageShaderRackView *owner;
@end

@interface MirageShaderRackView () {
@package
  NSScrollView *_scroll;
  MirageRackDocView *_doc;
  NSStackView *_chain;
  NSMutableArray<MirageRackBox *> *_boxViews;
  NSArray<MirageRackEntry *> *_entries;
  NSString *_selectedEntryID;
  MirageRackPreviewMode _previewMode;
  NSString *_previewEntryID;
  NSSet<NSString *> *_nonSelectableEntryIDs;
  NSString *_nonSelectableReason;
  NSButton *_addButton;
  NSImageSymbolConfiguration *_symConfig;
  NSView *_leadingShadow;
  NSView *_trailingShadow;
  CAGradientLayer *_leadingGrad;
  CAGradientLayer *_trailingGrad;
  /// The measured-slowness glyph, pinned to the strip's trailing edge OUTSIDE
  /// the scrolling region, and the scroller's trailing constraint it makes room
  /// in. Hidden, it costs nothing: the constant goes back and the boxes get the
  /// width again.
}
@end

/// Called across the class/category split.
@interface MirageShaderRackView (Internal)
/// Tear the chain down and build it again from `_entries`. The whole strip,
/// selection included - see the note on the implementation for why there is no
/// styling-only path. Implemented in +Boxes.m.
- (void)rebuildBoxes;
/// The "+" at the end of the chain. Built with the rail (the button outlives
/// any one rebuild), wired to the box model that owns every other action.
- (void)addTapped:(NSButton *)sender;
/// Track the edge fades to what there currently is to scroll to. Implemented
/// in the base file; called from +Boxes.m after a rebuild changes the document
/// width. Implemented in MirageShaderRackView.m.
- (void)updateEdgeShadows;
- (void)selectBoxAtIndex:(NSInteger)index;
- (BOOL)isBoxSelected:(NSInteger)index;
/// NO while a keypose popover is open on a time this entry has no keypose at.
- (BOOL)isBoxSelectable:(NSInteger)index;
- (NSArray<MirageRackBox *> *)orderedBoxViews;
/// The index the drop line points at, in FINAL order, plus where to draw it.
- (void)computeDropForDocPoint:(NSPoint)point
                  outFlatIndex:(NSInteger *)outFlatIndex
                      outLineX:(CGFloat *)outLineX;
- (void)performBoxMoveFromIndex:(NSInteger)fromIndex
                    toFlatIndex:(NSInteger)toIndex;
@end

NS_ASSUME_NONNULL_END
