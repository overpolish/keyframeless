/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKReorderListView.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

// Private pasteboard type carrying the dragged row's index (mirrors the Canvas
// layer-list reorder, which archives an NSIndexSet; a single int suffices here
// since the property list is single-select).
static NSString *const kKKReorderDragType =
    @"com.overpolish.keyframeless.reorderRow";

static const CGFloat kRowH = 28.0;
static const CGFloat kRowGap = 2.0;
static const CGFloat kListPad = 2.0;
static const CGFloat kListWidth = 200.0;
static const CGFloat kRowStride = kRowH + kRowGap;

@class KKReorderListView;

// One draggable row. Begins an NSDraggingSession once the pointer travels past
// the threshold, carrying its current index on the pasteboard.
@interface _KKReorderRow : NSView <NSDraggingSource>
@property(nonatomic) NSInteger index;
@end

@implementation _KKReorderRow {
  NSPoint _downPt;
  BOOL _didDrag;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSImage *)_snapshot {
  NSBitmapImageRep *rep =
      [self bitmapImageRepForCachingDisplayInRect:self.bounds];
  if (!rep)
    return nil;
  [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
  NSImage *img = [[NSImage alloc] initWithSize:self.bounds.size];
  [img addRepresentation:rep];
  return img;
}

- (void)mouseDown:(NSEvent *)event {
  _downPt = [self convertPoint:event.locationInWindow fromView:nil];
  _didDrag = NO;
}

- (void)mouseDragged:(NSEvent *)event {
  if (_didDrag)
    return;
  NSPoint cur = [self convertPoint:event.locationInWindow fromView:nil];
  if (hypot(cur.x - _downPt.x, cur.y - _downPt.y) < 3.0)
    return;
  _didDrag = YES;
  NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
  [item setString:[@(self.index) stringValue] forType:kKKReorderDragType];
  NSDraggingItem *di = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
  [di setDraggingFrame:self.bounds contents:[self _snapshot]];
  [self beginDraggingSessionWithItems:@[ di ] event:event source:self];
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return NSDragOperationMove;
}

@end

@interface KKReorderListView () <NSDraggingDestination>
@end

@implementation KKReorderListView {
  NSMutableArray<NSString *> *_ids;
  NSMutableArray<_KKReorderRow *> *_rows;
  NSView *_dropIndicator;
  NSInteger _dropIndex;
}

- (instancetype)initWithItemIDs:(NSArray<NSString *> *)itemIDs
                         titles:(NSArray<NSString *> *)titles {
  self = [super initWithFrame:NSMakeRect(0, 0, kListWidth, 0)];
  if (self) {
    _ids = [itemIDs mutableCopy];
    _rows = [NSMutableArray array];
    _dropIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)itemIDs.count; i++) {
      NSString *title = (i < (NSInteger)titles.count) ? titles[i] : itemIDs[i];
      _KKReorderRow *row = [self _makeRowWithTitle:title index:i];
      [_rows addObject:row];
      [self addSubview:row];
    }
    [self registerForDraggedTypes:@[ kKKReorderDragType ]];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSSize)intrinsicContentSize {
  CGFloat h = _ids.count
                  ? (CGFloat)_ids.count * kRowStride - kRowGap + 2 * kListPad
                  : 0.0;
  return NSMakeSize(kListWidth, h);
}

- (_KKReorderRow *)_makeRowWithTitle:(NSString *)title index:(NSInteger)idx {
  _KKReorderRow *row = [[_KKReorderRow alloc] initWithFrame:NSZeroRect];
  row.index = idx;
  row.wantsLayer = YES;
  row.layer.cornerRadius = KKRadiusMD; // match the timeline container's radius
  row.layer.backgroundColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.06].CGColor;

  NSImageView *grip = [NSImageView
      imageViewWithImage:[NSImage imageWithSystemSymbolName:@"line.3.horizontal"
                                   accessibilityDescription:nil]];
  grip.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.5];
  grip.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:grip];

  NSTextField *label = [NSTextField labelWithString:title];
  label.font = [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightMedium];
  label.textColor = [NSColor inspectorLabel];
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:label];

  [NSLayoutConstraint activateConstraints:@[
    [grip.leadingAnchor constraintEqualToAnchor:row.leadingAnchor
                                       constant:KKPaddingMD],
    [grip.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [label.leadingAnchor constraintEqualToAnchor:grip.trailingAnchor
                                        constant:KKSpacingMD],
    [label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
  ]];
  return row;
}

- (void)layout {
  [super layout];
  [self _positionRows];
}

- (void)_positionRows {
  CGFloat w = NSWidth(self.bounds);
  for (NSInteger i = 0; i < (NSInteger)_rows.count; i++) {
    _rows[i].index = i;
    _rows[i].frame =
        NSMakeRect(0, kListPad + (CGFloat)i * kRowStride, w, kRowH);
  }
}

- (NSInteger)_dropIndexForPoint:(NSPoint)loc {
  CGFloat frac = (loc.y - kListPad) / kRowStride;
  NSInteger hover = (NSInteger)floor(frac);
  BOOL topHalf = (frac - floor(frac)) < 0.5;
  NSInteger target = topHalf ? hover : hover + 1;
  return MAX(0, MIN(target, (NSInteger)_rows.count));
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return [self draggingUpdated:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  NSInteger target =
      [self _dropIndexForPoint:[self convertPoint:sender.draggingLocation
                                         fromView:nil]];
  if (target != _dropIndex) {
    _dropIndex = target;
    [self _updateDropIndicator];
  }
  return NSDragOperationMove;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
  _dropIndex = -1;
  [_dropIndicator removeFromSuperview];
}

- (void)_updateDropIndicator {
  if (_dropIndex < 0) {
    [_dropIndicator removeFromSuperview];
    return;
  }
  if (!_dropIndicator) {
    _dropIndicator = [[NSView alloc] initWithFrame:NSZeroRect];
    _dropIndicator.wantsLayer = YES;
    _dropIndicator.layer.backgroundColor = [NSColor accentMatchingHost].CGColor;
    _dropIndicator.layer.cornerRadius = 1.0;
  }
  if (_dropIndicator.superview != self)
    [self addSubview:_dropIndicator];
  CGFloat y = kListPad + (CGFloat)_dropIndex * kRowStride - kRowGap * 0.5;
  _dropIndicator.frame = NSMakeRect(
      KKPaddingMD, y - 1.0, NSWidth(self.bounds) - 2 * KKPaddingMD, 2.0);
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
  return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSInteger target = _dropIndex;
  _dropIndex = -1;
  [_dropIndicator removeFromSuperview];
  if (target < 0)
    return NO;
  NSString *s = [sender.draggingPasteboard stringForType:kKKReorderDragType];
  if (!s)
    return NO;
  NSInteger src = s.integerValue;
  if (src < 0 || src >= (NSInteger)_ids.count)
    return NO;
  // Removing the source shifts everything after it down by one, so a forward
  // move lands one slot earlier than the raw insertion point.
  NSInteger dst = (src < target) ? target - 1 : target;
  if (dst == src)
    return NO; // no-op drop - don't fire (avoids a phantom undo entry)

  NSString *movedID = _ids[src];
  _KKReorderRow *movedRow = _rows[src];
  [_ids removeObjectAtIndex:src];
  [_rows removeObjectAtIndex:src];
  [_ids insertObject:movedID atIndex:dst];
  [_rows insertObject:movedRow atIndex:dst];
  [self _positionRows];
  if (self.onReorder)
    self.onReorder([_ids copy]);
  return YES;
}

@end
