/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// The layer stack is a flat array that encodes a tree: a group is a
/// `KKBezierPath` with `isGroup == YES` and a `groupID`; its members carry that
/// id in `parentGroupID` and sit contiguously right after it. These helpers
/// walk that structure by the parentGroupID chain (independent of array order).

/// Guard against a malformed parentGroupID cycle when walking the tree.
static const NSUInteger CanvasLayerGroupDepthGuard __attribute__((unused)) = 32;

/// All entries nested under the group at `groupIdx` (children + deeper).
extern NSIndexSet *CanvasLayerDescendantIndices(NSUInteger groupIdx,
                                                NSArray<KKBezierPath *> *paths);

/// Indices of the group(s) the entry at `idx` is nested in, innermost first.
extern NSIndexSet *CanvasLayerAncestorIndices(NSUInteger idx,
                                              NSArray<KKBezierPath *> *paths);

/// Remove the layers whose layerID is in `selIDs` (expanding any selected group
/// to its descendants) from `paths` IN PLACE, mirroring the layer-list Delete.
/// Returns the layerID that should be selected afterwards (the layer that fell
/// into the first removed slot, or the new last layer), or nil when the stack is
/// now empty / nothing matched. Shared by the canvas + mini Delete handlers so
/// they delete a selection exactly like the panel does.
extern NSString *_Nullable CanvasDeleteLayersByID(
    NSMutableArray<KKBezierPath *> *paths, NSArray<NSString *> *selIDs);

NS_ASSUME_NONNULL_END
