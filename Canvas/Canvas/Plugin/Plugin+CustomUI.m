/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#include <KeyframelessKit/KeyframelessKit.h>
#import <objc/message.h>

static const CGFloat kListHeight = 100.0;
static const CGFloat kVerticalPad = 4.0;
static const CGFloat kTotalHeight = kListHeight + kVerticalPad * 2;

static const CGFloat kRowHeight = 24.0;
static const CGFloat kRowSpacing = 1.0;

@protocol KKLayerReorder
- (void)_reorderFromIndices:(NSIndexSet *)indices
                    toIndex:(NSUInteger)target
              parentGroupID:(NSString *)parentGroupID;
- (void)renameRow:(NSMenuItem *)sender;
- (void)groupSelection:(NSMenuItem *)sender;
@end

@class KKLayerActionTarget;

@interface KKLayerRow : NSStackView
@property(nonatomic) NSUInteger rowIndex;
@property(nonatomic, copy) NSString *groupID;
@property(nonatomic, copy) NSString *parentGroupID;
- (NSImage *)snapshot;
@end

@interface KKLayerContentView : NSView
@property(nonatomic, weak) id<KKLayerReorder> actionTarget;
@property(nonatomic) NSInteger dropFlatIndex;
@property(nonatomic) CGFloat dropIndent;
@property(nonatomic, copy) NSString *dropParentGroupID;
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
    [self registerForDraggedTypes:@[ @"com.overpolish.canvas.layerDrag" ]];
  }
  return self;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return NSDragOperationMove;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  NSPoint loc = [self convertPoint:sender.draggingLocation fromView:nil];
  CGFloat stride = kRowHeight + kRowSpacing;
  NSInteger visIdx = (NSInteger)round((loc.y - kVerticalPad) / stride);

  // Build sorted list of visible rows
  NSMutableArray<KKLayerRow *> *rows = [NSMutableArray array];
  for (NSView *v in self.subviews) {
    if ([v isKindOfClass:[KKLayerRow class]] && !v.hidden)
      [rows addObject:(KKLayerRow *)v];
  }
  [rows sortUsingComparator:^NSComparisonResult(KKLayerRow *a, KKLayerRow *b) {
    return a.rowIndex < b.rowIndex ? NSOrderedAscending : NSOrderedDescending;
  }];

  visIdx = MAX(0, MIN(visIdx, (NSInteger)rows.count));

  NSInteger flatIdx;
  CGFloat indent = 0;
  NSString *parentGID = nil;

  // Which row is the cursor actually over?
  CGFloat rowY = loc.y - kVerticalPad;
  CGFloat fractional = rowY / stride;
  NSInteger hoverIdx = (NSInteger)fractional;
  BOOL inTopHalf = (fractional - floor(fractional)) < 0.5;
  hoverIdx = MAX(0, MIN(hoverIdx, (NSInteger)rows.count - 1));

  KKLayerRow *hoverRow = (rows.count > 0) ? rows[(NSUInteger)hoverIdx] : nil;

  // Get dragged indices to prevent dropping into self
  NSData *dragData = [sender.draggingPasteboard
      dataForType:@"com.overpolish.canvas.layerDrag"];
  NSIndexSet *dragIndices =
      dragData ? [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                                   fromData:dragData
                                                      error:nil]
               : nil;

  if (hoverRow) {
    if (inTopHalf) {
      flatIdx = (NSInteger)hoverRow.rowIndex;
    } else {
      flatIdx = (NSInteger)hoverRow.rowIndex + 1;
    }
    if (hoverRow.groupID && !inTopHalf)
      parentGID = hoverRow.groupID;
    else
      parentGID = hoverRow.parentGroupID;

    KKLog *log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
    [log info:@"drag: hover=%lu topHalf=%d groupID=%@ parentGID=%@ "
              @"dragIndices=%@",
              (unsigned long)hoverRow.rowIndex, inTopHalf, hoverRow.groupID,
              parentGID, dragIndices];

    // Prevent dropping into a group that is being dragged
    if (parentGID && dragIndices) {
      // Walk the target parent chain — if any ancestor is being dragged,
      // it would create a cycle
      NSString *checkGID = parentGID;
      NSUInteger guard = 0;
      while (checkGID && guard < 20) {
        guard++;
        BOOL found = NO;
        for (KKLayerRow *r in rows) {
          if (r.groupID && [r.groupID isEqualToString:checkGID]) {
            if ([dragIndices containsIndex:r.rowIndex]) {
              // This group is being dragged — fall back to its parent
              parentGID = r.parentGroupID;
              checkGID = nil;
            } else {
              checkGID = r.parentGroupID;
            }
            found = YES;
            break;
          }
        }
        if (!found)
          break;
      }
    }
  } else {
    flatIdx = 0;
  }

  // Calculate indent from parentGID depth
  NSUInteger depthCount = 0;
  NSString *pid = parentGID;
  while (pid && depthCount < 20) {
    depthCount++;
    NSString *nextPid = nil;
    for (KKLayerRow *r in rows) {
      if ([r.groupID isEqualToString:pid]) {
        nextPid = r.parentGroupID;
        break;
      }
    }
    pid = nextPid;
  }
  indent = depthCount * 18.0;

  if (flatIdx != self.dropFlatIndex || fabs(indent - self.dropIndent) > 0.5) {
    self.dropFlatIndex = flatIdx;
    self.dropIndent = indent;
    self.dropParentGroupID = parentGID;
    [self _updateDropIndicatorAtVisRow:visIdx];
  }
  return NSDragOperationMove;
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

  NSData *data = [sender.draggingPasteboard
      dataForType:@"com.overpolish.canvas.layerDrag"];
  if (!data)
    return NO;

  NSIndexSet *dragIndices =
      [NSKeyedUnarchiver unarchivedObjectOfClass:[NSIndexSet class]
                                        fromData:data
                                           error:nil];
  if (!dragIndices || dragIndices.count == 0)
    return NO;

  NSString *pgid = self.dropParentGroupID;
  self.dropParentGroupID = nil;
  [self.actionTarget _reorderFromIndices:dragIndices
                                 toIndex:(NSUInteger)targetIndex
                           parentGroupID:pgid];
  return YES;
}

- (void)_updateDropIndicatorAtVisRow:(NSInteger)visRow {
  if (!_dropIndicator) {
    _dropIndicator = [[NSView alloc] initWithFrame:NSZeroRect];
    _dropIndicator.wantsLayer = YES;
    _dropIndicator.layer.backgroundColor = [NSColor accent].CGColor;
    _dropIndicator.layer.cornerRadius = 1.0;
  }
  CGFloat stride = kRowHeight + kRowSpacing;
  CGFloat y = kVerticalPad + visRow * stride - 1.0;
  CGFloat left = KKPaddingSM + self.dropIndent;
  _dropIndicator.frame =
      NSMakeRect(left, y, self.bounds.size.width - left - KKPaddingSM, 2.0);
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

static BOOL sForceRefresh = NO;
static BOOL sIsEditing = NO;
static BOOL sIsDragging = NO;
static NSString *const kLayerDragType = @"com.overpolish.canvas.layerDrag";
static NSIndexSet *sSelectedIndices;
static NSIndexSet *sUISelection;
static NSIndexSet *sPendingOSCSelection;
static NSSet<NSString *> *sCollapsedGroupIDs;
void KKCanvasRefreshLayerList(NSUInteger pathCount,
                              NSArray<KKBezierPath *> *paths);

static NSIndexSet *KKDescendantIndices(NSUInteger groupIdx,
                                       NSArray<KKBezierPath *> *paths) {
  NSString *gid = paths[groupIdx].groupID;
  if (!gid)
    return [NSIndexSet indexSet];
  NSMutableIndexSet *result = [NSMutableIndexSet indexSet];
  NSMutableSet<NSString *> *groupIDs = [NSMutableSet setWithObject:gid];
  for (NSUInteger i = 0; i < paths.count; i++) {
    if (i == groupIdx)
      continue;
    if (paths[i].parentGroupID &&
        [groupIDs containsObject:paths[i].parentGroupID]) {
      [result addIndex:i];
      if (paths[i].isGroup && paths[i].groupID)
        [groupIDs addObject:paths[i].groupID];
    }
  }
  return result;
}

@interface KKLayerListContainer : NSView
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSView *borderView;
@property(nonatomic, strong) NSView *emptyView;
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, strong) NSLayoutConstraint *contentHeightConstraint;
@property(nonatomic, strong) KKLayerActionTarget *actionTarget;
@end

static __weak KKLayerListContainer *sLayerListContainer;

@interface KKEditableLabel : NSTextField
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

@interface KKLayerButton : NSButton <NSDraggingSource>
@property(nonatomic, weak) KKLayerRow *parentRow;
@end

@implementation KKLayerButton {
  NSPoint _mouseDownPoint;
  BOOL _didDrag;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return NSDragOperationMove;
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

  // Only include direct rows, not expanded group children.
  // The reorder will expand groups via KKDescendantIndices.
  NSIndexSet *dragIndices = [NSIndexSet indexSetWithIndex:row.rowIndex];

  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dragIndices
                                       requiringSecureCoding:YES
                                                       error:nil];
  NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
  [pbItem setData:data forType:kLayerDragType];

  NSDraggingItem *dragItem =
      [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];
  [dragItem setDraggingFrame:row.bounds contents:[row snapshot]];

  sIsDragging = YES;
  [row beginDraggingSessionWithItems:@[ dragItem ] event:event source:self];
}

- (void)mouseUp:(NSEvent *)event {
  [self highlight:NO];
  if (_didDrag)
    return;
  if (event.clickCount >= 2) {
    KKLayerRow *row = self.parentRow;
    if (row) {
      KKLayerListContainer *container = sLayerListContainer;
      if (container) {
        NSMenuItem *fake = [[NSMenuItem alloc] init];
        fake.tag = row.rowIndex;
        [(id<KKLayerReorder>)container.actionTarget renameRow:fake];
      }
    }
  } else {
    [self performClick:self];
  }
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
  sIsDragging = NO;
  sForceRefresh = YES;
}

@end

@interface KKLayerActionTarget : NSObject <NSTextFieldDelegate, KKLayerReorder>
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
- (void)toggleVisibility:(NSButton *)sender;
- (void)toggleLock:(NSButton *)sender;
- (void)renameRow:(NSMenuItem *)sender;
- (void)duplicateRow:(NSMenuItem *)sender;
- (void)deleteRow:(NSMenuItem *)sender;
- (void)groupSelection:(NSMenuItem *)sender;
- (void)ungroupRow:(NSMenuItem *)sender;
- (void)removeFromGroup:(NSMenuItem *)sender;
- (void)toggleGroupCollapse:(NSButton *)sender;
- (void)_reorderFromIndices:(NSIndexSet *)indices
                    toIndex:(NSUInteger)target
              parentGroupID:(NSString *)parentGroupID;
@end

@implementation KKLayerActionTarget

- (void)_toggleProperty:(NSButton *)sender
                  apply:(void (^)(KKBezierPath *))apply {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length == 0) {
    [actionAPI endAction:self];
    return;
  }

  NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
  NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
  NSUInteger index = sender.tag;
  if (index >= paths.count) {
    [actionAPI endAction:self];
    return;
  }

  apply(paths[index]);
  NSData *newBlob = [KKBezierPath blobFromPaths:paths];
  NSString *newStr = [newBlob base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:newStr toParameter:kParamPathData];
  [actionAPI endAction:self];

  sForceRefresh = YES;
  KKCanvasRefreshLayerList(paths.count, paths);
}

- (void)toggleVisibility:(NSButton *)sender {
  NSUInteger idx = sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    BOOL newVal = !paths[idx].hidden;
    paths[idx].hidden = newVal;
    if (paths[idx].isGroup) {
      NSIndexSet *desc = KKDescendantIndices(idx, paths);
      [desc enumerateIndexesUsingBlock:^(NSUInteger di, BOOL *stop) {
        paths[di].hidden = newVal;
      }];
    }
  }];
}

- (void)toggleLock:(NSButton *)sender {
  NSUInteger idx = sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    BOOL newVal = !paths[idx].locked;
    paths[idx].locked = newVal;
    if (paths[idx].isGroup) {
      NSIndexSet *desc = KKDescendantIndices(idx, paths);
      [desc enumerateIndexesUsingBlock:^(NSUInteger di, BOOL *stop) {
        paths[di].locked = newVal;
      }];
    }
  }];
}

- (void)_commitEditing {
  KKLayerListContainer *container = sLayerListContainer;
  if (!container || !sIsEditing)
    return;
  [container.contentView.window makeFirstResponder:container.contentView];
}

- (void)renameRow:(NSMenuItem *)sender {
  [self _commitEditing];

  NSInteger index = sender.tag;
  KKLayerListContainer *container = sLayerListContainer;
  if (!container)
    return;

  NSView *content = container.contentView;
  for (NSStackView *row in content.subviews) {
    if (![row isKindOfClass:[NSStackView class]])
      continue;
    for (NSView *v in row.arrangedSubviews) {
      if ([v isKindOfClass:[NSButton class]] && v.tag == index &&
          [(NSButton *)v action] == @selector(selectRow:)) {
        NSButton *btn = (NSButton *)v;
        KKEditableLabel *field =
            [KKEditableLabel textFieldWithString:btn.title];
        field.font = btn.font;
        field.tag = index;
        field.bordered = NO;
        field.focusRingType = NSFocusRingTypeNone;
        field.drawsBackground = NO;
        field.textColor = [NSColor labelColor];
        field.delegate = self;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        [field
            setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSUInteger viewIndex = [row.arrangedSubviews indexOfObject:btn];
        [row removeArrangedSubview:btn];
        [btn removeFromSuperview];
        [row insertArrangedSubview:field atIndex:viewIndex];

        sIsEditing = YES;
        [field.window makeFirstResponder:field];
        return;
      }
    }
  }
}

- (void)_modifyPaths:(void (^)(NSMutableArray<KKBezierPath *> *))block {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    block(paths);
    NSData *newBlob = [KKBezierPath blobFromPaths:paths];
    NSString *newStr = [newBlob base64EncodedStringWithOptions:0];
    [paramSetAPI setStringParameterValue:newStr toParameter:kParamPathData];

    sForceRefresh = YES;
    KKCanvasRefreshLayerList(paths.count, paths);
  }
  [actionAPI endAction:self];
}

- (void)duplicateRow:(NSMenuItem *)sender {
  NSIndexSet *sel = sUISelection;
  if (!sel || sel.count <= 1 || ![sel containsIndex:sender.tag])
    sel = [NSIndexSet indexSetWithIndex:sender.tag];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSMutableIndexSet *newSel = [NSMutableIndexSet indexSet];
    __block NSUInteger offset = 0;
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      NSUInteger src = idx + offset;
      if (src >= paths.count)
        return;
      KKBezierPath *clone =
          [KKBezierPath pathWithData:[paths[src] dataRepresentation]];
      [paths insertObject:clone atIndex:src + 1];
      [newSel addIndex:src + 1];
      offset++;
    }];
    NSIndexSet *frozen = [newSel copy];
    sUISelection = frozen;
    sSelectedIndices = frozen;
    sPendingOSCSelection = frozen;
  }];
}

- (void)deleteRow:(NSMenuItem *)sender {
  NSIndexSet *sel = sUISelection;
  if (!sel || sel.count <= 1 || ![sel containsIndex:sender.tag])
    sel = [NSIndexSet indexSetWithIndex:sender.tag];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSMutableIndexSet *expanded = [sel mutableCopy];
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup)
        [expanded addIndexes:KKDescendantIndices(idx, paths)];
    }];
    [expanded enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 if (idx < paths.count)
                                   [paths removeObjectAtIndex:idx];
                               }];
    NSMutableIndexSet *adjusted =
        [sUISelection mutableCopy] ?: [NSMutableIndexSet indexSet];
    [expanded enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 [adjusted removeIndex:idx];
                                 [adjusted shiftIndexesStartingAtIndex:idx + 1
                                                                    by:-1];
                               }];
    NSIndexSet *frozen = [adjusted copy];
    sUISelection = frozen;
    sSelectedIndices = frozen;
    sPendingOSCSelection = frozen;
  }];
}

- (void)groupSelection:(NSMenuItem *)sender {
  NSIndexSet *sel = sUISelection;
  if (!sel || sel.count == 0)
    return;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSUInteger insertAt = sel.firstIndex;
    NSString *inheritedParent =
        insertAt < paths.count ? paths[insertAt].parentGroupID : nil;

    NSMutableArray<KKBezierPath *> *children = [NSMutableArray array];
    [sel enumerateIndexesWithOptions:NSEnumerationReverse
                          usingBlock:^(NSUInteger idx, BOOL *stop) {
                            if (idx < paths.count) {
                              [children insertObject:paths[idx] atIndex:0];
                              [paths removeObjectAtIndex:idx];
                            }
                          }];
    KKBezierPath *group = [[KKBezierPath alloc] init];
    group.isGroup = YES;
    group.groupID = [[NSUUID UUID] UUIDString];
    group.parentGroupID = inheritedParent;
    group.name = @"Group";
    for (KKBezierPath *child in children) {
      if ([child.parentGroupID isEqual:inheritedParent] ||
          (!child.parentGroupID && !inheritedParent))
        child.parentGroupID = group.groupID;
    }
    insertAt = MIN(insertAt, paths.count);
    [paths insertObject:group atIndex:insertAt];
    for (NSUInteger i = 0; i < children.count; i++)
      [paths insertObject:children[i] atIndex:insertAt + 1 + i];

    NSIndexSet *groupSel = [NSIndexSet indexSetWithIndex:insertAt];
    sUISelection = groupSel;
    sSelectedIndices = groupSel;
    sPendingOSCSelection = groupSel;
  }];
}

- (void)removeFromGroup:(NSMenuItem *)sender {
  NSUInteger idx = sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count)
      return;
    paths[idx].parentGroupID = nil;
  }];
}

- (void)ungroupRow:(NSMenuItem *)sender {
  NSUInteger idx = sender.tag;
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if (idx >= paths.count || !paths[idx].isGroup)
      return;
    NSString *gid = paths[idx].groupID;
    NSString *parentGID = paths[idx].parentGroupID;
    [paths removeObjectAtIndex:idx];

    NSMutableIndexSet *childSel = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < paths.count; i++) {
      if ([paths[i].parentGroupID isEqualToString:gid ?: @""]) {
        paths[i].parentGroupID = parentGID;
        [childSel addIndex:i];
      }
    }
    NSIndexSet *frozen = [childSel copy];
    sUISelection = frozen;
    sSelectedIndices = frozen;
    sPendingOSCSelection = frozen;
  }];
}

- (void)toggleGroupCollapse:(id)sender {
  NSUInteger idx = [(NSView *)sender tag];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  [paramSetAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
  [actionAPI endAction:self];

  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if (idx < paths.count && paths[idx].groupID) {
      NSString *gid = paths[idx].groupID;
      NSMutableSet<NSString *> *mut = sCollapsedGroupIDs
                                          ? [sCollapsedGroupIDs mutableCopy]
                                          : [NSMutableSet set];
      if ([mut containsObject:gid])
        [mut removeObject:gid];
      else
        [mut addObject:gid];
      sCollapsedGroupIDs = [mut copy];
    }
    sForceRefresh = YES;
    KKCanvasRefreshLayerList(paths.count, paths);
  }
}

- (void)_reorderFromIndices:(NSIndexSet *)indices
                    toIndex:(NSUInteger)target
              parentGroupID:(NSString *)parentGroupID {
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    // Expand to include descendants of any dragged groups
    NSMutableIndexSet *expanded = [indices mutableCopy];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count && paths[idx].isGroup)
        [expanded addIndexes:KKDescendantIndices(idx, paths)];
    }];

    // Tag direct items (the ones user actually dragged) before removal
    NSMutableSet *directItems = [NSMutableSet set];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count)
        [directItems addObject:paths[idx]];
    }];

    // Collect in order
    NSMutableArray<KKBezierPath *> *dragged = [NSMutableArray array];
    [expanded enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx < paths.count)
        [dragged addObject:paths[idx]];
    }];

    // Calculate insert position
    NSUInteger insertBefore = target;
    insertBefore -=
        [expanded countOfIndexesInRange:NSMakeRange(0, insertBefore)];

    // Remove
    [expanded enumerateIndexesWithOptions:NSEnumerationReverse
                               usingBlock:^(NSUInteger idx, BOOL *stop) {
                                 if (idx < paths.count)
                                   [paths removeObjectAtIndex:idx];
                               }];

    // Insert and update parentGroupID only on direct items
    NSUInteger insertAt = MIN(insertBefore, paths.count);
    for (NSUInteger i = 0; i < dragged.count; i++) {
      if ([directItems containsObject:dragged[i]])
        dragged[i].parentGroupID = parentGroupID;
      [paths insertObject:dragged[i] atIndex:insertAt + i];
    }

    NSIndexSet *newSel = [NSIndexSet
        indexSetWithIndexesInRange:NSMakeRange(insertAt, dragged.count)];
    sUISelection = newSel;
    sSelectedIndices = newSel;
    sPendingOSCSelection = newSel;
  }];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
  NSTextField *field = note.object;
  NSString *newName = field.stringValue;
  NSInteger index = field.tag;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if (index >= 0 && (NSUInteger)index < paths.count) {
      paths[index].name = newName.length > 0 ? newName : nil;
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      NSString *newStr = [newBlob base64EncodedStringWithOptions:0];
      [paramSetAPI setStringParameterValue:newStr toParameter:kParamPathData];
    }
  }
  [actionAPI endAction:self];

  sIsEditing = NO;
  sForceRefresh = YES;
}

- (void)selectRow:(NSButton *)sender {
  [self _commitEditing];
  NSUInteger clicked = sender.tag;
  NSEventModifierFlags flags = NSEvent.modifierFlags;
  NSMutableIndexSet *sel =
      [sUISelection mutableCopy] ?: [NSMutableIndexSet indexSet];

  if (flags & NSEventModifierFlagCommand) {
    if ([sel containsIndex:clicked])
      [sel removeIndex:clicked];
    else
      [sel addIndex:clicked];
  } else if (flags & NSEventModifierFlagShift) {
    NSUInteger anchor = sel.count > 0 ? sel.lastIndex : 0;
    NSUInteger lo = MIN(anchor, clicked);
    NSUInteger hi = MAX(anchor, clicked);
    [sel addIndexesInRange:NSMakeRange(lo, hi - lo + 1)];
  } else {
    [sel removeAllIndexes];
    [sel addIndex:clicked];
  }

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];

  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if (clicked < paths.count && paths[clicked].isGroup)
      [sel addIndexes:KKDescendantIndices(clicked, paths)];
  }

  NSIndexSet *frozen = [sel copy];
  sUISelection = frozen;
  sSelectedIndices = frozen;
  sPendingOSCSelection = frozen;

  [paramSetAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
  [actionAPI endAction:self];

  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    sForceRefresh = YES;
    KKCanvasRefreshLayerList(paths.count, paths);
  }
}

@end

@implementation KKLayerListContainer
@end

static NSUInteger sLastListHash = NSUIntegerMax;

NSIndexSet *_Nullable KKCanvasConsumePendingSelection(void) {
  NSIndexSet *pending = sPendingOSCSelection;
  sPendingOSCSelection = nil;
  return pending;
}

void KKCanvasUpdateSelection(NSIndexSet *indices) {
  NSIndexSet *copy = [indices copy];
  sSelectedIndices = copy;
  dispatch_async(dispatch_get_main_queue(), ^{
    sUISelection = copy;
  });
}

static NSUInteger layerListHash(NSUInteger count,
                                NSArray<KKBezierPath *> *paths,
                                NSIndexSet *selection) {
  NSUInteger h = count;
  for (NSUInteger i = 0; i < count; i++) {
    h = h * 31 + (paths[i].hidden ? 1 : 0);
    h = h * 31 + (paths[i].locked ? 2 : 0);
    h = h * 31 + paths[i].name.hash;
  }
  h = h * 31 + selection.hash;
  return h;
}

void KKCanvasRefreshLayerList(NSUInteger pathCount,
                              NSArray<KKBezierPath *> *paths) {
  NSIndexSet *selection = sSelectedIndices ?: [NSIndexSet indexSet];
  NSUInteger hash = layerListHash(pathCount, paths, selection);
  if (hash == sLastListHash && !sForceRefresh)
    return;
  sLastListHash = hash;
  sForceRefresh = NO;

  NSIndexSet *capturedSelection = [selection copy];
  NSMutableArray<NSNumber *> *hiddenStates =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSNumber *> *lockedStates =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSNumber *> *groupFlags =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSString *> *groupIDs =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSString *> *parentGroupIDs =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSString *> *names =
      [NSMutableArray arrayWithCapacity:pathCount];
  for (NSUInteger i = 0; i < pathCount; i++) {
    [hiddenStates addObject:@(paths[i].hidden)];
    [lockedStates addObject:@(paths[i].locked)];
    [groupFlags addObject:@(paths[i].isGroup)];
    [groupIDs addObject:paths[i].groupID ?: @""];
    [parentGroupIDs addObject:paths[i].parentGroupID ?: @""];
    [names addObject:paths[i].name
                         ?: [NSString stringWithFormat:@"Path %lu",
                                                       (unsigned long)(i + 1)]];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    KKLayerListContainer *container = sLayerListContainer;
    if (!container)
      return;
    if (sIsEditing || sIsDragging)
      return;

    NSView *content = container.contentView;
    [content.subviews
        makeObjectsPerformSelector:@selector(removeFromSuperview)];

    if (pathCount == 0) {
      container.emptyView.hidden = NO;
      [content addSubview:container.emptyView];
      container.contentHeightConstraint.constant = kListHeight;
      return;
    }

    container.emptyView.hidden = YES;
    CGFloat topPad = kVerticalPad;
    CGFloat stride = kRowHeight + kRowSpacing;

    NSImageSymbolConfiguration *symConfig = [NSImageSymbolConfiguration
        configurationWithPointSize:10.0
                            weight:NSFontWeightRegular];

    // Build groupID→index map for collapse checking
    NSMutableDictionary<NSString *, NSNumber *> *groupIndexMap =
        [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < pathCount; i++) {
      if (groupFlags[i].boolValue && groupIDs[i].length > 0)
        groupIndexMap[groupIDs[i]] = @(i);
    }

    NSUInteger visRow = 0;

    for (NSUInteger i = 0; i < pathCount; i++) {
      BOOL isGroup = groupFlags[i].boolValue;

      // Check if any ancestor is collapsed
      BOOL ancestorCollapsed = NO;
      NSString *pid = parentGroupIDs[i];
      NSUInteger guard = 0;
      while (pid.length > 0 && guard < 20) {
        guard++;
        NSNumber *parentIdx = groupIndexMap[pid];
        if (parentIdx &&
            [sCollapsedGroupIDs
                containsObject:groupIDs[parentIdx.unsignedIntegerValue]]) {
          ancestorCollapsed = YES;
          break;
        }
        if (parentIdx)
          pid = parentGroupIDs[parentIdx.unsignedIntegerValue];
        else
          break;
      }
      if (ancestorCollapsed)
        continue;

      BOOL collapsed = isGroup && groupIDs[i].length > 0 &&
                       [sCollapsedGroupIDs containsObject:groupIDs[i]];
      BOOL isHidden = hiddenStates[i].boolValue;
      BOOL isLocked = lockedStates[i].boolValue;
      BOOL isSelected = [capturedSelection containsIndex:i];

      // Calculate depth by walking parentGroupID chain
      NSUInteger depth = 0;
      NSString *dpid = parentGroupIDs[i];
      while (dpid.length > 0 && depth < 20) {
        depth++;
        NSNumber *pIdx = groupIndexMap[dpid];
        if (pIdx)
          dpid = parentGroupIDs[pIdx.unsignedIntegerValue];
        else
          break;
      }
      CGFloat indent = depth * 18.0;

      // --- Build row views ---

      NSMutableArray<NSView *> *rowViews = [NSMutableArray array];

      if (isGroup) {
        NSString *folderName = collapsed ? @"folder.fill" : @"folder";
        NSButton *folderBtn = [NSButton
            buttonWithImage:[[NSImage imageWithSystemSymbolName:folderName
                                       accessibilityDescription:nil]
                                imageWithSymbolConfiguration:symConfig]
                     target:container.actionTarget
                     action:@selector(toggleGroupCollapse:)];
        folderBtn.bezelStyle = NSBezelStyleInline;
        folderBtn.bordered = NO;
        folderBtn.imagePosition = NSImageOnly;
        folderBtn.tag = i;
        folderBtn.contentTintColor = [NSColor secondaryLabelColor];
        [folderBtn.widthAnchor constraintEqualToConstant:12.0].active = YES;
        [folderBtn.heightAnchor constraintEqualToConstant:12.0].active = YES;
        [rowViews addObject:folderBtn];
      }

      NSString *eyeName = isHidden ? @"eye.slash" : @"eye.fill";
      NSButton *eyeButton =
          [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:eyeName
                                               accessibilityDescription:nil]
                                        imageWithSymbolConfiguration:symConfig]
                             target:container.actionTarget
                             action:@selector(toggleVisibility:)];
      eyeButton.bezelStyle = NSBezelStyleInline;
      eyeButton.bordered = NO;
      eyeButton.imagePosition = NSImageOnly;
      eyeButton.tag = i;
      eyeButton.contentTintColor = isHidden ? [NSColor tertiaryLabelColor]
                                            : [NSColor secondaryLabelColor];
      [eyeButton.widthAnchor constraintEqualToConstant:12.0].active = YES;
      [eyeButton.heightAnchor constraintEqualToConstant:12.0].active = YES;
      [rowViews addObject:eyeButton];

      KKLayerButton *rowButton =
          [KKLayerButton buttonWithTitle:names[i]
                                  target:container.actionTarget
                                  action:@selector(selectRow:)];
      rowButton.bezelStyle = NSBezelStyleInline;
      rowButton.bordered = NO;
      rowButton.tag = i;
      rowButton.alignment = NSTextAlignmentLeft;
      rowButton.font = isGroup ? [NSFont boldSystemFontOfSize:11.0]
                               : [NSFont systemFontOfSize:11.0];
      rowButton.contentTintColor =
          isHidden ? [NSColor tertiaryLabelColor] : [NSColor labelColor];
      rowButton.cell.lineBreakMode = NSLineBreakByTruncatingTail;
      [rowButton
          setContentHuggingPriority:1
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
      [rowViews addObject:rowButton];

      NSString *lockName = isLocked ? @"lock.fill" : @"lock.open";
      NSButton *lockButton =
          [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:lockName
                                               accessibilityDescription:nil]
                                        imageWithSymbolConfiguration:symConfig]
                             target:container.actionTarget
                             action:@selector(toggleLock:)];
      lockButton.bezelStyle = NSBezelStyleInline;
      lockButton.bordered = NO;
      lockButton.imagePosition = NSImageOnly;
      lockButton.tag = i;
      lockButton.contentTintColor = isLocked ? [NSColor secondaryLabelColor]
                                             : [NSColor tertiaryLabelColor];
      [lockButton.widthAnchor constraintEqualToConstant:12.0].active = YES;
      [lockButton.heightAnchor constraintEqualToConstant:12.0].active = YES;
      [rowViews addObject:lockButton];

      // --- Context menu ---

      BOOL multiSelect = capturedSelection.count > 1;
      NSMenu *ctxMenu = [[NSMenu alloc] init];

      if (!multiSelect) {
        NSMenuItem *renameItem =
            [[NSMenuItem alloc] initWithTitle:@"Rename"
                                       action:@selector(renameRow:)
                                keyEquivalent:@""];
        renameItem.target = container.actionTarget;
        renameItem.tag = i;
        renameItem.image = [NSImage imageWithSystemSymbolName:@"pencil"
                                     accessibilityDescription:nil];
        [ctxMenu addItem:renameItem];
      }

      if (isGroup) {
        NSMenuItem *ungroupItem =
            [[NSMenuItem alloc] initWithTitle:@"Ungroup"
                                       action:@selector(ungroupRow:)
                                keyEquivalent:@""];
        ungroupItem.target = container.actionTarget;
        ungroupItem.tag = i;
        ungroupItem.image =
            [NSImage imageWithSystemSymbolName:@"folder.badge.minus"
                      accessibilityDescription:nil];
        [ctxMenu addItem:ungroupItem];
      }

      if (!isGroup) {
        NSMenuItem *groupItem =
            [[NSMenuItem alloc] initWithTitle:@"Group"
                                       action:@selector(groupSelection:)
                                keyEquivalent:@""];
        groupItem.target = container.actionTarget;
        groupItem.tag = i;
        groupItem.image =
            [NSImage imageWithSystemSymbolName:@"folder.badge.plus"
                      accessibilityDescription:nil];
        [ctxMenu addItem:groupItem];
      }

      if (!isGroup && depth > 0) {
        NSMenuItem *removeFromGroupItem =
            [[NSMenuItem alloc] initWithTitle:@"Remove from Group"
                                       action:@selector(removeFromGroup:)
                                keyEquivalent:@""];
        removeFromGroupItem.target = container.actionTarget;
        removeFromGroupItem.tag = i;
        removeFromGroupItem.image = [NSImage
            imageWithSystemSymbolName:@"rectangle.portrait.and.arrow.right"
             accessibilityDescription:nil];
        [ctxMenu addItem:removeFromGroupItem];
      }

      if (!isGroup) {
        NSMenuItem *duplicateItem =
            [[NSMenuItem alloc] initWithTitle:@"Duplicate"
                                       action:@selector(duplicateRow:)
                                keyEquivalent:@""];
        duplicateItem.target = container.actionTarget;
        duplicateItem.tag = i;
        duplicateItem.image =
            [NSImage imageWithSystemSymbolName:@"plus.rectangle.on.rectangle"
                      accessibilityDescription:nil];
        [ctxMenu addItem:duplicateItem];
      }

      [ctxMenu addItem:[NSMenuItem separatorItem]];

      NSMenuItem *deleteItem =
          [[NSMenuItem alloc] initWithTitle:@"Delete"
                                     action:@selector(deleteRow:)
                              keyEquivalent:@""];
      deleteItem.target = container.actionTarget;
      deleteItem.tag = i;
      deleteItem.image = [NSImage imageWithSystemSymbolName:@"trash"
                                   accessibilityDescription:nil];
      deleteItem.attributedTitle = [[NSMutableAttributedString alloc]
          initWithString:@"Delete"
              attributes:@{NSForegroundColorAttributeName : [NSColor error]}];
      [ctxMenu addItem:deleteItem];

      // --- Build row ---

      KKLayerRow *row = [KKLayerRow stackViewWithViews:rowViews];
      row.rowIndex = i;
      row.groupID = isGroup ? groupIDs[i] : nil;
      row.parentGroupID =
          parentGroupIDs[i].length > 0 ? parentGroupIDs[i] : nil;
      rowButton.parentRow = row;
      row.menu = ctxMenu;
      row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      row.alignment = NSLayoutAttributeCenterY;
      row.distribution = NSStackViewDistributionFill;
      row.spacing = 6.0;
      row.edgeInsets =
          NSEdgeInsetsMake(0, KKPaddingMD + indent, 0, KKPaddingMD);
      row.wantsLayer = YES;
      row.layer.cornerRadius = 4.0;
      row.layer.backgroundColor =
          isSelected ? [[NSColor accent] colorWithAlphaComponent:0.15].CGColor
                     : [NSColor clearColor].CGColor;
      row.translatesAutoresizingMaskIntoConstraints = NO;
      [content addSubview:row];
      [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                        constant:KKPaddingSM]
          .active = YES;
      [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                         constant:-KKPaddingSM]
          .active = YES;
      [row.topAnchor constraintEqualToAnchor:content.topAnchor
                                    constant:topPad + visRow * stride]
          .active = YES;
      [row.heightAnchor constraintEqualToConstant:kRowHeight].active = YES;
      visRow++;
    }

    CGFloat totalHeight = MAX(visRow * stride + topPad, kListHeight);
    container.contentHeightConstraint.constant = totalHeight;
  });
}

@implementation CanvasPlugin (CustomUI)

- (void)refreshLayerList {
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamLayerList) {
    CGFloat inset = KKInspectorHorizontalInset;

    KKLayerListContainer *wrapper = [[KKLayerListContainer alloc]
        initWithFrame:NSMakeRect(0, 0, 300, kTotalHeight)];
    wrapper.autoresizingMask = NSViewWidthSizable;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0];
    scrollView.borderType = NSNoBorder;
    scrollView.wantsLayer = YES;
    scrollView.layer.cornerRadius = 6.0;
    scrollView.layer.masksToBounds = YES;
    wrapper.scrollView = scrollView;

    NSView *borderView = [[NSView alloc] initWithFrame:NSZeroRect];
    borderView.translatesAutoresizingMaskIntoConstraints = NO;
    borderView.wantsLayer = YES;
    borderView.layer.cornerRadius = 6.0;
    borderView.layer.borderWidth = 1.0;
    borderView.layer.borderColor =
        [NSColor colorWithWhite:1.0 alpha:0.05].CGColor;
    wrapper.borderView = borderView;
    [borderView addSubview:scrollView];
    [wrapper addSubview:borderView];

    [NSLayoutConstraint activateConstraints:@[
      [borderView.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor
                                               constant:inset],
      [borderView.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor
                                                constant:-inset],
      [borderView.topAnchor constraintEqualToAnchor:wrapper.topAnchor
                                           constant:kVerticalPad],
      [borderView.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor
                                              constant:-kVerticalPad],
      [scrollView.leadingAnchor
          constraintEqualToAnchor:borderView.leadingAnchor],
      [scrollView.trailingAnchor
          constraintEqualToAnchor:borderView.trailingAnchor],
      [scrollView.topAnchor constraintEqualToAnchor:borderView.topAnchor],
      [scrollView.bottomAnchor constraintEqualToAnchor:borderView.bottomAnchor],
    ]];

    NSImage *icon =
        [NSImage imageWithSystemSymbolName:@"square.3.layers.3d.slash"
                  accessibilityDescription:nil];
    NSImageView *iconView = [NSImageView imageViewWithImage:icon];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentTintColor = [NSColor secondaryLabelColor];
    [iconView.widthAnchor constraintEqualToConstant:12.0].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:12.0].active = YES;

    NSTextField *empty = [NSTextField labelWithString:@"No shapes"];
    empty.font = [NSFont systemFontOfSize:11.0];
    empty.textColor = [NSColor secondaryLabelColor];
    empty.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *emptyStack =
        [NSStackView stackViewWithViews:@[ iconView, empty ]];
    emptyStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    emptyStack.spacing = 4.0;
    emptyStack.translatesAutoresizingMaskIntoConstraints = NO;

    KKLayerContentView *content =
        [[KKLayerContentView alloc] initWithFrame:NSZeroRect];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:emptyStack];
    scrollView.documentView = content;

    [content.leadingAnchor
        constraintEqualToAnchor:scrollView.contentView.leadingAnchor]
        .active = YES;
    [content.trailingAnchor
        constraintEqualToAnchor:scrollView.contentView.trailingAnchor]
        .active = YES;
    NSLayoutConstraint *heightConstraint =
        [content.heightAnchor constraintEqualToConstant:kListHeight];
    heightConstraint.active = YES;
    [emptyStack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor]
        .active = YES;
    [emptyStack.topAnchor constraintEqualToAnchor:content.topAnchor
                                         constant:kListHeight / 2 - 7]
        .active = YES;

    KKLayerActionTarget *visTarget = [[KKLayerActionTarget alloc] init];
    visTarget.apiManager = self.apiManager;

    wrapper.emptyView = emptyStack;
    wrapper.contentView = content;
    wrapper.contentHeightConstraint = heightConstraint;
    wrapper.actionTarget = visTarget;
    content.actionTarget = visTarget;
    sLayerListContainer = wrapper;
    sLastListHash = NSUIntegerMax;

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *str = nil;
    [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
    [actionAPI endAction:self];

    if (str.length > 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
      NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
      if (paths.count > 0)
        KKCanvasRefreshLayerList(paths.count, paths);
    }

    return wrapper;
  }

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
