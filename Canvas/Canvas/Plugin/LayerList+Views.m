/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "LayerList_Private.h"

@implementation KKLayerListContainer
@end

@implementation KKLayerRow

- (NSImage *)snapshot {
  NSBitmapImageRep *rep =
      [self bitmapImageRepForCachingDisplayInRect:self.bounds];
  [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
  NSImage *img = [[NSImage alloc] initWithSize:self.bounds.size];
  [img addRepresentation:rep];
  return img;
}

@end

@implementation KKEditableLabel

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (self.currentEditor) {
    [self.currentEditor keyDown:event];
    return YES;
  }
  return [super performKeyEquivalent:event];
}

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    NSTextView *editor = (NSTextView *)self.currentEditor;
    NSColor *accent = [NSColor accent];
    editor.insertionPointColor = accent;
    editor.selectedTextAttributes = @{
      NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
      NSForegroundColorAttributeName : [NSColor labelColor],
    };
  }
  return ok;
}

@end

@implementation KKLayerButton {
  NSPoint _mouseDownPoint;
  BOOL _didDrag;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return NSDragOperationEvery;
}

- (void)mouseDown:(NSEvent *)event {
  _mouseDownPoint = [self convertPoint:event.locationInWindow fromView:nil];
  _didDrag = NO;
  [self highlight:YES];
}

- (void)mouseDragged:(NSEvent *)event {
  if (_didDrag)
    return;
  NSPoint current = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat dist =
      hypot(current.x - _mouseDownPoint.x, current.y - _mouseDownPoint.y);
  if (dist < 3.0)
    return;
  _didDrag = YES;
  [self highlight:NO];

  KKLayerRow *row = self.parentRow;
  if (!row)
    return;

  KKLayerActionTarget *at = (KKLayerActionTarget *)self.target;
  KKLayerInstanceState *state = KKLayerStateForUUID(at.instanceUUID);

  BOOL optionHeld = (event.modifierFlags & NSEventModifierFlagOption) != 0;
  NSIndexSet *dragIndices = state.uiSelection;
  if (!dragIndices || dragIndices.count == 0 ||
      ![dragIndices containsIndex:row.rowIndex])
    dragIndices = [NSIndexSet indexSetWithIndex:row.rowIndex];

  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dragIndices
                                       requiringSecureCoding:YES
                                                       error:nil];
  NSString *dragType = optionHeld ? kLayerDuplicateDragType : kLayerDragType;
  NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
  [pbItem setData:data forType:dragType];

  NSDraggingItem *dragItem =
      [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];
  [dragItem setDraggingFrame:row.bounds contents:[row snapshot]];

  state.isDragging = YES;
  [row beginDraggingSessionWithItems:@[ dragItem ] event:event source:self];
}

- (void)mouseUp:(NSEvent *)event {
  [self highlight:NO];
  if (_didDrag)
    return;
  if (event.clickCount >= 2) {
    KKLayerRow *row = self.parentRow;
    if (row) {
      KKLayerActionTarget *renameAt = (KKLayerActionTarget *)self.target;
      NSMenuItem *fake = [[NSMenuItem alloc] init];
      fake.tag = row.rowIndex;
      [renameAt renameRow:fake];
    }
  } else {
    [self performClick:self];
  }
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
  KKLayerActionTarget *endAt = (KKLayerActionTarget *)self.target;
  KKLayerInstanceState *endState = KKLayerStateForUUID(endAt.instanceUUID);
  endState.isDragging = NO;
  endState.forceRefresh = YES;
}

@end

@implementation KKLayerContentView {
  NSView *_dropIndicator;
}

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.dropFlatIndex = -1;
    [self registerForDraggedTypes:@[ kLayerDragType, kLayerDuplicateDragType ]];
  }
  return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return [self _isDuplicateDrag:sender] ? NSDragOperationCopy
                                        : NSDragOperationMove;
}

- (NSArray<KKLayerRow *> *)_sortedVisibleRows {
  NSMutableArray<KKLayerRow *> *rows = [NSMutableArray array];
  for (NSView *v in self.subviews) {
    if ([v isKindOfClass:[KKLayerRow class]] && !v.hidden)
      [rows addObject:(KKLayerRow *)v];
  }
  [rows sortUsingComparator:^NSComparisonResult(KKLayerRow *a, KKLayerRow *b) {
    return a.rowIndex < b.rowIndex ? NSOrderedAscending : NSOrderedDescending;
  }];
  return rows;
}

- (NSIndexSet *)_dragIndicesFromPasteboard:(id<NSDraggingInfo>)sender {
  NSData *data = [sender.draggingPasteboard dataForType:kLayerDragType];
  if (!data)
    data = [sender.draggingPasteboard dataForType:kLayerDuplicateDragType];
  if (!data)
    return nil;
  return [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                           fromData:data
                                              error:nil];
}

- (BOOL)_isDuplicateDrag:(id<NSDraggingInfo>)sender {
  return [sender.draggingPasteboard dataForType:kLayerDuplicateDragType] != nil;
}

- (NSString *)_resolveParentGID:(NSString *)parentGID
                    dragIndices:(NSIndexSet *)dragIndices
                           rows:(NSArray<KKLayerRow *> *)rows {
  if (!parentGID || !dragIndices)
    return parentGID;
  NSString *checkGID = parentGID;
  NSUInteger guard = 0;
  while (checkGID && guard < kGroupDepthGuard) {
    guard++;
    BOOL found = NO;
    for (KKLayerRow *r in rows) {
      if (r.groupID && [r.groupID isEqualToString:checkGID]) {
        if ([dragIndices containsIndex:r.rowIndex])
          return r.parentGroupID;
        checkGID = r.parentGroupID;
        found = YES;
        break;
      }
    }
    if (!found)
      break;
  }
  return parentGID;
}

- (NSUInteger)_depthForParentGID:(NSString *)parentGID
                            rows:(NSArray<KKLayerRow *> *)rows {
  NSUInteger depth = 0;
  NSString *pid = parentGID;
  while (pid && depth < kGroupDepthGuard) {
    depth++;
    NSString *nextPid = nil;
    for (KKLayerRow *r in rows) {
      if ([r.groupID isEqualToString:pid]) {
        nextPid = r.parentGroupID;
        break;
      }
    }
    pid = nextPid;
  }
  return depth;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  NSPoint loc = [self convertPoint:sender.draggingLocation fromView:nil];
  NSArray<KKLayerRow *> *rows = [self _sortedVisibleRows];
  NSIndexSet *dragIndices = [self _dragIndicesFromPasteboard:sender];

  CGFloat rowY = loc.y - kLayerListVerticalPad;
  CGFloat fractional = rowY / kLayerRowStride;
  NSInteger hoverIdx = (NSInteger)fractional;
  BOOL inTopHalf = (fractional - floor(fractional)) < 0.5;
  BOOL belowAllRows = hoverIdx >= (NSInteger)rows.count;
  hoverIdx = MAX(0, MIN(hoverIdx, (NSInteger)rows.count - 1));

  NSInteger visIdx =
      (NSInteger)round((loc.y - kLayerListVerticalPad) / kLayerRowStride);
  visIdx = MAX(0, MIN(visIdx, (NSInteger)rows.count));

  KKLayerRow *hoverRow = (rows.count > 0) ? rows[(NSUInteger)hoverIdx] : nil;

  NSInteger flatIdx = 0;
  NSString *parentGID = nil;

  if (belowAllRows && rows.count > 0) {
    flatIdx = (NSInteger)rows.lastObject.rowIndex + 1;
    parentGID = nil;
  } else if (hoverRow) {
    flatIdx = inTopHalf ? (NSInteger)hoverRow.rowIndex
                        : (NSInteger)hoverRow.rowIndex + 1;
    if (hoverRow.groupID && !inTopHalf)
      parentGID = hoverRow.groupID;
    else
      parentGID = hoverRow.parentGroupID;

    parentGID = [self _resolveParentGID:parentGID
                            dragIndices:dragIndices
                                   rows:rows];
  }

  CGFloat indent =
      [self _depthForParentGID:parentGID rows:rows] * kLayerGroupIndent;

  if (flatIdx != self.dropFlatIndex || fabs(indent - self.dropIndent) > 0.5) {
    self.dropFlatIndex = flatIdx;
    self.dropIndent = indent;
    self.dropParentGroupID = parentGID;
    [self _updateDropIndicatorAtVisRow:visIdx];
  }
  return [self _isDuplicateDrag:sender] ? NSDragOperationCopy
                                        : NSDragOperationMove;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
  self.dropFlatIndex = -1;
  [self _removeDropIndicator];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
  return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  [self _removeDropIndicator];
  NSInteger targetIndex = self.dropFlatIndex;
  self.dropFlatIndex = -1;
  if (targetIndex < 0)
    return NO;

  NSIndexSet *dragIndices = [self _dragIndicesFromPasteboard:sender];
  if (!dragIndices || dragIndices.count == 0)
    return NO;

  NSString *pgid = self.dropParentGroupID;
  self.dropParentGroupID = nil;
  if ([self _isDuplicateDrag:sender]) {
    [self.actionTarget _duplicateFromIndices:dragIndices
                                     toIndex:(NSUInteger)targetIndex
                               parentGroupID:pgid];
  } else {
    [self.actionTarget _reorderFromIndices:dragIndices
                                   toIndex:(NSUInteger)targetIndex
                             parentGroupID:pgid];
  }
  return YES;
}

- (void)_updateDropIndicatorAtVisRow:(NSInteger)visRow {
  if (!_dropIndicator) {
    _dropIndicator = [[NSView alloc] initWithFrame:NSZeroRect];
    _dropIndicator.wantsLayer = YES;
    _dropIndicator.layer.backgroundColor = [NSColor accent].CGColor;
    _dropIndicator.layer.cornerRadius = KKBorderWidthSM / 2.0;
  }
  CGFloat y = kLayerListVerticalPad + visRow * kLayerRowStride - 1.0;
  CGFloat left = KKPaddingSM + self.dropIndent;
  _dropIndicator.frame = NSMakeRect(
      left, y, self.bounds.size.width - left - KKPaddingSM, KKBorderWidthSM);
  if (!_dropIndicator.superview)
    [self addSubview:_dropIndicator];
}

- (void)_removeDropIndicator {
  [_dropIndicator removeFromSuperview];
  _dropIndicator = nil;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (event.modifierFlags & NSEventModifierFlagCommand &&
      [event.charactersIgnoringModifiers isEqualToString:@"g"]) {
    NSMenuItem *fake = [[NSMenuItem alloc] init];
    [self.actionTarget groupSelection:fake];
    return YES;
  }
  return [super performKeyEquivalent:event];
}

@end
