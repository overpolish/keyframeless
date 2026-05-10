/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKStagePlayheadView.h"
#import "../../Style/KKTokens.h"
#import "KKStageSequencerView_Private.h"

static void _drawPlayheadKnob(CGFloat cx, CGFloat topY, NSColor *color) {
  static const CGFloat w = 9.5;
  static const CGFloat h = 10.0;
  static const CGFloat cr = 1.5;
  static const CGFloat pointRatio = 0.5;
  static const CGFloat curveOff = 0.5;
  static const CGFloat curveCtl = 1.0;
  static const CGFloat sideRatio = 0.3;

  CGFloat left = cx - w / 2.0;
  CGFloat right = cx + w / 2.0;
  CGFloat top = topY;
  CGFloat bottom = topY - h;
  CGFloat midX = cx;
  CGFloat pointH = h * pointRatio;
  CGFloat pointBaseY = top - (h - pointH);

  NSBezierPath *path = [NSBezierPath bezierPath];
  [path moveToPoint:NSMakePoint(left + cr, top)];
  [path lineToPoint:NSMakePoint(right - cr, top)];
  [path appendBezierPathWithArcFromPoint:NSMakePoint(right, top)
                                 toPoint:NSMakePoint(right, top - cr)
                                  radius:cr];
  [path lineToPoint:NSMakePoint(right, pointBaseY)];
  [path curveToPoint:NSMakePoint(midX, bottom)
       controlPoint1:NSMakePoint(right - curveOff,
                                 pointBaseY - pointH * sideRatio)
       controlPoint2:NSMakePoint(midX + curveCtl, bottom + curveOff)];
  [path curveToPoint:NSMakePoint(left, pointBaseY)
       controlPoint1:NSMakePoint(midX - curveCtl, bottom + curveOff)
       controlPoint2:NSMakePoint(left + curveOff,
                                 pointBaseY - pointH * sideRatio)];
  [path lineToPoint:NSMakePoint(left, top - cr)];
  [path appendBezierPathWithArcFromPoint:NSMakePoint(left, top)
                                 toPoint:NSMakePoint(left + cr, top)
                                  radius:cr];
  [path closePath];

  [color setFill];
  [path fill];
  [[NSColor colorWithWhite:0.08 alpha:1.0] setStroke];
  path.lineWidth = 0.5;
  [path stroke];
}

@implementation KKStagePlayheadView

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    _zoom = 1.0;
    _playheadFraction = -1.0;
  }
  return self;
}

- (NSView *)hitTest:(NSPoint)point {
  return nil;
}

- (void)setPlayheadFraction:(double)f {
  if (fabs(_playheadFraction - f) < 0.0001)
    return;
  _playheadFraction = f;
  [self setNeedsDisplay:YES];
}

- (void)setZoom:(CGFloat)zoom {
  if (fabs(_zoom - zoom) < 0.0001)
    return;
  _zoom = zoom;
  [self setNeedsDisplay:YES];
}

- (void)setPanOffset:(CGFloat)pan {
  if (fabs(_panOffset - pan) < 0.0001)
    return;
  _panOffset = pan;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  // Reject NaN/inf — comparisons against NaN are false, so the range guard
  // alone leaks bad fractions through to NSBezierPath which then throws.
  if (!isfinite(_playheadFraction) || !isfinite(_panOffset) || !isfinite(_zoom))
    return;
  if (_playheadFraction < 0 || _playheadFraction > 1)
    return;
  CGFloat viewW = NSWidth(self.bounds);
  CGFloat viewH = NSHeight(self.bounds);
  CGFloat trackX = kKSSBorderInset + kKSSLabelWidth;
  CGFloat trackW =
      viewW - 2 * kKSSBorderInset - kKSSLabelWidth - kKSSLabelPadding;
  if (trackW < 1)
    return;

  CGFloat x = trackX + (_playheadFraction - _panOffset) * _zoom * trackW;
  if (!isfinite(x))
    return;
  if (x < trackX - 0.5 || x > trackX + trackW + 0.5)
    return;

  // Line spans from the bottom of the view up to the bottom of the ruler.
  // Knob sits with its flat edge at the top of the ruler; its point reaches
  // down to the same Y as the line top, producing a single continuous shape.
  CGFloat rulerTop = viewH - _topPadding;
  CGFloat rulerBottom = rulerTop - _rulerHeight;
  NSColor *c = [NSColor colorWithWhite:0.8 alpha:1.0];

  [c setStroke];
  NSBezierPath *line = [NSBezierPath bezierPath];
  line.lineWidth = 1.0;
  [line moveToPoint:NSMakePoint(x, 0)];
  [line lineToPoint:NSMakePoint(x, rulerBottom)];
  [line stroke];

  _drawPlayheadKnob(x, rulerTop, c);
}

@end
