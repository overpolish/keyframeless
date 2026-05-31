/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAdvancedView_Private.h"

#import "../KKLog.h"
#import "../Math/KKTimelineScale.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKKeyposeSymbol.h"
#import "KKLocalized.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

BOOL KKAdvValuesEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
  if (a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++)
    if (fabs(a[i].doubleValue - b[i].doubleValue) > kValueEqEps)
      return NO;
  return YES;
}

// Normalise one component value to [0,1] given its [min,max] bounds. No
// clamp: the row reserves outer headroom (1 - kRowValueFrac) so easing
// overshoot (Elastic/Bounce/Back) draws into that band instead of
// flattening against the value-range edge.
double KKAdvNormComponent(double v, NSArray<NSNumber *> *cMin,
                          NSArray<NSNumber *> *cMax, NSUInteger i) {
  double lo = (i < cMin.count) ? cMin[i].doubleValue : 0.0;
  double hi = (i < cMax.count) ? cMax[i].doubleValue : 1.0;
  if (hi <= lo)
    hi = lo + 1.0;
  return (v - lo) / (hi - lo);
}

@implementation KKTimelineAdvancedView (Drawing)

- (void)drawRect:(NSRect)dirtyRect {
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0 || NSHeight(g) <= 0)
    return;

  NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:g
                                                        xRadius:KKRadiusMD
                                                        yRadius:KKRadiusMD];
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
  [track fill];

  NSArray<KKLane *> *lanes = [self _animatableLanes];
  NSRect tracks = [self _tracksRect];

  NSDictionary *labelAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName :
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.75],
  };

  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    NSRect row = [self _rowRectForIndex:i count:lanes.count];
    if (i == _hoverLaneRow) {
      // Extend the hover highlight by kPillW/2 on each side so it lines up
      // with the boundary pills (which sit centred on tracks.minX / maxX)
      // and the lane line - all three agree on where the visible row ends.
      NSRect hoverRect = NSInsetRect(row, -kPillW * 0.5, -1);
      NSBezierPath *hi = [NSBezierPath bezierPathWithRoundedRect:hoverRect
                                                         xRadius:KKRadiusSM
                                                         yRadius:KKRadiusSM];
      [[[NSColor inspectorLabel] colorWithAlphaComponent:0.05] setFill];
      [hi fill];
    }
    NSString *label = KKLocalizedParamName(lane.label ?: @"");
    NSSize lsz = [label sizeWithAttributes:labelAttrs];
    NSPoint lp =
        NSMakePoint(NSMinX(g) + kRowLabelInset, NSMidY(row) - lsz.height * 0.5);
    [label drawAtPoint:lp withAttributes:labelAttrs];
  }

  // Curves and pills get clipped to the tracks rect so zoom/pan content
  // doesn't bleed into the label gutter or beyond the track edges. Clip is
  // expanded so t=0 / t=1 pills draw whole + ~2px for the selection halo.
  CGFloat edgePad = kPillW * 0.5 + 2.0;
  [NSGraphicsContext saveGraphicsState];
  NSRectClip(NSMakeRect(NSMinX(tracks) - edgePad, NSMinY(g),
                        NSWidth(tracks) + edgePad * 2.0, NSHeight(g)));
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    NSRect row = [self _rowRectForIndex:i count:lanes.count];
    [self _drawLane:lane inRow:row tracks:tracks];
  }
  [NSGraphicsContext restoreGraphicsState];

  [self _drawRulerInRect:g tracks:tracks];
  [self _drawDurationOverlayInRect:g tracks:tracks];
  [self _drawPlayheadInRect:g tracks:tracks];
  [self _drawDragSnapGuideInRect:g tracks:tracks];
  [self _drawMarqueeRect];
}

- (void)_drawDurationPillInRect:(NSRect)g
                         tracks:(NSRect)tracks
                          fracA:(double)fracA
                          fracB:(double)fracB
                           tint:(NSColor *)tint
                         rulerY:(CGFloat)rulerY {
  double dur = [self _clipDuration];
  if (dur <= 0.0 || fracB <= fracA)
    return;
  double secs = (fracB - fracA) * dur;
  NSString *txt = secs < 10.0 ? [NSString stringWithFormat:@"%.1fs", secs]
                              : [NSString stringWithFormat:@"%.0fs", secs];
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName : tint,
  };
  NSSize sz = [txt sizeWithAttributes:attrs];
  CGFloat xA = [self _xForFrac:fracA inTracks:tracks];
  CGFloat xB = [self _xForFrac:fracB inTracks:tracks];
  CGFloat cx = (xA + xB) / 2.0;
  CGFloat x = round(cx - sz.width / 2.0);
  x = MAX(NSMinX(tracks), MIN(NSMaxX(tracks) - sz.width, x));
  CGFloat y = rulerY + (kRulerH - sz.height) / 2.0;
  NSRect pill =
      NSInsetRect(NSMakeRect(x, rulerY, sz.width, kRulerH), -3.0, 0.0);
  [[[NSColor inspectorBackground] colorWithAlphaComponent:0.92] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:pill
                                   xRadius:KKRadiusSM
                                   yRadius:KKRadiusSM] fill];
  [txt drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
}

- (void)_drawDurationOverlayInRect:(NSRect)g tracks:(NSRect)tracks {
  CGFloat rulerY = NSMaxY(g) + kRulerGap;
  NSColor *neutral = [NSColor accentMatchingHost];
  NSColor *warn = [NSColor warning];

  BOOL singleDrag =
      _dragActive && _pressLaneLabel && _dragOriginTimes.count == 0;
  if (singleDrag) {
    KKLane *lane = nil;
    for (KKLane *l in _timeline.lanes)
      if ([l.label isEqualToString:_pressLaneLabel] && l.enabled) {
        lane = l;
        break;
      }
    if (!lane || _pressKPIdx < 0 ||
        _pressKPIdx >= (NSInteger)lane.keyposes.count)
      return;
    double tHere = lane.keyposes[_pressKPIdx].time;
    if (_pressKPIdx > 0) {
      KKKeyPose *prev = lane.keyposes[_pressKPIdx - 1];
      NSColor *tint =
          KKAdvValuesEqual(prev.values, lane.keyposes[_pressKPIdx].values)
              ? neutral
              : warn;
      [self _drawDurationPillInRect:g
                             tracks:tracks
                              fracA:prev.time
                              fracB:tHere
                               tint:tint
                             rulerY:rulerY];
    }
    if (_pressKPIdx + 1 < (NSInteger)lane.keyposes.count) {
      KKKeyPose *next = lane.keyposes[_pressKPIdx + 1];
      NSColor *tint =
          KKAdvValuesEqual(lane.keyposes[_pressKPIdx].values, next.values)
              ? neutral
              : warn;
      [self _drawDurationPillInRect:g
                             tracks:tracks
                              fracA:tHere
                              fracB:next.time
                               tint:tint
                             rulerY:rulerY];
    }
    return;
  }

  if (_hoverGapLabel && _hoverGapAIdx >= 0) {
    KKLane *lane = nil;
    for (KKLane *l in _timeline.lanes)
      if ([l.label isEqualToString:_hoverGapLabel] && l.enabled) {
        lane = l;
        break;
      }
    if (!lane)
      return;
    if (_hoverGapAIdx + 1 >= (NSInteger)lane.keyposes.count)
      return;
    KKKeyPose *a = lane.keyposes[_hoverGapAIdx];
    KKKeyPose *b = lane.keyposes[_hoverGapAIdx + 1];
    NSColor *tint = KKAdvValuesEqual(a.values, b.values) ? neutral : warn;
    [self _drawDurationPillInRect:g
                           tracks:tracks
                            fracA:a.time
                            fracB:b.time
                             tint:tint
                           rulerY:rulerY];
  }
}

- (void)_drawMarqueeRect {
  if (!_marqueeActive)
    return;
  NSRect r = NSMakeRect(MIN(_marqueeAnchor.x, _marqueeCurrent.x),
                        MIN(_marqueeAnchor.y, _marqueeCurrent.y),
                        fabs(_marqueeAnchor.x - _marqueeCurrent.x),
                        fabs(_marqueeAnchor.y - _marqueeCurrent.y));
  if (NSWidth(r) < 1.0)
    r.size.width = 1.0;
  if (NSHeight(r) < 1.0)
    r.size.height = 1.0;
  NSColor *accent = [NSColor accentMatchingHost];
  [[accent colorWithAlphaComponent:0.12] setFill];
  NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
  NSBezierPath *border = [NSBezierPath bezierPathWithRect:r];
  border.lineWidth = 1.0;
  CGFloat dash[2] = {4.0, 3.0};
  [border setLineDash:dash count:2 phase:0.0];
  [accent setStroke];
  [border stroke];
}

- (void)_drawDragSnapGuideInRect:(NSRect)g tracks:(NSRect)tracks {
  if (isnan(_dragSnapFrac))
    return;
  CGFloat x = [self _xForFrac:_dragSnapFrac inTracks:tracks];
  x = round(x) + 0.5;
  NSBezierPath *line = [NSBezierPath bezierPath];
  [line moveToPoint:NSMakePoint(x, NSMinY(g))];
  [line lineToPoint:NSMakePoint(x, NSMaxY(g))];
  line.lineWidth = 1.0;
  [[NSColor systemYellowColor] setStroke];
  [line stroke];
}

- (void)_drawLane:(KKLane *)lane inRow:(NSRect)row tracks:(NSRect)tracks {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count == 0)
    return;
  NSColor *neutral = [NSColor accentMatchingHost];
  NSColor *warn = [NSColor warning];

  CGFloat pad = (NSHeight(row) * (1.0 - kRowValueFrac)) * 0.5;
  if (pad < kRowVPadMin)
    pad = kRowVPadMin;
  CGFloat yBot = NSMinY(row) + pad;
  CGFloat yTop = NSMaxY(row) - pad;
  if (yTop <= yBot) {
    yBot = NSMinY(row);
    yTop = NSMaxY(row);
  }
  CGFloat clampLo = NSMinY(row);
  CGFloat clampHi = NSMaxY(row);

  NSUInteger compCount = kps.firstObject.values.count;
  // Plot range = union of the lane's declared componentMin/Max and the
  // *actual* per-component min/max sampled across all intervals (so
  // modulation overshoot or out-of-range edits expand the visual scale
  // instead of clipping into the row edges).
  NSMutableArray<NSNumber *> *plotMin = lane.componentMin
                                            ? [lane.componentMin mutableCopy]
                                            : [NSMutableArray array];
  NSMutableArray<NSNumber *> *plotMax = lane.componentMax
                                            ? [lane.componentMax mutableCopy]
                                            : [NSMutableArray array];
  while (plotMin.count < compCount)
    [plotMin addObject:@0.0];
  while (plotMax.count < compCount)
    [plotMax addObject:@1.0];
  for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++) {
    KKKeyPose *ka = kps[i];
    KKKeyPose *kb = kps[i + 1];
    BOOL flat =
        KKAdvValuesEqual(ka.values, kb.values) &&
        (!ka.outgoing || ka.outgoing.modulation == KKIntervalModulationNone);
    NSInteger samples = flat ? 1 : 16;
    for (NSInteger k = 0; k <= samples; k++) {
      double t = (samples > 0) ? (double)k / (double)samples : 0.0;
      double gFrac = ka.time + (kb.time - ka.time) * t;
      NSArray<NSNumber *> *vals = KKTimelineLaneValueAtFraction(lane, gFrac);
      for (NSUInteger c = 0; c < compCount && c < vals.count; c++) {
        double v = vals[c].doubleValue;
        if (v < plotMin[c].doubleValue)
          plotMin[c] = @(v);
        if (v > plotMax[c].doubleValue)
          plotMax[c] = @(v);
      }
    }
  }
  NSArray<NSNumber *> *cMin = plotMin;
  NSArray<NSNumber *> *cMax = plotMax;
  BOOL multi = compCount > 1;
  CGFloat lineW = multi ? 1.25 : kIntervalWidth;
  CGFloat compAlpha = multi ? (compCount > 2 ? 0.65 : 0.85) : 1.0;

  // Selection highlight draws under the outer (wide) clip so its first/
  // last-gap kPillW/2 extension reaches under the boundary pills - the
  // whole point of that extension is to land under the pill+tie-bar.
  [self _drawGapSelectionForLane:lane inRow:row tracks:tracks];

  // Lane value curves clip just wide enough to match where pills can draw.
  // Pills at t=0 / t=1 sit centred on the tracks edge so their outer half
  // (kPillW/2) sits OUTSIDE the strict tracks rect. The lane line must
  // extend by the same amount, otherwise a pill at the edge sits over an
  // un-filled strip and reads as the line stopping kPillW/2 short of the
  // visible row edge. We do NOT match the full outer clip (kPillW/2 + 2)
  // because the extra 2pt was just AA padding for pills; curves shouldn't
  // escape into it.
  CGFloat innerEdgePad = kPillW * 0.5;
  [NSGraphicsContext saveGraphicsState];
  NSRectClip(NSMakeRect(NSMinX(tracks) - innerEdgePad, NSMinY(row),
                        NSWidth(tracks) + innerEdgePad * 2.0, NSHeight(row)));

  // Leading + trailing flat fill: the value before the first keypose (and
  // after the last) is constant at that endpoint's value, but the per-gap
  // loop only draws between keyposes. When the user zooms/pans such that
  // the first or last keypose sits inside the visible row (not at the
  // edge), the area between the row edge and that keypose ends up empty.
  // Draw the leading/trailing constant flat lines at the endpoint kp's
  // normalised values so the lane visually fills the entire row.
  // Single-keypose lanes naturally fall out of this: both halves meet at
  // the kp position, drawing a constant across the whole row.
  KKKeyPose *firstKP = kps.firstObject;
  KKKeyPose *lastKP = kps.lastObject;
  CGFloat firstX = [self _xForFrac:firstKP.time inTracks:tracks];
  CGFloat lastX = [self _xForFrac:lastKP.time inTracks:tracks];
  // Leading/trailing flat fills extend out to the widened inner clip
  // (tracks edge minus kPillW/2) so the lane line reaches under the t=0 /
  // t=1 pill's outer half - same edge the per-gap loop's first/last
  // segment will also be extended to below.
  NSColor *flatColor = [neutral colorWithAlphaComponent:compAlpha];
  CGFloat leftEdge = NSMinX(tracks) - innerEdgePad;
  CGFloat rightEdge = NSMaxX(tracks) + innerEdgePad;
  if (firstX > leftEdge) {
    for (NSUInteger c = 0; c < compCount && c < firstKP.values.count; c++) {
      double n =
          KKAdvNormComponent(firstKP.values[c].doubleValue, cMin, cMax, c);
      CGFloat y = round(yBot + (yTop - yBot) * n) + 0.5;
      NSPoint pts[2] = {NSMakePoint(leftEdge, y), NSMakePoint(firstX, y)};
      KKStrokeTimelineCurve(pts, 2, lineW, NO, flatColor);
    }
  }
  if (lastX < rightEdge) {
    for (NSUInteger c = 0; c < compCount && c < lastKP.values.count; c++) {
      double n =
          KKAdvNormComponent(lastKP.values[c].doubleValue, cMin, cMax, c);
      CGFloat y = round(yBot + (yTop - yBot) * n) + 0.5;
      NSPoint pts[2] = {NSMakePoint(lastX, y), NSMakePoint(rightEdge, y)};
      KKStrokeTimelineCurve(pts, 2, lineW, NO, flatColor);
    }
  }

  for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++) {
    KKKeyPose *a = kps[i];
    KKKeyPose *b = kps[i + 1];
    CGFloat xA = [self _xForFrac:a.time inTracks:tracks];
    CGFloat xB = [self _xForFrac:b.time inTracks:tracks];
    if (xB - xA < 0.5)
      continue;
    // First/last gap: extend the segment so it sits under the boundary
    // pill's outer half. The drawing clip is widened by kPillW/2 to match.
    // Middle gaps keep their exact bounds so consecutive gaps don't double-
    // tint when alpha < 1.
    if (i == 0)
      xA -= innerEdgePad;
    if (i + 1 == (NSInteger)kps.count - 1)
      xB += innerEdgePad;
    KKInterval *iv = a.outgoing;
    BOOL anyDiffer = !KKAdvValuesEqual(a.values, b.values);
    BOOL hasModulation = iv && iv.modulation != KKIntervalModulationNone;
    NSColor *base = anyDiffer ? warn : neutral;
    NSColor *color = [base colorWithAlphaComponent:compAlpha];

    if (!anyDiffer && !hasModulation) {
      for (NSUInteger c = 0; c < compCount; c++) {
        double n = KKAdvNormComponent(a.values[c].doubleValue, cMin, cMax, c);
        CGFloat y = round(yBot + (yTop - yBot) * n) + 0.5;
        NSPoint pts[2] = {NSMakePoint(xA, y), NSMakePoint(xB, y)};
        KKStrokeTimelineCurve(pts, 2, lineW, NO, color);
      }
      continue;
    }

    NSInteger n =
        MAX(16, (NSInteger)MIN((CGFloat)kCurveSamples, (xB - xA) / 2.0));
    if (hasModulation) {
      double cyc = (iv.modulation == KKIntervalModulationOscillate)  ? 6.0
                   : (iv.modulation == KKIntervalModulationHandheld) ? 60.0
                                                                     : 55.0;
      cyc *= iv.modulationFrequency;
      n = MAX(n, (NSInteger)ceil(cyc * 24.0));
      n = MIN(n, 4000);
    }
    NSPoint **pts = malloc(sizeof(NSPoint *) * compCount);
    for (NSUInteger c = 0; c < compCount; c++)
      pts[c] = malloc(sizeof(NSPoint) * (size_t)(n + 1));
    for (NSInteger k = 0; k <= n; k++) {
      double t = (double)k / (double)n;
      double globalFrac = a.time + (b.time - a.time) * t;
      NSArray<NSNumber *> *vals =
          KKTimelineLaneValueAtFraction(lane, globalFrac);
      CGFloat x = xA + (xB - xA) * t;
      for (NSUInteger c = 0; c < compCount; c++) {
        double v =
            (c < vals.count) ? vals[c].doubleValue : a.values[c].doubleValue;
        double nv = KKAdvNormComponent(v, cMin, cMax, c);
        CGFloat y = yBot + (yTop - yBot) * nv;
        if (y < clampLo)
          y = clampLo;
        if (y > clampHi)
          y = clampHi;
        pts[c][k] = NSMakePoint(x, y);
      }
    }
    for (NSUInteger c = 0; c < compCount; c++) {
      KKStrokeTimelineCurve(pts[c], n + 1, lineW, NO, color);
      free(pts[c]);
    }
    free(pts);
  }

  [NSGraphicsContext restoreGraphicsState];

  CGFloat pillTop = NSMaxY(row) - kPillInsetY;
  CGFloat pillBot = NSMinY(row) + kPillInsetY;
  if (pillTop <= pillBot) {
    pillTop = NSMaxY(row);
    pillBot = NSMinY(row);
  }
  BOOL isTopLane = _topLaneLabel &&
                   [lane.label isEqualToString:_topLaneLabel] &&
                   _topKPIdx >= 0 && _topKPIdx < (NSInteger)kps.count;
  for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
    if (isTopLane && i == _topKPIdx)
      continue;
    [self _drawPillForKPInLane:lane
                       atIndex:i
                       pillBot:pillBot
                       pillTop:pillTop
                        tracks:tracks
                       neutral:neutral
                          warn:warn];
  }
  if (isTopLane)
    [self _drawPillForKPInLane:lane
                       atIndex:_topKPIdx
                       pillBot:pillBot
                       pillTop:pillTop
                        tracks:tracks
                       neutral:neutral
                          warn:warn];

  [self _drawTieBarsForLane:lane
                      inRow:row
                    pillTop:pillTop
                     tracks:tracks
                    neutral:neutral];
}

- (void)_drawGapSelectionForLane:(KKLane *)lane
                           inRow:(NSRect)row
                          tracks:(NSRect)tracks {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count < 2)
    return;
  NSColor *neutral = [NSColor accentMatchingHost];
  NSColor *warn = [NSColor warning];
  // First/last gap's selection rect extends out by kPillW/2 to cover under
  // the boundary pill's outer half - same edge the lane line uses, so the
  // highlight and the line agree on where the visible row "ends".
  CGFloat innerEdgePad = kPillW * 0.5;
  for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++) {
    if (![self _gapSelected:lane aIdx:i])
      continue;
    CGFloat xA = [self _xForFrac:kps[i].time inTracks:tracks];
    CGFloat xB = [self _xForFrac:kps[i + 1].time inTracks:tracks];
    if (xB - xA < 1.0)
      continue;
    if (i == 0)
      xA -= innerEdgePad;
    if (i + 1 == (NSInteger)kps.count - 1)
      xB += innerEdgePad;
    BOOL transition = !KKAdvValuesEqual(kps[i].values, kps[i + 1].values);
    NSColor *tint =
        [(transition ? warn : neutral) colorWithAlphaComponent:0.15];
    NSRect col = NSMakeRect(xA, NSMinY(row), xB - xA, NSHeight(row));
    [tint setFill];
    NSRectFillUsingOperation(col, NSCompositingOperationSourceOver);
  }
}

- (void)_drawTieBarsForLane:(KKLane *)lane
                      inRow:(NSRect)row
                    pillTop:(CGFloat)pillTop
                     tracks:(NSRect)tracks
                    neutral:(NSColor *)neutral {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  CGFloat barY = MIN(pillTop + 3.0, NSMaxY(row) - 0.5);
  for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++) {
    KKInterval *iv = kps[i].outgoing;
    if (!iv || !iv.endpointsLinked)
      continue;
    if (!KKAdvValuesEqual(kps[i].values, kps[i + 1].values))
      continue;
    CGFloat xA = [self _xForFrac:kps[i].time inTracks:tracks];
    CGFloat xB = [self _xForFrac:kps[i + 1].time inTracks:tracks];
    if (xB - xA < 4.0)
      continue;
    NSBezierPath *tie = [NSBezierPath bezierPath];
    [tie moveToPoint:NSMakePoint(xA, pillTop)];
    [tie lineToPoint:NSMakePoint(xA, barY)];
    [tie lineToPoint:NSMakePoint(xB, barY)];
    [tie lineToPoint:NSMakePoint(xB, pillTop)];
    tie.lineWidth = KKBorderWidthSM;
    tie.lineJoinStyle = NSLineJoinStyleRound;
    tie.lineCapStyle = NSLineCapStyleRound;
    [[neutral colorWithAlphaComponent:0.7] setStroke];
    [tie stroke];
  }
}

- (void)_drawPillForKPInLane:(KKLane *)lane
                     atIndex:(NSInteger)i
                     pillBot:(CGFloat)pillBot
                     pillTop:(CGFloat)pillTop
                      tracks:(NSRect)tracks
                     neutral:(NSColor *)neutral
                        warn:(NSColor *)warn {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  KKKeyPose *kp = kps[i];
  CGFloat x = [self _xForFrac:kp.time inTracks:tracks];
  BOOL warnHere = NO;
  if (i > 0 && !KKAdvValuesEqual(kps[i - 1].values, kp.values))
    warnHere = YES;
  if (!warnHere && i + 1 < (NSInteger)kps.count &&
      !KKAdvValuesEqual(kp.values, kps[i + 1].values))
    warnHere = YES;
  CGFloat pillX = round(x) - kPillW * 0.5 + 0.5;
  NSRect pill = NSMakeRect(pillX, pillBot, kPillW, pillTop - pillBot);
  NSColor *base = warnHere ? warn : neutral;
  KKDrawKeyposePill(pill, YES, base);
  if ([self _pillSelected:lane atIdx:i]) {
    CGFloat r = MIN(pill.size.width, pill.size.height) * 0.5;
    NSBezierPath *halo =
        [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(pill, -1.5, -1.5)
                                        xRadius:r + 1.5
                                        yRadius:r + 1.5];
    halo.lineWidth = 1.5;
    [[NSColor inspectorLabel] setStroke];
    [halo stroke];
  }
}

- (void)_drawRulerInRect:(NSRect)g tracks:(NSRect)tracks {
  double dur = [self _clipDuration];
  if (dur <= 0.0 || NSWidth(tracks) <= 0.0)
    return;
  CGFloat rulerY = NSMaxY(g) + kRulerGap;
  CGFloat pps = NSWidth(tracks) / dur;
  double interval = KKTimelineScaleTickInterval(pps, kTickMinSpacing);
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName :
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.35],
  };
  NSBezierPath *ticks = [NSBezierPath bezierPath];
  ticks.lineWidth = KKBorderWidthXS;
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.15] setStroke];
  for (double t = 0; t <= dur + 0.001; t += interval) {
    double frac = t / dur;
    if (frac > 1.0001)
      break;
    CGFloat x = [self _xForFrac:frac inTracks:tracks];
    if (x < NSMinX(tracks) - 0.5 || x > NSMaxX(tracks) + 0.5)
      continue;
    [ticks moveToPoint:NSMakePoint(x, rulerY)];
    [ticks lineToPoint:NSMakePoint(x, rulerY + 4.0)];
    NSString *label = KKTimelineScaleTimecode(t);
    NSSize lsz = [label sizeWithAttributes:attrs];
    CGFloat lx = x + 3.0;
    if (lx >= NSMinX(tracks) && lx + lsz.width <= NSMaxX(tracks))
      [label drawAtPoint:NSMakePoint(lx, rulerY + (kRulerH - lsz.height) / 2.0)
          withAttributes:attrs];
  }
  [ticks stroke];
}

- (void)_drawPlayheadInRect:(NSRect)g tracks:(NSRect)tracks {
  if (_playheadFraction < 0.0)
    return;
  CGFloat px = [self _xForFrac:_playheadFraction inTracks:tracks];
  px = round(px) + 0.5;
  CGFloat top = NSMaxY(g) + kRulerGap + kRulerH;
  NSColor *phc = [NSColor inspectorLabel];
  NSBezierPath *line = [NSBezierPath bezierPath];
  [line moveToPoint:NSMakePoint(px, NSMinY(g))];
  [line lineToPoint:NSMakePoint(px, top)];
  line.lineWidth = 1.0;
  [[phc colorWithAlphaComponent:0.85] setStroke];
  [line stroke];
  CGFloat kw = 7.0, kh = 6.0;
  NSBezierPath *knob = [NSBezierPath bezierPath];
  [knob moveToPoint:NSMakePoint(px - kw / 2.0, top)];
  [knob lineToPoint:NSMakePoint(px + kw / 2.0, top)];
  [knob lineToPoint:NSMakePoint(px + kw / 2.0, top - kh + 3.0)];
  [knob lineToPoint:NSMakePoint(px, top - kh)];
  [knob lineToPoint:NSMakePoint(px - kw / 2.0, top - kh + 3.0)];
  [knob closePath];
  [phc setFill];
  [knob fill];
}

@end
