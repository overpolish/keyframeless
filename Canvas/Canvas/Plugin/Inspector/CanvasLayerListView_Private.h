/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared internals of CanvasLayerListView, split across category files
// (+Rows, +Grouping, +DragDrop). Holds the ivars (so the categories can touch
// the cached state) and declares the cross-category method surface.

#import "CanvasLayerListView.h"

@class KKBezierPath;
@class KKCheckboxRowView;

NS_ASSUME_NONNULL_BEGIN

// Shared layout metrics.
static const CGFloat kRowHeight __attribute__((unused)) = 24.0;
// Leading identity glyph (folder / thumbnail / shape). Kept close to the eye /
// lock icon size so the rows read as a single aligned column.
static const CGFloat kLeadGlyphSize __attribute__((unused)) = 15.0;
static const CGFloat kSelectionAlpha __attribute__((unused)) = 0.15;
static const CGFloat kEdgeShadowHeight __attribute__((unused)) = 16.0;
// Pointer travel before a press on a row becomes a reorder drag.
static const CGFloat kRowDragThreshold __attribute__((unused)) = 3.0;
// Per-level indent for nested group members.
static const CGFloat kGroupIndent __attribute__((unused)) = 14.0;

// Internal pasteboard type for dragging rows to reorder (archived NSIndexSet).
extern NSPasteboardType const kCanvasLayerRowDragType;

// A row: drag source for reorder + click selection + double-click rename.
// (Implemented in +DragDrop; built by +Rows.)
@interface CanvasLayerRow : NSStackView <NSDraggingSource>
@property(nonatomic) NSInteger rowIndex;
@property(nonatomic, weak) CanvasLayerListView *owner;
@end

// Flipped document view that hosts the rows and is the drop target.
@interface CanvasLayerDocView : NSView
@property(nonatomic, weak) CanvasLayerListView *owner;
@end

// The class extension holds the ivars (so categories can touch the cached
// state) + the methods implemented in the primary @implementation (core).
@interface CanvasLayerListView () <NSTextFieldDelegate> {
@protected
  NSScrollView *_scroll;
  NSStackView *_rowsStack;
  NSStackView *_emptyStack;
  NSMutableIndexSet *_selection;
  // Layers that can't be selected right now: a keypose popover at time T grays
  // layers with no keypose at T (you can't edit a keypose they don't have).
  // Empty for the Constants popover (every layer selectable). Every OTHER
  // interaction (drag, visibility, lock, rename) stays live on grayed rows.
  NSSet<NSString *> *_nonSelectableLayerIDs;
  NSImageSymbolConfiguration *_symConfig;
  // Cached state so interactions stay snappy: avoid re-reading the param blob
  // and reloading thumbnails from disk on every click.
  NSMutableArray<KKBezierPath *> *_paths;
  NSMutableArray<NSView *> *_rowViews;
  NSMutableDictionary<NSString *, NSImage *> *_thumbCache;
  NSView *_topShadow;
  NSView *_bottomShadow;
  NSView *_listBorder;
  NSTextField *_hintLabel;
  KKCheckboxRowView *_autoSelectRow; // "Auto-select layers" toggle above list
  BOOL _autoSelectState;             // backs the row's live binding
  NSInteger _editingIndex;           // row being inline-renamed, or -1
  __weak NSTextField *_editingField;
  NSMutableSet<NSString *> *_collapsedGroups; // UI-only collapsed group IDs
  id _keyMonitor;                             // local keyDown monitor
  NSInteger _selfWritePending; // skip our own writes echoing back as reloads
}

// Layer blob IO + cache mutation, scroll shadows, rename (primary impl).
- (void)_modifyPaths:(void (^)(NSMutableArray<KKBezierPath *> *paths))block;
- (nullable KKBezierPath *)_imageLayerForURL:(NSURL *)url;
- (nullable NSImage *)_thumbnailForPath:(NSString *)imagePath;
- (void)_updateScrollShadows;
- (void)beginRenameAtIndex:(NSUInteger)idx;
- (void)commitRenameIfEditing;
- (void)_commitRenameIfEditing;
- (void)renameRow:(NSMenuItem *)sender; // menu/button action target
@end

// Methods are declared on matching CATEGORY interfaces (not the extension) so
// the compiler doesn't expect them in the primary @implementation.

@interface CanvasLayerListView (Rows)
- (void)_rebuildRows;
- (void)_applySelectionStyling;
- (BOOL)_rowNonSelectable:(NSInteger)rowIndex;
- (NSView *)_rowViewForPath:(KKBezierPath *)path
                      index:(NSUInteger)idx
                   selected:(BOOL)selected;
- (NSMenu *)_contextMenuForIndex:(NSUInteger)idx;
- (NSIndexSet *)_actionTargetsForTag:(NSUInteger)tag;
- (BOOL)isRowSelected:(NSUInteger)idx;
- (void)selectIndex:(NSUInteger)idx
          modifiers:(NSEventModifierFlags)mods
         clickCount:(NSInteger)clicks;
// Fire onPrimaryLayerSelected for the current selection's first index. Used by
// selection paths that set _selection directly (drop / reorder) rather than
// through selectIndex:, so the inspector swaps its per-layer state to match.
- (void)_notifyPrimaryLayerSelected;
@end

@interface CanvasLayerListView (Grouping)
- (BOOL)isRowLocked:(NSUInteger)idx;
- (BOOL)_isRowHiddenByCollapse:(NSUInteger)idx;
- (NSInteger)_indexOfGroupID:(NSString *)gid;
- (NSInteger)subtreeEndFlatIndex:(NSUInteger)idx;
- (NSInteger)depthOfParentGroupID:(nullable NSString *)gid;
- (NSIndexSet *)_targetsWithDescendantsForTag:(NSUInteger)tag
                                        paths:(NSArray<KKBezierPath *> *)paths;
// Action targets for the row buttons / context menu (referenced via @selector
// from +Rows when building the row + menu).
- (void)toggleCollapse:(NSButton *)sender;
- (void)toggleVisibility:(NSButton *)sender;
- (void)toggleLock:(NSButton *)sender;
- (void)duplicateRow:(NSMenuItem *)sender;
- (void)deleteRow:(NSMenuItem *)sender;
- (void)groupSelection:(NSMenuItem *)sender;
- (void)ungroupRow:(NSMenuItem *)sender;
- (void)removeFromGroup:(NSMenuItem *)sender;
// Group the current selection (Cmd-G); _groupTargetsForTag: is the shared core.
- (void)groupSelectedRows;
- (void)_groupTargetsForTag:(NSUInteger)tag;
@end

@interface CanvasLayerListView (DragDrop)
@property(nonatomic, readonly) NSArray<NSView *> *orderedRowViews;
- (NSIndexSet *)dragIndicesForRow:(NSUInteger)idx;
- (NSString *_Nullable)_resolveDropParent:(nullable NSString *)parent
                                 dragging:(nullable NSIndexSet *)dragged;
- (void)performRowReorderFromIndices:(NSIndexSet *)indices
                         toFlatIndex:(NSInteger)dropIdx
                       parentGroupID:(nullable NSString *)parentGID;
- (NSArray<NSURL *> *)imageURLsFromDraggingInfo:(id<NSDraggingInfo>)info;
- (void)insertImageURLs:(NSArray<NSURL *> *)urls
            atFlatIndex:(NSInteger)idx
          parentGroupID:(nullable NSString *)parentGID;
- (BOOL)computeDropForDocPoint:(NSPoint)p
                      dragging:(nullable NSIndexSet *)dragged
                  outFlatIndex:(NSInteger *)outFlat
                     outParent:(NSString *_Nullable *_Nullable)outParent
                      outLineY:(CGFloat *)outY
                 outLineIndent:(CGFloat *)outIndent;
@end

NS_ASSUME_NONNULL_END
