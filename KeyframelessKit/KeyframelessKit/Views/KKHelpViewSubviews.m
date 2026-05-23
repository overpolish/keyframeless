/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHelpViewSubviews.h"
#import "../Style/NSColor+KKColors.h"
#import "KKHelpView_Private.h"

@implementation _KKGuideStartButton
- (void)mouseDown:(NSEvent *)event {
  if (_actionBlock)
    _actionBlock();
}
- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
@end

@implementation KKHelpShortcutsGrid

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  if (self.numberOfRows < 2)
    return;

  NSColor *line = [[NSColor inspectorLabel] colorWithAlphaComponent:0.10];
  [line setStroke];
  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineWidth = 1.0;

  for (NSInteger r = 0; r < self.numberOfRows - 1; r++) {
    NSView *aCell = [self cellAtColumnIndex:0 rowIndex:r].contentView;
    NSView *bCell = [self cellAtColumnIndex:0 rowIndex:r + 1].contentView;
    if (!aCell || !bCell)
      continue;
    CGFloat yBottomA = NSMinY(aCell.frame);
    CGFloat yTopB = NSMaxY(bCell.frame);
    CGFloat y = (yBottomA + yTopB) * 0.5;
    [path moveToPoint:NSMakePoint(0, y)];
    [path lineToPoint:NSMakePoint(self.bounds.size.width, y)];
  }
  [path stroke];
}

@end

@implementation KKHelpBackgroundView

- (BOOL)isFlipped {
  return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor inspectorBackground] setFill];
  NSRectFill(self.bounds);

  NSBundle *bundle = [NSBundle bundleForClass:[KKHelpBackgroundView class]];
  NSImage *logo = [[NSImage alloc]
      initByReferencingFile:[bundle pathForResource:@"keyframeless-logo"
                                             ofType:@"png"]];
  if (!logo)
    return;

  CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height) * 0.9;
  NSGraphicsContext *gc = [NSGraphicsContext currentContext];
  [gc saveGraphicsState];

  NSAffineTransform *t = [NSAffineTransform transform];
  // Tuck the logo into the bottom-right corner with a slice peeking past
  // the right edge.
  [t translateXBy:self.bounds.size.width - side * 0.75 yBy:-side * 0.25];
  [t rotateByDegrees:-18.0];
  [t concat];

  NSRect target = NSMakeRect(0, 0, side, side);
  [logo drawInRect:target
          fromRect:NSZeroRect
         operation:NSCompositingOperationSourceOver
          fraction:0.06];

  [gc restoreGraphicsState];
}

@end

@implementation KKHelpTOCLink
- (void)mouseDown:(NSEvent *)event {
  NSView *doc = self.documentHost;
  NSView *anchor = self.anchorView;
  NSScrollView *sv = doc.enclosingScrollView;
  NSClipView *clip = sv.contentView;
  if (!doc || !anchor || !sv || !clip)
    return;
  // Compute the anchor's top edge in clip-view coordinates (the clip is
  // flipped, so smaller y = visually higher), then translate to a new
  // bounds origin. Doing it via the clip rather than `scrollPoint:`
  // sidesteps the doc-flipped vs. clip-flipped mismatch (page stack is
  // non-flipped, so NSMinY of a section frame in doc coords is the
  // section's *bottom*, which is why scrollPoint was landing wrong).
  NSRect inClip = [clip convertRect:anchor.bounds fromView:anchor];
  CGFloat newY =
      clip.bounds.origin.y + NSMinY(inClip) - KKHelpPagePadding * 0.5;
  if (newY < 0)
    newY = 0;
  [clip setBoundsOrigin:NSMakePoint(clip.bounds.origin.x, newY)];
  [sv reflectScrolledClipView:clip];
}
- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
@end

@implementation _KKCapsuleView
- (void)layout {
  [super layout];
  self.layer.cornerRadius = NSHeight(self.bounds) / 2.0;
}
@end

@implementation _KKGuideRowRefs
@end
