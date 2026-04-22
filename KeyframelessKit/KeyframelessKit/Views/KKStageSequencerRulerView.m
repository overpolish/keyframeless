/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerRulerView.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKStageSequencerView_Private.h"

static double _rulerTickInterval(CGFloat pps) {
  static const double candidates[] = {0.1,  0.25, 0.5,  1.0,  2.0,   5.0,
                                      10.0, 15.0, 30.0, 60.0, 120.0, 300.0};
  static const int count = sizeof(candidates) / sizeof(candidates[0]);
  CGFloat minSpacing = 50.0;
  for (int i = 0; i < count; i++) {
    if (candidates[i] * pps >= minSpacing)
      return candidates[i];
  }
  return candidates[count - 1];
}

static NSString *_rulerTimecode(double seconds) {
  int totalSec = (int)seconds;
  int m = totalSec / 60;
  int s = totalSec % 60;
  double frac = seconds - totalSec;
  if (frac > 0.001 && seconds < 60)
    return [NSString stringWithFormat:@"%d.%ds", s, (int)(frac * 10)];
  if (m > 0)
    return [NSString stringWithFormat:@"%d:%02d", m, s];
  return [NSString stringWithFormat:@"%ds", s];
}

@implementation KKStageSequencerRulerView {
  BOOL _scrubbing;
}

+ (CGFloat)preferredHeight {
  return kKSSRulerHeight;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    _zoom = 1.0;
    _panOffset = 0.0;
  }
  return self;
}

- (void)setEffectDuration:(double)effectDuration {
  if (fabs(_effectDuration - effectDuration) < 0.001)
    return;
  _effectDuration = effectDuration;
  [self setNeedsDisplay:YES];
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

- (void)_trackX:(CGFloat *)outX width:(CGFloat *)outW {
  CGFloat viewW = NSWidth(self.bounds);
  // Match KKStageSequencerView's track geometry so the ruler aligns with the
  // lanes. The sequencer uses kKSSBorderInset for L/R padding inside its own
  // bounds; here our bounds match the sequencer's width (both pinned to the
  // container), so we use the same formula.
  *outX = kKSSBorderInset + kKSSLabelWidth;
  *outW = viewW - 2 * kKSSBorderInset - kKSSLabelWidth - kKSSLabelPadding;
}

- (CGFloat)_xForFrac:(double)frac trackX:(CGFloat)tx trackW:(CGFloat)tw {
  return tx + (frac - _panOffset) * _zoom * tw;
}

- (double)_fracForX:(CGFloat)x trackX:(CGFloat)tx trackW:(CGFloat)tw {
  return _panOffset + (x - tx) / (_zoom * tw);
}

- (void)_clampPan {
  CGFloat visibleSpan = 1.0 / _zoom;
  _panOffset = MAX(0.0, MIN(1.0 - visibleSpan, _panOffset));
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];

  CGFloat tx = 0, tw = 0;
  [self _trackX:&tx width:&tw];
  if (tw < 10)
    return;

  CGFloat rulerY = 0;

  if (_effectDuration > 0) {
    CGFloat pps = tw * _zoom / _effectDuration;
    double interval = _rulerTickInterval(pps);

    NSDictionary *attrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : [NSColor timelineLabel],
    };
    [[NSColor colorWithWhite:0.8 alpha:0.15] setStroke];
    NSBezierPath *ticks = [NSBezierPath bezierPath];
    ticks.lineWidth = 1.0;

    double visStart = _panOffset * _effectDuration;
    double tStart = floor(visStart / interval) * interval;
    double visEnd = (_panOffset + 1.0 / _zoom) * _effectDuration;

    for (double t = tStart; t <= visEnd + 0.001; t += interval) {
      if (t < 0)
        continue;
      double frac = t / _effectDuration;
      CGFloat x = [self _xForFrac:frac trackX:tx trackW:tw];
      if (x < tx || x > tx + tw)
        continue;

      [ticks moveToPoint:NSMakePoint(x, rulerY)];
      [ticks lineToPoint:NSMakePoint(x, rulerY + kKSSRulerHeight)];

      NSString *label = _rulerTimecode(t);
      NSSize lsz = [label sizeWithAttributes:attrs];
      CGFloat lx = x + 3;
      if (lx + lsz.width <= tx + tw) {
        CGFloat ly = rulerY + (kKSSRulerHeight - lsz.height) / 2.0;
        [label drawAtPoint:NSMakePoint(lx, ly) withAttributes:attrs];
      }
    }
    [ticks stroke];
  }

  // Playhead knob + line are drawn by KKStagePlayheadView (overlay).
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat tx = 0, tw = 0;
  [self _trackX:&tx width:&tw];
  if (loc.x < tx || loc.x > tx + tw)
    return;
  double frac = [self _fracForX:loc.x trackX:tx trackW:tw];
  frac = MAX(0.0, MIN(1.0, frac));
  _scrubbing = YES;
  self.playheadFraction = frac;
  if (self.onPlayheadScrub)
    self.onPlayheadScrub(frac);
}

- (void)mouseDragged:(NSEvent *)event {
  if (!_scrubbing)
    return;
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat tx = 0, tw = 0;
  [self _trackX:&tx width:&tw];
  double frac = [self _fracForX:loc.x trackX:tx trackW:tw];
  frac = MAX(0.0, MIN(1.0, frac));
  self.playheadFraction = frac;
  if (self.onPlayheadScrub)
    self.onPlayheadScrub(frac);
}

- (void)mouseUp:(NSEvent *)event {
  _scrubbing = NO;
}

- (void)magnifyWithEvent:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat tx = 0, tw = 0;
  [self _trackX:&tx width:&tw];
  double fracUnder = [self _fracForX:loc.x trackX:tx trackW:tw];
  _zoom = MAX(1.0, MIN(20.0, _zoom * (1.0 + event.magnification)));
  _panOffset = fracUnder - (loc.x - tx) / (_zoom * tw);
  [self _clampPan];
  [self setNeedsDisplay:YES];
  if (self.onZoomPanChanged)
    self.onZoomPanChanged(_zoom, _panOffset);
}

- (void)scrollWheel:(NSEvent *)event {
  if (event.phase == NSEventPhaseNone &&
      event.momentumPhase == NSEventPhaseNone)
    return;
  CGFloat tx = 0, tw = 0;
  [self _trackX:&tx width:&tw];
  CGFloat dx = event.scrollingDeltaX;
  if (event.hasPreciseScrollingDeltas)
    _panOffset -= dx / (_zoom * tw);
  else
    _panOffset -= dx * 0.01 / _zoom;
  [self _clampPan];
  [self setNeedsDisplay:YES];
  if (self.onZoomPanChanged)
    self.onZoomPanChanged(_zoom, _panOffset);
}

@end
