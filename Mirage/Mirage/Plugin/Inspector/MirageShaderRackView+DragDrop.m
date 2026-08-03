/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Click and reorder-drag for the rack boxes, the arrow between them, and the
// document view that draws the insertion line. The rack is FLAT - no groups, no
// nesting - so the drop target is a plain index and the line is a full-height
// bar between two boxes.

#import "MirageShaderRackView_Internal.h"

#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

NSPasteboardType const kMirageRackBoxDragType =
    @"com.keyframeless.mirage.rackboxes";

@implementation MirageRackBox {
  NSPoint _downPoint;
  BOOL _dragging;
}

// A borderless companion / a ViewBridge-hosted popover delivers clicks as
// first-mouse events, so the box has to opt in or the first click on an
// unfocused inspector is swallowed.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  _dragging = NO;
  _downPoint = event.locationInWindow;
  if (![self.owner isBoxSelected:self.boxIndex])
    [self.owner selectBoxAtIndex:self.boxIndex];
}

- (void)mouseDragged:(NSEvent *)event {
  if (_dragging)
    return;
  NSPoint p = event.locationInWindow;
  if (hypot(p.x - _downPoint.x, p.y - _downPoint.y) < kMirageRackDragThreshold)
    return;
  _dragging = YES;
  NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
  [item setString:@(self.boxIndex).stringValue forType:kMirageRackBoxDragType];
  NSDraggingItem *di = [[NSDraggingItem alloc] initWithPasteboardWriter:item];
  [di setDraggingFrame:self.bounds contents:[self _snapshot]];
  [self beginDraggingSessionWithItems:@[ di ] event:event source:self];
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

@implementation MirageRackConnectorView

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    // The glyph is centred in the view's own box-height bounds, and never
    // stretched: a scaled arrow between two 28pt boxes reads as a different
    // weight of line at every rack length.
    self.imageScaling = NSImageScaleNone;
    self.imageAlignment = NSImageAlignCenter;
    self.contentTintColor = NSColor.secondaryLabelColor;
  }
  return self;
}

// The arrow keeps the same glyph when the shader feeding it is bypassed and
// only loses ink. A second symbol here would collide with the preview controls
// on the boxes, which are what the arrow-family glyphs mean in this strip.
- (void)setDimmed:(BOOL)dimmed {
  if (_dimmed == dimmed)
    return;
  _dimmed = dimmed;
  self.contentTintColor =
      dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor;
}

// Never a click target: a press between two boxes belongs to neither, and
// swallowing it would break a drag started just off a box edge.
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}

@end

@implementation MirageRackDocView {
  NSView *_dropLine;
  NSInteger _dropIndex;
}

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _dropIndex = -1;
    [self registerForDraggedTypes:@[ kMirageRackBoxDragType ]];
  }
  return self;
}

- (NSView *)_dropLineView {
  if (!_dropLine) {
    _dropLine = [[NSView alloc] initWithFrame:NSZeroRect];
    _dropLine.wantsLayer = YES;
    _dropLine.layer.backgroundColor = [NSColor accentMatchingHost].CGColor;
    _dropLine.layer.cornerRadius = 1.0;
    _dropLine.hidden = YES;
    [self addSubview:_dropLine];
  }
  return _dropLine;
}

- (NSInteger)_draggedBoxFrom:(id<NSDraggingInfo>)sender {
  NSString *value =
      [sender.draggingPasteboard stringForType:kMirageRackBoxDragType];
  return value.length ? value.integerValue : -1;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return [self draggingUpdated:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  if ([self _draggedBoxFrom:sender] < 0) {
    _dropLine.hidden = YES;
    _dropIndex = -1;
    return NSDragOperationNone;
  }
  NSPoint p = [self convertPoint:sender.draggingLocation fromView:nil];
  CGFloat x = 0;
  [self.owner computeDropForDocPoint:p outFlatIndex:&_dropIndex outLineX:&x];
  NSView *line = [self _dropLineView];
  CGFloat inset = (self.bounds.size.height - kMirageRackBoxHeight) / 2.0;
  line.frame = NSMakeRect(x - 1.0, inset, 2.0, kMirageRackBoxHeight);
  line.hidden = NO;
  [self addSubview:line positioned:NSWindowAbove relativeTo:nil];
  return NSDragOperationMove;
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
  NSInteger from = [self _draggedBoxFrom:sender];
  NSInteger to = _dropIndex;
  _dropIndex = -1;
  if (from < 0 || to < 0)
    return NO;
  [self.owner performBoxMoveFromIndex:from toFlatIndex:to];
  return YES;
}

@end

@implementation MirageShaderRackView (DragDrop)

- (NSArray<MirageRackBox *> *)orderedBoxViews {
  return [_boxViews copy];
}

- (void)computeDropForDocPoint:(NSPoint)point
                  outFlatIndex:(NSInteger *)outFlatIndex
                      outLineX:(CGFloat *)outLineX {
  NSArray<MirageRackBox *> *boxes = [self orderedBoxViews];
  NSInteger flat = (NSInteger)boxes.count;
  CGFloat lineX = 0;
  CGFloat gap = (KKSpacingSM + kMirageRackConnectorWidth) / 2.0;
  for (MirageRackBox *box in boxes) {
    NSRect fr = [box convertRect:box.bounds toView:_doc];
    if (point.x >= NSMaxX(fr))
      continue;
    BOOL leadingHalf = point.x < NSMidX(fr);
    flat = box.boxIndex + (leadingHalf ? 0 : 1);
    lineX = leadingHalf ? NSMinX(fr) - gap : NSMaxX(fr) + gap;
    break;
  }
  if (flat == (NSInteger)boxes.count && boxes.count)
    lineX = NSMaxX([boxes.lastObject convertRect:boxes.lastObject.bounds
                                          toView:_doc]) +
            gap;
  if (outFlatIndex)
    *outFlatIndex = flat;
  if (outLineX)
    *outLineX = lineX;
}

// The move leaves through the host, which owns the registry the order lives in.
// Nothing is reordered locally first: the boxes come back through
// -applyEntries:selected: once the mutation has landed, so a refused move (the
// drop that changes nothing) simply redraws what is already there.
- (void)performBoxMoveFromIndex:(NSInteger)fromIndex
                    toFlatIndex:(NSInteger)toIndex {
  if (fromIndex < 0 || (NSUInteger)fromIndex >= _entries.count)
    return;
  if (toIndex == fromIndex || toIndex == fromIndex + 1)
    return;
  MirageRackEntry *entry = _entries[(NSUInteger)fromIndex];
  if (self.onMoveEntry)
    self.onMoveEntry(entry.entryID, toIndex);
}

@end
