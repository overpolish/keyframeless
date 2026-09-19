/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFKeyposeMap_Private.h"

// A press on a keypose selects it, as a click on a host keyframe marker does,
// and turns into a retime once the pointer travels far enough for the movement
// to be deliberate. A press anywhere else on the rail drags the playhead.
static const CGFloat KFKeyposeDragThreshold = 3;

@implementation KFKeyposeMap (Interaction)
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.tracking) [self removeTrackingArea:self.tracking];
  self.tracking = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                   NSTrackingActiveAlways | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseMoved:(NSEvent *)event {
  [self hoverAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}
- (void)mouseExited:(NSEvent *)event { self.hoveredIndex = -1; }
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) return;
  self.hoveredIndex = -1;
  self.scrubbing = NO;
  [self endDrag];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  [self hoverAtPoint:point];
  NSInteger index = [self indexAtPoint:point];
  if (index >= 0) {
    self.pressedIndex = index;
    self.pressedPosition = point.x;
    if (self.onSelect) self.onSelect(self.stops[index].time);
    return;
  }
  if (![self isScrubPoint:point] || !self.onScrub) return;
  self.scrubbing = YES;
  self.onScrub([self fractionAtX:point.x]);
}
- (void)mouseDragged:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (self.scrubbing) {
    self.onScrub([self fractionAtX:point.x]);
    return;
  }
  if (self.pressedIndex < 0 || !self.onRetimeDrag) return;
  if (self.dragIndex < 0 &&
      fabs(point.x - self.pressedPosition) < KFKeyposeDragThreshold)
    return;
  self.dragIndex = self.pressedIndex;
  CGFloat position = [self draggablePosition:point.x forIndex:self.dragIndex];
  NSString *label =
      self.onRetimeDrag(self.dragIndex,
                        [self timeAtPosition:position forIndex:self.dragIndex]);
  // A refused position leaves the preview on the last time the editor accepted,
  // so the keypose never previews a time the commit would not write.
  if (!label.length) return;
  self.dragPosition = position;
  self.dragLabel = label;
}
- (void)mouseUp:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  if (self.scrubbing) {
    self.scrubbing = NO;
    self.onScrub([self fractionAtX:point.x]);
    if (self.onScrubEnd) self.onScrubEnd();
  } else if (self.dragIndex >= 0) {
    // Commit the previewed position rather than the pointer, which may sit
    // past a clamp or on a time the editor refused.
    NSInteger index = self.dragIndex;
    CMTime target = [self timeAtPosition:self.dragPosition forIndex:index];
    void (^commit)(NSInteger, CMTime) = self.onRetimeCommit;
    [self endDrag];
    if (commit) commit(index, target);
  }
  self.pressedIndex = -1;
  [self hoverAtPoint:point];
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  if (!self.menuProvider) return [super menuForEvent:event];
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  return self.menuProvider([self indexAtPoint:point], [self timeAtPosition:point.x]);
}
@end
