/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideOverlayView_Private.h"
#import "KKTokens.h"
#import <QuartzCore/QuartzCore.h>

static NSColor *KJActionGreen(void) {
  return [NSColor colorWithRed:0.12 green:0.72 blue:0.36 alpha:1.0];
}

static const CGFloat kJTipPadH = 10.0;
static const CGFloat kJTipPadV = 8.0;
static const CGFloat kJTipArrowH = 6.0;
static const CGFloat kJTipArrowHalfW = 5.0;
static const CGFloat kJTipRowGap = 6.0;
static const CGFloat kJTipBottomRowH = 18.0;

@implementation _KKJoyrideOverlayView (Drawing)

// Pulsing amber halo around the drag target, on top of the dim cutout so it
// reads as glowing rather than a flat colour. Radius + alpha breathe at
// ~1.1 Hz; outer rings expand more than inner for a soft bloom.
- (void)_drawTargetGlow {
  NSRect t = [self _pillSecondaryLocalRect];
  if (NSIsEmptyRect(t))
    return;
  NSPoint c = NSMakePoint(NSMidX(t), NSMidY(t));
  // Size the glow to the OSC dot, not the (much larger) spotlight/cutout rect
  // the pill block hands back. Small fixed core with a modest pulse bloom.
  CGFloat base = 6.0;
  double p = 0.5 + 0.5 * sin(CACurrentMediaTime() * 2.0 * M_PI * 1.1);
  NSColor *amber = [NSColor colorWithRed:1.0 green:0.78 blue:0.24 alpha:1.0];
  const int rings = 4;
  for (int i = rings; i >= 1; i--) {
    CGFloat frac = (CGFloat)i / rings;
    CGFloat rr = base + frac * (4.0 + p * 7.0);
    CGFloat a = (0.12 + 0.20 * p) * (1.0 - frac * 0.6);
    [[amber colorWithAlphaComponent:a] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - rr, c.y - rr,
                                                       rr * 2, rr * 2)] fill];
  }
  CGFloat coreR = base + 1.0;
  NSBezierPath *core = [NSBezierPath
      bezierPathWithOvalInRect:NSMakeRect(c.x - coreR, c.y - coreR, coreR * 2,
                                          coreR * 2)];
  core.lineWidth = 2.0;
  [[amber colorWithAlphaComponent:0.45 + 0.45 * p] setStroke];
  [core stroke];
}

- (NSBezierPath *)_pillPathFrom:(NSRect)r1 to:(NSRect)r2 {
  NSPoint c1 = NSMakePoint(NSMidX(r1), NSMidY(r1));
  NSPoint c2 = NSMakePoint(NSMidX(r2), NSMidY(r2));
  CGFloat r = MIN(fabs(NSWidth(r1)), fabs(NSHeight(r1))) / 2.0;
  CGFloat dx = c2.x - c1.x;
  CGFloat dy = c2.y - c1.y;
  CGFloat dist = sqrt(dx * dx + dy * dy);
  if (dist < 1.0) {
    return [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c1.x - r, c1.y - r,
                                                             r * 2.0, r * 2.0)];
  }
  CGFloat angle = atan2f((float)dy, (float)dx);
  CGFloat midX = (c1.x + c2.x) / 2.0;
  CGFloat midY = (c1.y + c2.y) / 2.0;
  CGFloat halfW = dist / 2.0 + r;
  CGRect localRect = CGRectMake(-halfW, -r, halfW * 2.0, r * 2.0);
  // Rotate in local space then translate to midpoint.
  // CGAffineTransformTranslate(R, tx, ty) rotates (tx,ty) by R which is wrong;
  // CGAffineTransformConcat(R, T) means "apply R first, then T" which is
  // correct.
  CGAffineTransform t =
      CGAffineTransformConcat(CGAffineTransformMakeRotation(angle),
                              CGAffineTransformMakeTranslation(midX, midY));
  CGPathRef localPill = CGPathCreateWithRoundedRect(localRect, r, r, nil);
  CGPathRef pillPath = CGPathCreateCopyByTransformingPath(localPill, &t);
  CGPathRelease(localPill);
  NSBezierPath *result = [NSBezierPath bezierPathWithCGPath:pillPath];
  CGPathRelease(pillPath);
  return result;
}

- (void)_drawSpotlightCutout:(NSRect)paddedSpot {
  NSBezierPath *bgPath = [NSBezierPath bezierPath];
  [bgPath appendBezierPathWithRect:self.bounds];

  NSRect pillSecondary = NSZeroRect;
  if (_pillToScreenRectBlock) {
    NSRect sr = _pillToScreenRectBlock();
    if (!NSIsEmptyRect(sr) && self.window) {
      NSRect wr = [self.window convertRectFromScreen:sr];
      NSRect local = [self convertRect:wr fromView:nil];
      pillSecondary = NSInsetRect(local, -8.0, -3.0);
    }
  }

  if (!NSIsEmptyRect(pillSecondary)) {
    [bgPath appendBezierPath:[self _pillPathFrom:paddedSpot to:pillSecondary]];
  } else if (_spotlightCircular) {
    CGFloat side = MIN(fabs(NSWidth(paddedSpot)), fabs(NSHeight(paddedSpot)));
    NSRect square = NSMakeRect(NSMidX(paddedSpot) - side / 2.0,
                               NSMidY(paddedSpot) - side / 2.0, side, side);
    [bgPath appendBezierPathWithOvalInRect:square];
  } else {
    [bgPath appendBezierPathWithRoundedRect:paddedSpot xRadius:7.0 yRadius:7.0];
  }
  bgPath.windingRule = NSWindingRuleEvenOdd;
  [[NSColor colorWithWhite:0.0 alpha:0.35] setFill];
  [bgPath fill];
}

- (void)_drawBubble:(NSRect)bubble
               midX:(CGFloat)midX
          drawBelow:(BOOL)drawBelow {
  [[NSColor colorWithWhite:0.18 alpha:1.0] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:bubble xRadius:6.0
                                   yRadius:6.0] fill];

  NSBezierPath *arrow = [NSBezierPath bezierPath];
  if (drawBelow) {
    [arrow moveToPoint:NSMakePoint(midX - kJTipArrowHalfW, NSMinY(bubble))];
    [arrow lineToPoint:NSMakePoint(midX + kJTipArrowHalfW, NSMinY(bubble))];
    [arrow lineToPoint:NSMakePoint(midX, NSMinY(bubble) - kJTipArrowH)];
  } else {
    [arrow moveToPoint:NSMakePoint(midX - kJTipArrowHalfW, NSMaxY(bubble))];
    [arrow lineToPoint:NSMakePoint(midX + kJTipArrowHalfW, NSMaxY(bubble))];
    [arrow lineToPoint:NSMakePoint(midX, NSMaxY(bubble) + kJTipArrowH)];
  }
  [arrow closePath];
  [[NSColor colorWithWhite:0.18 alpha:1.0] setFill];
  [arrow fill];
}

- (void)_drawBubbleAnchoredAt:(NSRect)paddedSpot {
  NSSize textSz = _attributedMessage ? [_attributedMessage size] : NSZeroSize;

  BOOL hasSteps = _step > 0 && _totalSteps > 0;
  NSString *stepStr = hasSteps
                          ? [NSString stringWithFormat:@"%ld/%ld", (long)_step,
                                                       (long)_totalSteps]
                          : @"";
  NSFont *stepFont = [NSFont systemFontOfSize:KKFontSizeSM - 1.0
                                       weight:NSFontWeightRegular];
  NSDictionary *stepAttrs = @{
    NSFontAttributeName : stepFont,
    NSForegroundColorAttributeName : [NSColor colorWithWhite:1.0 alpha:0.4],
  };
  NSSize stepSz =
      stepStr.length > 0 ? [stepStr sizeWithAttributes:stepAttrs] : NSZeroSize;

  CGFloat minW = 0.0;
  if (hasSteps) {
    NSFont *actionFont = [NSFont systemFontOfSize:KKFontSizeSM
                                           weight:NSFontWeightMedium];
    BOOL isLastStep = _step == _totalSteps;
    BOOL showsNext = !isLastStep && self.onNext != nil;
    NSString *actionStr = isLastStep ? @"Done" : @"Skip";
    CGFloat actionW =
        [actionStr sizeWithAttributes:@{NSFontAttributeName : actionFont}]
            .width;
    CGFloat nextW =
        showsNext
            ? [@"Next" sizeWithAttributes:@{NSFontAttributeName : actionFont}]
                      .width +
                  16.0
            : 0.0;
    minW = kJTipPadH + stepSz.width + 16.0 + actionW + nextW + kJTipPadH;
  }
  CGFloat bubbleW = MAX(textSz.width + kJTipPadH * 2.0, minW);
  CGFloat bubbleH = hasSteps ? kJTipPadV + textSz.height + kJTipRowGap +
                                   kJTipBottomRowH + kJTipPadV
                             : kJTipPadV + textSz.height + kJTipPadV;

  CGFloat midX = MAX(bubbleW / 2.0 + KKPaddingMD,
                     MIN(NSMaxX(self.bounds) - bubbleW / 2.0 - KKPaddingMD,
                         NSMidX(paddedSpot)));
  CGFloat bubbleX = midX - bubbleW / 2.0;

  CGFloat bubbleYAbove = NSMinY(paddedSpot) - kJTipArrowH - bubbleH - 4.0;
  BOOL drawBelow = bubbleYAbove < 4.0;
  CGFloat bubbleY =
      drawBelow ? NSMaxY(paddedSpot) + kJTipArrowH + 4.0 : bubbleYAbove;
  NSRect bubbleRect = NSMakeRect(bubbleX, bubbleY, bubbleW, bubbleH);

  [self _drawBubble:bubbleRect midX:midX drawBelow:drawBelow];
  [_attributedMessage
      drawAtPoint:NSMakePoint(bubbleX + kJTipPadH, bubbleY + kJTipPadV)];

  if (hasSteps) {
    CGFloat bottomRowTop = bubbleY + kJTipPadV + textSz.height + kJTipRowGap;
    [self _drawStepRowInBubble:bubbleRect
                  bottomRowTop:bottomRowTop
                          midX:midX
                       stepStr:stepStr
                     stepAttrs:stepAttrs];
  } else {
    _actionRect = NSZeroRect;
    _nextRect = NSZeroRect;
  }
}

- (void)_drawStepRowInBubble:(NSRect)bubble
                bottomRowTop:(CGFloat)bottomRowTop
                        midX:(CGFloat)midX
                     stepStr:(NSString *)stepStr
                   stepAttrs:(NSDictionary *)stepAttrs {
  CGFloat centerY = bottomRowTop + kJTipBottomRowH / 2.0;

  if (stepStr.length > 0) {
    NSSize stepSz = [stepStr sizeWithAttributes:stepAttrs];
    [stepStr drawAtPoint:NSMakePoint(NSMinX(bubble) + kJTipPadH,
                                     centerY - stepSz.height / 2.0)
          withAttributes:stepAttrs];
  }

  BOOL isLast = _step == _totalSteps;
  BOOL showsNext = !isLast && self.onNext != nil;

  NSString *actionStr = isLast ? @"Done" : @"Skip";
  NSColor *actionColor =
      isLast ? KJActionGreen() : [NSColor colorWithWhite:1.0 alpha:0.55];
  NSDictionary *actionAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : actionColor,
  };
  NSSize actionSz = [actionStr sizeWithAttributes:actionAttrs];

  if (showsNext) {
    NSDictionary *nextAttrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : KJActionGreen(),
    };
    NSSize nextSz = [@"Next" sizeWithAttributes:nextAttrs];
    CGFloat nextX = NSMaxX(bubble) - kJTipPadH - nextSz.width;
    [@"Next" drawAtPoint:NSMakePoint(nextX, centerY - nextSz.height / 2.0)
          withAttributes:nextAttrs];
    _nextRect = NSMakeRect(nextX - 8.0, NSMinY(bubble),
                           nextSz.width + 8.0 + kJTipPadH, NSHeight(bubble));

    CGFloat actionX = nextX - 16.0 - actionSz.width;
    [actionStr drawAtPoint:NSMakePoint(actionX, centerY - actionSz.height / 2.0)
            withAttributes:actionAttrs];
    _actionRect = NSMakeRect(actionX - 4.0, NSMinY(bubble),
                             actionSz.width + 8.0, NSHeight(bubble));
  } else {
    _nextRect = NSZeroRect;
    CGFloat actionX = NSMaxX(bubble) - kJTipPadH - actionSz.width;
    [actionStr drawAtPoint:NSMakePoint(actionX, centerY - actionSz.height / 2.0)
            withAttributes:actionAttrs];
    _actionRect =
        NSMakeRect(actionX - 8.0, NSMinY(bubble),
                   actionSz.width + 8.0 + kJTipPadH, NSHeight(bubble));
  }
}

- (void)drawRect:(NSRect)dirty {
  NSRect spotRect =
      (_frozen && _haveLastSpot) ? _lastSpotRect : [self spotRectInSelf];
  if (NSIsEmptyRect(spotRect)) {
    if (_frozen)
      return; // tearing down — don't pop the centred fallback in
    if (_drawsBackground) {
      [[NSColor colorWithWhite:0.0 alpha:0.35] setFill];
      NSRectFill(self.bounds);
    }
    if (_message) {
      // No spotlight target — draw a floating bubble near the top of the
      // screen so steps that require viewer interaction still show guidance.
      NSRect synthetic = NSMakeRect(NSMidX(self.bounds) - 1, 200.0, 2, 2);
      [self _drawBubbleAnchoredAt:NSInsetRect(synthetic, -8.0, -3.0)];
    }
    return;
  }
  if (spotRect.size.height < 1.0 || spotRect.size.width < 1.0)
    return;

  _lastSpotRect = spotRect;
  _haveLastSpot = YES;
  NSRect paddedSpot = NSInsetRect(spotRect, -8.0, -3.0);
  if (_drawsBackground)
    [self _drawSpotlightCutout:paddedSpot];
  [self _drawTargetGlow];
  if (!_message) {
    _actionRect = NSZeroRect;
    _nextRect = NSZeroRect;
    return;
  }
  [self _drawBubbleAnchoredAt:paddedSpot];
}

@end
