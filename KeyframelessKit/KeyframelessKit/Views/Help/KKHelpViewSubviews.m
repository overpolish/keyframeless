/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHelpViewSubviews.h"
#import "KKHelpView_Private.h"
#import "NSColor+KKColors.h"

@implementation _KKGuideStartButton
- (void)mouseDown:(NSEvent *)event {
  if (_actionBlock)
    _actionBlock();
}
- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
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

@implementation _KKCapsuleView
- (void)layout {
  [super layout];
  self.layer.cornerRadius = NSHeight(self.bounds) / 2.0;
}
@end

@implementation _KKGuideRowRefs
@end
