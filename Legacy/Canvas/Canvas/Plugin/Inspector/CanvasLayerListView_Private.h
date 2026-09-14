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
  id _renameClickMon; // local mouse-down monitor: blur rename on outside click
  // Mouse-moved monitors for the row-hover highlight. Tracking areas are
  // unreliable in the inspector's ViewBridge process (need a key window, and
  // a row rebuild on selection destroys them without firing exit), so hit-test
  // live row frames on every move instead. Local fires when the view-service
  // window is key; global fires when the host (FCP) has focus.
  id _hoverMonitorLocal;
  id _hoverMonitorGlobal;
  NSInteger _hoveredRowIndex; // last row reported to onLayerHovered (-1 = none)
  NSInteger _selfWritePending; // skip our own writes echoing back as reloads
}

// Scroll shadows (primary impl).
- (void)_updateScrollShadows;
// Row-hover hit-test driven by the mouse-moved monitors (primary impl).
- (void)_updateHoverFromMouse;
// Wrap a multi-write mutation (blob + selection) in ONE host undo group so a
// single cmd-Z reverts the whole thing - without it the blob write and the
// follow-up selection write land as two separate undo steps. Used by every
// keyboard / menu structural edit (delete, duplicate, group, move).
- (void)_runInUndoGroup:(NSString *)name block:(void (^)(void))block;
// Keyboard structural edits on the current selection (primary impl): duplicate
// (Cmd-D) and reorder the primary row among its siblings (Cmd-] / Cmd-[;
// delta -1 = forward / toward the front, +1 = backward).
- (void)_duplicateSelectedRows;
- (void)_moveSelectedRowByOffset:(NSInteger)delta;
// Move the selection to the adjacent selectable, non-collapsed row (Up / Down
// arrows; delta -1 = up / toward the front, +1 = down). No reorder.
- (void)_moveSelectionByOffset:(NSInteger)delta;
@end

// Methods are declared on matching CATEGORY interfaces (not the extension) so
// the compiler doesn't expect them in the primary @implementation.

// Layer blob IO (KKBezierPath <-> kParamLayerData string) + cache mutation +
// image / SVG import.
@interface CanvasLayerListView (IO)
- (NSMutableArray<KKBezierPath *> *)_readPaths;
- (void)_writePaths:(NSArray<KKBezierPath *> *)paths;
- (void)_modifyPaths:(void (^)(NSMutableArray<KKBezierPath *> *paths))block;
- (nullable KKBezierPath *)_imageLayerForURL:(NSURL *)url;
// Parse an SVG file into ready-to-insert layers in top-to-bottom flat order:
// index 0 is the root (a group when the SVG has several elements, else the
// single path) with a nil parent; any following entries are the group's
// children. Empty when the file can't be read / parsed.
- (NSArray<KKBezierPath *> *)_svgLayersForURL:(NSURL *)url;
- (nullable NSImage *)_thumbnailForPath:(NSString *)imagePath;
@end

// Inline-rename lifecycle: begin / commit, the field's end-of-edit delegate,
// and the context-menu rename action target.
@interface CanvasLayerListView (Rename)
- (void)beginRenameAtIndex:(NSUInteger)idx;
- (void)commitRenameIfEditing;
- (void)_beginRenameAtIndex:(NSUInteger)idx;
- (void)_commitRename;
- (void)_commitRenameIfEditing;
- (void)_resetCursorAfterEditing;
- (void)renameRow:(NSMenuItem *)sender; // menu/button action target
@end

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
// Row tracking-area enter (its index) / exit (-1); resolves the layerID and
// fires onLayerHovered for the mini-viewer's transient hover highlight.
- (void)hoverRowAtIndex:(NSInteger)rowIndex;
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
// Shared duplicate core (menu tag + keyboard both route here): clone the action
// targets for `tag` and select the clones. Wrapped in a single undo group.
- (void)_duplicateTargetsForTag:(NSUInteger)tag;
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
// Importable files in a drag: image (raster) + SVG (vector) URLs.
- (NSArray<NSURL *> *)importableURLsFromDraggingInfo:(id<NSDraggingInfo>)info;
- (void)insertFileURLs:(NSArray<NSURL *> *)urls
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
