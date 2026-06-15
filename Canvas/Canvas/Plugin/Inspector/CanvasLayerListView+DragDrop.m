/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Drag/drop + reorder for the Layers panel: the draggable row, the drop-target
// document view, and the owner-side drop computation / reorder / image insert.

#import "CanvasLayerListView_Private.h"

#import "CanvasLayerRowViews.h"
#import "CanvasLayerTree.h"

#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

NSPasteboardType const kCanvasLayerRowDragType =
    @"co.overpolish.keyframeless.canvas.layerrows";

#pragma mark - Draggable row

// A row is the drag source for reorder. It also owns click selection + the
// double-click-to-rename gesture (so the whole row body is grabbable).
@implementation CanvasLayerRow {
  NSPoint _downPoint;
  BOOL _dragging;
  BOOL _deferSelect; // clicked an already-selected row: collapse on mouse-up
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}
- (void)mouseDown:(NSEvent *)event {
  _dragging = NO;
  _deferSelect = NO;
  _downPoint = event.locationInWindow;
  NSUInteger idx = (NSUInteger)self.rowIndex;
  if (event.clickCount >= 2) {
    [self.owner beginRenameAtIndex:idx];
    return;
  }
  NSEventModifierFlags mods = event.modifierFlags;
  if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagShift)) {
    [self.owner selectIndex:idx modifiers:mods clickCount:1];
  } else if (![self.owner isRowSelected:idx]) {
    [self.owner selectIndex:idx modifiers:0 clickCount:1];
  } else {
    // Already selected with no modifier: keep the (possibly multi-) selection
    // so it can be dragged; collapse to just this row on mouse-up if no drag.
    _deferSelect = YES;
  }
}
- (void)mouseDragged:(NSEvent *)event {
  if (_dragging)
    return;
  NSPoint p = event.locationInWindow;
  if (hypot(p.x - _downPoint.x, p.y - _downPoint.y) < kRowDragThreshold)
    return;
  NSIndexSet *indices =
      [self.owner dragIndicesForRow:(NSUInteger)self.rowIndex];
  if (indices.count == 0)
    return; // nothing draggable (e.g. the row is locked)
  _dragging = YES;
  _deferSelect = NO;
  [self.owner commitRenameIfEditing];
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:indices
                                       requiringSecureCoding:YES
                                                       error:nil];
  if (!data)
    return;
  NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
  [item setData:data forType:kCanvasLayerRowDragType];
  NSDraggingItem *di = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
  [di setDraggingFrame:self.bounds contents:[self _snapshot]];
  [self beginDraggingSessionWithItems:@[ di ] event:event source:self];
}
- (void)mouseUp:(NSEvent *)event {
  if (_deferSelect && !_dragging)
    [self.owner selectIndex:(NSUInteger)self.rowIndex modifiers:0 clickCount:1];
  _deferSelect = NO;
}
- (NSImage *)_snapshot {
  NSBitmapImageRep *rep =
      [self bitmapImageRepForCachingDisplayInRect:self.bounds];
  [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
  NSImage *img = [[NSImage alloc] initWithSize:self.bounds.size];
  [img addRepresentation:rep];
  return img;
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return NSDragOperationMove;
}
@end

#pragma mark - Drop-target document view

// Flipped so rows stack top-to-bottom. Also the drop target for row reorder
// (shows the drop line + commits the move).
@implementation CanvasLayerDocView {
  NSView *_dropLine;
  NSInteger _dropIndex;
  NSString *_dropParent;
}
- (BOOL)isFlipped {
  return YES;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _dropIndex = -1;
    // Reorder (row type) AND new image files: both show the drop line and
    // insert at the indicated position.
    [self registerForDraggedTypes:@[
      kCanvasLayerRowDragType, NSPasteboardTypeFileURL
    ]];
  }
  return self;
}
- (NSView *)_dropLineView {
  if (!_dropLine) {
    _dropLine = [[NSView alloc] initWithFrame:NSZeroRect];
    _dropLine.wantsLayer = YES;
    _dropLine.layer.backgroundColor = [NSColor accent].CGColor;
    _dropLine.layer.cornerRadius = 1.0;
    _dropLine.hidden = YES;
    [self addSubview:_dropLine];
  }
  return _dropLine;
}
- (NSIndexSet *)_draggedRowsFrom:(id<NSDraggingInfo>)sender {
  NSData *data =
      [sender.draggingPasteboard dataForType:kCanvasLayerRowDragType];
  if (!data)
    return nil;
  return [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                           fromData:data
                                              error:nil];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return [self draggingUpdated:sender];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  NSIndexSet *dragged = [self _draggedRowsFrom:sender];
  BOOL isRow = dragged != nil;
  BOOL isFiles =
      !isRow && [self.owner imageURLsFromDraggingInfo:sender].count > 0;
  if (!isRow && !isFiles) {
    _dropLine.hidden = YES;
    _dropIndex = -1;
    return NSDragOperationNone;
  }
  NSPoint p = [self convertPoint:sender.draggingLocation fromView:nil];
  CGFloat y = 0, indent = 0;
  NSString *parent = nil;
  [self.owner computeDropForDocPoint:p
                            dragging:dragged
                        outFlatIndex:&_dropIndex
                           outParent:&parent
                            outLineY:&y
                       outLineIndent:&indent];
  _dropParent = parent;
  NSView *line = [self _dropLineView];
  line.frame =
      NSMakeRect(indent + KKPaddingMD, y - 1.0,
                 self.bounds.size.width - indent - 2 * KKPaddingMD, 2.0);
  line.hidden = NO;
  [self addSubview:line positioned:NSWindowAbove relativeTo:nil];
  return isRow ? NSDragOperationMove : NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)sender {
  _dropLine.hidden = YES;
  _dropIndex = -1;
}
- (void)draggingEnded:(id<NSDraggingInfo>)sender {
  _dropLine.hidden = YES;
}
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
  return YES;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  _dropLine.hidden = YES;
  if (_dropIndex < 0)
    return NO;
  NSIndexSet *indices = [self _draggedRowsFrom:sender];
  if (indices) {
    [self.owner performRowReorderFromIndices:indices
                                 toFlatIndex:_dropIndex
                               parentGroupID:_dropParent];
    _dropIndex = -1;
    return YES;
  }
  NSArray<NSURL *> *urls = [self.owner imageURLsFromDraggingInfo:sender];
  if (urls.count == 0)
    return NO;
  [self.owner insertImageURLs:urls
                  atFlatIndex:_dropIndex
                parentGroupID:_dropParent];
  _dropIndex = -1;
  return YES;
}
@end

#pragma mark - Owner: drop computation / reorder / image insert

@implementation CanvasLayerListView (DragDrop)

- (NSArray<NSView *> *)orderedRowViews {
  return [_rowViews copy];
}

- (NSIndexSet *)dragIndicesForRow:(NSUInteger)idx {
  NSIndexSet *base = (_selection.count > 0 && [_selection containsIndex:idx])
                         ? _selection
                         : [NSIndexSet indexSetWithIndex:idx];
  // Locked layers can't be reordered - drop them from the dragged set.
  NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
  [base enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    if (i < _paths.count && !_paths[i].locked)
      [out addIndex:i];
  }];
  return out;
}

// A drop must not land inside a group that's being dragged (its own subtree):
// walk the target parent chain up to the first group not in `dragged`.
- (NSString *)_resolveDropParent:(NSString *)parent
                        dragging:(NSIndexSet *)dragged {
  if (parent.length == 0 || dragged.count == 0)
    return parent;
  NSString *gid = parent;
  NSUInteger guard = 0;
  while (gid.length > 0 && guard++ < CanvasLayerGroupDepthGuard) {
    NSInteger gIdx = [self _indexOfGroupID:gid];
    if (gIdx < 0)
      break;
    if ([dragged containsIndex:(NSUInteger)gIdx]) {
      parent = _paths[(NSUInteger)gIdx].parentGroupID;
      gid = parent;
      continue;
    }
    gid = _paths[(NSUInteger)gIdx].parentGroupID;
  }
  return parent;
}

- (BOOL)computeDropForDocPoint:(NSPoint)p
                      dragging:(NSIndexSet *)dragged
                  outFlatIndex:(NSInteger *)outFlat
                     outParent:(NSString *_Nullable *_Nullable)outParent
                      outLineY:(CGFloat *)outY
                 outLineIndent:(CGFloat *)outIndent {
  NSView *doc = _scroll.documentView;
  NSArray<CanvasLayerRow *> *rows =
      (NSArray<CanvasLayerRow *> *)self.orderedRowViews;
  NSInteger flat = (NSInteger)_paths.count;
  NSString *parent = nil;
  CGFloat lineY = 0;

  if (rows.count == 0) {
    flat = 0;
  } else {
    NSInteger hover = -1;
    BOOL topHalf = NO;
    for (NSUInteger i = 0; i < rows.count; i++) {
      NSRect fr = [rows[i] convertRect:rows[i].bounds toView:doc];
      if (p.y < NSMaxY(fr)) {
        hover = (NSInteger)i;
        topHalf = p.y < NSMidY(fr);
        break;
      }
    }
    if (hover < 0) {
      // Below all visible rows: append after the last row's subtree, top level.
      CanvasLayerRow *last = rows.lastObject;
      flat = [self subtreeEndFlatIndex:(NSUInteger)last.rowIndex];
      parent = _paths[(NSUInteger)last.rowIndex].parentGroupID;
      NSRect fr = [last convertRect:last.bounds toView:doc];
      lineY = NSMaxY(fr);
    } else {
      CanvasLayerRow *hr = rows[(NSUInteger)hover];
      NSUInteger hidx = (NSUInteger)hr.rowIndex;
      KKBezierPath *hp = _paths[hidx];
      NSRect fr = [hr convertRect:hr.bounds toView:doc];
      if (topHalf) {
        flat = (NSInteger)hidx;
        parent = hp.parentGroupID;
        lineY = NSMinY(fr);
      } else if (hp.isGroup &&
                 ![_collapsedGroups containsObject:hp.groupID ?: @""]) {
        // Bottom half of an expanded group: drop in as its first child.
        parent = hp.groupID;
        flat = (NSInteger)hidx + 1;
        lineY = NSMaxY(fr);
      } else {
        // Bottom half: after this entry's subtree, at its level.
        flat = [self subtreeEndFlatIndex:hidx];
        parent = hp.parentGroupID;
        lineY = NSMaxY(fr);
      }
    }
  }

  parent = [self _resolveDropParent:parent dragging:dragged];
  if (outFlat)
    *outFlat = flat;
  if (outParent)
    *outParent = parent;
  if (outY)
    *outY = lineY;
  if (outIndent)
    *outIndent = [self depthOfParentGroupID:parent] * kGroupIndent;
  return YES;
}

// Move the dragged rows (and any dragged group's descendants) to flat index
// `dropIdx`, reparenting the dragged roots to `parentGID`. Subtrees stay
// intact.
- (void)performRowReorderFromIndices:(NSIndexSet *)indices
                         toFlatIndex:(NSInteger)dropIdx
                       parentGroupID:(NSString *)parentGID {
  if (indices.count == 0)
    return;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    // Expand to include descendants of any dragged group.
    NSMutableIndexSet *expanded = [NSMutableIndexSet indexSet];
    [indices enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      if (i >= paths.count)
        return;
      [expanded addIndex:i];
      if (paths[i].isGroup)
        [expanded addIndexes:CanvasLayerDescendantIndices(i, paths)];
    }];
    if (expanded.count == 0)
      return;
    NSArray<KKBezierPath *> *moving = [paths objectsAtIndexes:expanded];
    // The groupIDs being moved - their members keep their (internal) parent.
    NSMutableSet<NSString *> *movingGroupIDs = [NSMutableSet set];
    for (KKBezierPath *m in moving)
      if (m.isGroup && m.groupID.length)
        [movingGroupIDs addObject:m.groupID];
    // Reparent only the roots of the dragged forest to the drop target.
    for (KKBezierPath *m in moving) {
      BOOL nestedInMoved = m.parentGroupID.length &&
                           [movingGroupIDs containsObject:m.parentGroupID];
      if (!nestedInMoved)
        m.parentGroupID = parentGID.length ? parentGID : nil;
    }
    NSInteger clamped = MAX((NSInteger)0, MIN(dropIdx, (NSInteger)paths.count));
    NSUInteger removedBefore =
        [expanded countOfIndexesInRange:NSMakeRange(0, (NSUInteger)clamped)];
    NSUInteger target = (NSUInteger)clamped - removedBefore;
    [paths removeObjectsAtIndexes:expanded];
    if (target > paths.count)
      target = paths.count;
    NSIndexSet *insertAt = [NSIndexSet
        indexSetWithIndexesInRange:NSMakeRange(target, moving.count)];
    [paths insertObjects:moving atIndexes:insertAt];
    [self->_selection removeAllIndexes];
    [self->_selection addIndexes:insertAt];
  }];
}

// Image file drops are handled by the doc view (so they show the drop line and
// insert at the indicated position); these helpers do the work it calls back.
- (NSArray<NSURL *> *)imageURLsFromDraggingInfo:(id<NSDraggingInfo>)info {
  NSArray<NSURL *> *urls = [info.draggingPasteboard
      readObjectsForClasses:@[ [NSURL class] ]
                    options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
  NSMutableArray<NSURL *> *images = [NSMutableArray array];
  for (NSURL *url in urls)
    if ([CanvasLayerImageExtensions()
            containsObject:url.pathExtension.lowercaseString])
      [images addObject:url];
  return images;
}

- (void)insertImageURLs:(NSArray<NSURL *> *)urls
            atFlatIndex:(NSInteger)idx
          parentGroupID:(NSString *)parentGID {
  if (urls.count == 0)
    return;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSInteger clamped = MAX((NSInteger)0, MIN(idx, (NSInteger)paths.count));
    NSUInteger pos = (NSUInteger)clamped;
    NSMutableIndexSet *newSel = [NSMutableIndexSet indexSet];
    for (NSURL *url in urls) {
      KKBezierPath *layer = [self _imageLayerForURL:url];
      if (layer) {
        layer.parentGroupID = parentGID.length ? parentGID : nil;
        [paths insertObject:layer atIndex:pos];
        [newSel addIndex:pos];
        pos++;
      }
    }
    [self->_selection removeAllIndexes];
    [self->_selection addIndexes:newSel];
  }];
}

@end
