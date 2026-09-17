/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ICValueTextField+Scrub.h"
#import "ICValueTextField_Private.h"
#import <CoreGraphics/CoreGraphics.h>

static const CGFloat kICScrubStartThreshold = 3.0;
static const CGFloat kICScrubPointsPerStep = 4.0;
static const double kICScrubCoarseMultiplier = 10.0;
static const double kICScrubFineMultiplier = 0.1;

NSInteger ICScrubWholeStepsForTravel(CGFloat travel) {
  return (NSInteger)(travel / kICScrubPointsPerStep);
}

static NSCursor *ICBlankCursor(void) {
  static NSCursor *blank;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    blank = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
  });
  return blank;
}

@implementation ICValueTextField (Scrub)
- (void)scrubBy:(double)delta {
  double old=self.doubleValue, value=old+delta;
  if([self.formatter isKindOfClass:NSNumberFormatter.class]) {
    NSNumberFormatter *formatter=(NSNumberFormatter *)self.formatter;
    if(formatter.minimum) value=fmax(value,formatter.minimum.doubleValue);
    if(formatter.maximum) value=fmin(value,formatter.maximum.doubleValue);
  }
  // Formatter bounds normally validate typed text; programmatic drag values
  // need the same bounds before dispatch, without rejecting/beeping at an edge.
  if(!isfinite(value) || value==old) return;
  self.doubleValue=value;
  [self sendAction:self.action to:self.target];
}

- (void)trackScrubFromMouseDown:(NSEvent *)event {
  double step = self.scrubStep > 0 ? self.scrubStep : 1.0;
  CGFloat residual = 0, startTravel = 0;
  BOOL scrubbing = NO;
  NSPoint anchor = NSEvent.mouseLocation;
  CGFloat screenHeight = NSScreen.screens.count ? NSHeight(NSScreen.screens.firstObject.frame) : 0;
  CGPoint anchorCG = CGPointMake(anchor.x, screenHeight - anchor.y);
  NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
  @try {
    while (YES) {
      NSEvent *event = [self.window nextEventMatchingMask:mask];
      if (!event || event.type == NSEventTypeLeftMouseUp) break;
      CGFloat delta = event.deltaX - event.deltaY;
      if (!scrubbing) {
        startTravel += delta;
        if (fabs(startTravel) < kICScrubStartThreshold) continue;
        scrubbing = YES;
        self.icScrubbing = YES;
        CGAssociateMouseAndMouseCursorPosition(false);
        if (self.onScrubBegin) self.onScrubBegin();
      }
      [ICBlankCursor() set];
      double multiplier = 1.0;
      if (event.modifierFlags & NSEventModifierFlagShift) multiplier *= kICScrubCoarseMultiplier;
      if (event.modifierFlags & NSEventModifierFlagOption) multiplier *= kICScrubFineMultiplier;
      residual += delta;
      NSInteger steps = ICScrubWholeStepsForTravel(residual);
      if (steps) {
        residual -= (CGFloat)steps * kICScrubPointsPerStep;
        [self scrubBy:(double)steps * step * multiplier];
      }
      if (screenHeight > 0) CGWarpMouseCursorPosition(anchorCG);
    }
  } @finally {
    if (scrubbing) {
      if (screenHeight > 0) CGWarpMouseCursorPosition(anchorCG);
      CGAssociateMouseAndMouseCursorPosition(true);
      [[NSCursor arrowCursor] set];
      @try {
        if (self.onScrubEnd) self.onScrubEnd();
      } @finally {
        self.icScrubbing = NO;
      }
    }
  }
  if (!scrubbing) {
    self.userClickPending = YES;
    self.inMouseDown = YES;
    if ([self.window makeFirstResponder:self]) [self selectText:nil];
    self.inMouseDown = NO;
  }
}
@end
