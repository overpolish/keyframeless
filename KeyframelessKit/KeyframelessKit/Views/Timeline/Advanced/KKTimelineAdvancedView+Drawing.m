/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAdvancedView_Private.h"

#import "KKKeyposeSymbol.h"
#import "KKLocalized.h"
#import "KKLog.h"
#import "KKTimelineScale.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKGradientBarView.h>
#import <KeyframelessKit/KKGradientSampling.h>
#import <KeyframelessKit/KKPathMorph.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

// Derived graph values for a composite gradient lane value
// [type, angleDegrees, <flat stops>]: a stops "signature" line, plus an angle
// line when linear. Lets the generic curve drawing plot 1-2 meaningful lines
// instead of the raw component tangle.
static NSArray<NSNumber *> *KKAdvGradientDerived(NSArray<NSNumber *> *composite,
                                                 BOOL linear) {
  double angle = composite.count >= 2 ? composite[1].doubleValue : 0.0;
  // Continuous (not wrapped mod 360): a modulation wiggle that crosses 0/360
  // would teleport top-to-bottom on a wrapped track. The plot auto-scales the
  // angle component to its sampled range, so an out-of-[0,1] value just widens
  // the scale instead of clipping or wrapping.
  double angleNorm = angle / 360.0;
  NSArray<KKGradientStop *> *stops =
      composite.count > 2
          ? KKGradientStopsFromFlat([composite
                subarrayWithRange:NSMakeRange(2, composite.count - 2)])
          : nil;
  double sig = KKGradientStopsSignature(stops);
  return linear ? @[ @(angleNorm), @(sig) ] : @[ @(sig) ];
}

BOOL KKAdvValuesEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
  return KKValuesEqual(a, b); // shared impl (Basic+Model)
}

// A geometry lane (oscEditedOnly, e.g. a path's Points) carries no scalar of
// its own - just a per-keypose shape snapshot. Rewrite it to a single 0..1
// component so the generic curve drawing plots a line that holds flat across
// equal shapes and slopes between distinct ones.
//
// The plotted value is a DUMMY normalized level, not the raw signature: the
// signature is an FNV hash, so two different shapes can hash to nearby values
// (0.51 vs 0.52) and their transition would draw almost flat - looking like a
// hold. We use the hash only to decide EQUALITY (group identical shapes), then
// spread the distinct shapes evenly over [0,1] by first-appearance order, so
// every real transition reads as a clear slope and holds stay flat.
// Curve/easing state is preserved (KKKeyPose copy keeps `outgoing`), so the
// line eases like the morph.
static KKLane *KKAdvGeometryLaneForPlot(KKLane *lane) {
  NSUInteger n = lane.keyposes.count;
  NSMutableArray<NSNumber *> *distinctSigs = [NSMutableArray array];
  NSMutableArray<NSNumber *> *rankForKp = [NSMutableArray arrayWithCapacity:n];
  for (KKKeyPose *kp in lane.keyposes) {
    double sig = KKMorphSnapshotSignature(kp.geometrySnapshot);
    NSInteger rank = -1;
    for (NSUInteger j = 0; j < distinctSigs.count; j++)
      if (fabs(distinctSigs[j].doubleValue - sig) < 1e-9) {
        rank = (NSInteger)j;
        break;
      }
    if (rank < 0) {
      rank = (NSInteger)distinctSigs.count;
      [distinctSigs addObject:@(sig)];
    }
    [rankForKp addObject:@(rank)];
  }
  double maxRank =
      distinctSigs.count > 1 ? (double)(distinctSigs.count - 1) : 1.0;
  NSMutableArray<KKKeyPose *> *kps = [NSMutableArray arrayWithCapacity:n];
  for (NSUInteger i = 0; i < n; i++) {
    KKKeyPose *c = [lane.keyposes[i] copy];
    double v =
        distinctSigs.count > 1 ? rankForKp[i].doubleValue / maxRank : 0.5;
    c.values = @[ @(v) ];
    [kps addObject:c];
  }
  KKLane *out = [lane copy];
  out.keyposes = kps;
  out.componentMin = @[ @0.0 ];
  out.componentMax = @[ @1.0 ];
  return out;
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

// A category HEADER row: icon + localized category name flush-left, plus a
// trailing collapse chevron at the graph's right edge (so the row doubles as
// the collapse affordance, mirroring the layer header). Indented under the
// layer header when the timeline has a layer level, giving a layer > category
// > lane tree.
- (void)_drawCategoryHeaderRowForLane:(KKLane *)lane
                                inRow:(NSRect)row
                            collapsed:(BOOL)collapsed {
  NSColor *ink = [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
  NSString *name = KKLocalizedParamName(lane.categoryKey ?: @"");
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:kGroupDividerFontSize
                                            weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName : ink,
    NSKernAttributeName : @0.5,
  };
  NSSize tsz = [name sizeWithAttributes:attrs];
  CGFloat midY = NSMidY(row);
  NSRect g = [self _graphRect];

  NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration
      configurationWithPointSize:kGroupDividerFontSize
                          weight:NSFontWeightSemibold]
      configurationByApplyingConfiguration:
          [NSImageSymbolConfiguration configurationWithHierarchicalColor:ink]];

  CGFloat x = NSMinX(g) + kRowLabelInset +
              (lane.layerKey.length ? kCategoryHeaderIndent : 0.0);
  if (lane.categorySymbol.length) {
    NSImage *icon = [[NSImage imageWithSystemSymbolName:lane.categorySymbol
                               accessibilityDescription:nil]
        imageWithSymbolConfiguration:cfg];
    if (icon) {
      CGFloat iconH = icon.size.height;
      [icon drawInRect:NSMakeRect(x, floor(midY - iconH * 0.5), icon.size.width,
                                  iconH)];
      x += icon.size.width + KKPaddingSM;
    }
  }
  [name drawAtPoint:NSMakePoint(x, floor(midY - tsz.height * 0.5))
      withAttributes:attrs];

  NSString *chev = collapsed ? @"chevron.right" : @"chevron.down";
  NSImage *chevImg = [[NSImage imageWithSystemSymbolName:chev
                                accessibilityDescription:nil]
      imageWithSymbolConfiguration:cfg];
  if (chevImg) {
    CGFloat cw = chevImg.size.width, ch = chevImg.size.height;
    [chevImg drawInRect:NSMakeRect(NSMaxX(g) - kRowLabelInset - cw,
                                   floor(midY - ch * 0.5), cw, ch)];
  }
}

// A layer HEADER row (multi-owner timelines that set `layerKey`/`layerLabel`):
// the layer's name + symbol, plus a trailing collapse glyph. Drawn heavier than
// a lane label so the layer reads as the outer grouping level. The symbol shows
// FILLED when the layer is collapsed, outline when expanded (so the row doubles
// as the collapse affordance). Defaults to a stacked-squares glyph.
- (void)_drawLayerHeaderRowForLane:(KKLane *)lane
                             inRow:(NSRect)row
                         collapsed:(BOOL)collapsed {
  NSColor *ink = [[NSColor inspectorLabel] colorWithAlphaComponent:0.9];
  NSString *name = lane.layerLabel.length ? lane.layerLabel : @"";
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:kGroupDividerFontSize
                                            weight:NSFontWeightBold],
    NSForegroundColorAttributeName : ink,
    NSKernAttributeName : @0.3,
  };
  NSSize tsz = [name sizeWithAttributes:attrs];
  CGFloat midY = NSMidY(row);
  // Anchor to the GRAPH's left/right edges (not the row rect, which starts
  // after the label gutter) so the layer name lines up flush-left with the
  // lane labels + category headers below it, instead of looking indented.
  NSRect g = [self _graphRect];

  NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration
      configurationWithPointSize:kGroupDividerFontSize
                          weight:NSFontWeightBold]
      configurationByApplyingConfiguration:
          [NSImageSymbolConfiguration configurationWithHierarchicalColor:ink]];

  NSString *base = lane.layerSymbol.length ? lane.layerSymbol : @"square.stack";
  NSString *symbol = collapsed ? [base stringByAppendingString:@".fill"] : base;
  NSImage *icon =
      [[NSImage imageWithSystemSymbolName:symbol
                 accessibilityDescription:nil] imageWithSymbolConfiguration:cfg]
          ?: [[NSImage imageWithSystemSymbolName:base
                        accessibilityDescription:nil]
                 imageWithSymbolConfiguration:cfg];
  CGFloat x = NSMinX(g) + kRowLabelInset;
  if (icon) {
    CGFloat iconH = icon.size.height;
    [icon drawInRect:NSMakeRect(x, floor(midY - iconH * 0.5), icon.size.width,
                                iconH)];
    x += icon.size.width + KKPaddingSM;
  }
  // Locked layer: a lock glyph between the layer icon and its name marks the
  // whole layer read-only (the lanes below are washed instead of overlaid
  // here).
  if (lane.locked) {
    NSImage *lockImg = [[NSImage imageWithSystemSymbolName:@"lock.fill"
                                  accessibilityDescription:nil]
        imageWithSymbolConfiguration:cfg];
    if (lockImg) {
      CGFloat lh = lockImg.size.height;
      [lockImg drawInRect:NSMakeRect(x, floor(midY - lh * 0.5),
                                     lockImg.size.width, lh)];
      x += lockImg.size.width + KKPaddingSM;
    }
  }
  [name drawAtPoint:NSMakePoint(x, floor(midY - tsz.height * 0.5))
      withAttributes:attrs];

  // Trailing chevron echoes the collapse state at the graph's right edge.
  NSString *chev = collapsed ? @"chevron.right" : @"chevron.down";
  NSImage *chevImg = [[NSImage imageWithSystemSymbolName:chev
                                accessibilityDescription:nil]
      imageWithSymbolConfiguration:cfg];
  if (chevImg) {
    CGFloat cw = chevImg.size.width, ch = chevImg.size.height;
    [chevImg drawInRect:NSMakeRect(NSMaxX(g) - kRowLabelInset - cw,
                                   floor(midY - ch * 0.5), cw, ch)];
  }
}

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

  // Rows (labels, curves, pills, hover) clip to the container's rounded-rect
  // shape so scrolled content can't bleed into the pinned ruler above, past the
  // graph below, or out of the rounded corners.
  [NSGraphicsContext saveGraphicsState];
  [track addClip];

  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    NSRect row = [self _rowRectForIndex:i count:lanes.count];
    // A header row draws a name + collapse glyph in place of a lane
    // label/curve - the category header for a categorised run, otherwise the
    // layer (owner) header.
    if (lane.headerPlaceholder) {
      if (lane.categoryHeader)
        [self _drawCategoryHeaderRowForLane:lane
                                      inRow:row
                                  collapsed:[_collapsedCategoryKeys
                                                containsObject:lane.label]];
      else
        [self _drawLayerHeaderRowForLane:lane
                                   inRow:row
                               collapsed:[_collapsedLayerKeys
                                             containsObject:lane.layerKey
                                                                ?: @""]];
      continue;
    }
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
  // doesn't bleed into the label gutter or beyond the track edges. The left
  // edge keeps a small pad so the t=0 pill + halo draw whole; the right edge
  // runs out to the container edge so the last-frame pill and its selection
  // halo overflow whole into the free right gutter, the same way the playhead
  // knob overflows.
  CGFloat edgePad = kPillW * 0.5 + 2.0;
  CGFloat clipL = NSMinX(tracks) - edgePad;
  [NSGraphicsContext saveGraphicsState];
  NSRectClip(NSMakeRect(clipL, NSMinY(g), NSMaxX(g) - clipL, NSHeight(g)));
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (lane.headerPlaceholder)
      continue;
    NSRect row = [self _rowRectForIndex:i count:lanes.count];
    [self _drawLane:lane inRow:row tracks:tracks];
  }
  [NSGraphicsContext restoreGraphicsState]; // curve clip

  // Locked layers are read-only: wash their rows (labels, header, curve, pills)
  // toward the background so they read as disabled but still visible.
  NSColor *lockWash =
      [[NSColor inspectorBackground] colorWithAlphaComponent:0.6];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    // Lane rows wash to read as disabled; the layer HEADER row is left clean
    // and instead shows a lock glyph (drawn in _drawLayerHeaderRowForLane:).
    if (!lanes[i].locked || lanes[i].headerPlaceholder)
      continue;
    NSRect row = [self _rowRectForIndex:i count:lanes.count];
    NSRect wash = NSInsetRect(row, -kPillW * 0.5, 0);
    [lockWash setFill];
    NSRectFillUsingOperation(wash, NSCompositingOperationSourceOver);
  }
  [NSGraphicsContext restoreGraphicsState]; // outer rows clip

  // Fade shadows over the rows go under the ruler / playhead so those stay
  // crisp; the row content above/below fades into a shadow when it scrolls.
  [self _drawScrollFadesInRect:g];

  [self _drawRulerInRect:g tracks:tracks];
  [self _drawDurationOverlayInRect:g tracks:tracks];
  [self _drawPlayheadInRect:g tracks:tracks];
  [self _drawDragSnapGuideInRect:g tracks:tracks];
  [self _drawMarqueeRect];
}

- (void)_drawScrollFadesInRect:(NSRect)g {
  CGFloat maxY = [self _maxScrollY];
  if (maxY <= 0.0)
    return;
  CGFloat fadeH = 16.0;
  CGFloat peak = 0.33;
  // Strength tracks how far the rows are scrolled past each edge (ramping up
  // over the first fadeH points), so the shadow grows/shrinks with the scroll
  // amount rather than snapping on/off.
  CGFloat topA = peak * MAX(0.0, MIN(1.0, _scrollY / fadeH));
  CGFloat botA = peak * MAX(0.0, MIN(1.0, (maxY - _scrollY) / fadeH));
  NSColor *clear = [NSColor colorWithCalibratedWhite:0.0 alpha:0.0];
  // Clip to the track's rounded rect so the fade follows the rounded corners
  // instead of squaring them off.
  [NSGraphicsContext saveGraphicsState];
  [[NSBezierPath bezierPathWithRoundedRect:g
                                   xRadius:KKRadiusMD
                                   yRadius:KKRadiusMD] addClip];
  // Top fade: rows lie above the viewport once scrolled down (y-up, so the
  // top edge is NSMaxY). Shadow at the top edge fading to clear below it.
  if (topA > 0.001) {
    NSRect r = NSMakeRect(NSMinX(g), NSMaxY(g) - fadeH, NSWidth(g), fadeH);
    NSGradient *grad = [[NSGradient alloc]
        initWithStartingColor:clear
                  endingColor:[NSColor colorWithCalibratedWhite:0.0
                                                          alpha:topA]];
    [grad drawInRect:r angle:90.0];
  }
  // Bottom fade: more rows lie below the viewport.
  if (botA > 0.001) {
    NSRect r = NSMakeRect(NSMinX(g), NSMinY(g), NSWidth(g), fadeH);
    NSGradient *grad = [[NSGradient alloc]
        initWithStartingColor:[NSColor colorWithCalibratedWhite:0.0 alpha:botA]
                  endingColor:clear];
    [grad drawInRect:r angle:90.0];
  }
  [NSGraphicsContext restoreGraphicsState];
}

- (void)_drawDurationPillInRect:(NSRect)g
                         tracks:(NSRect)tracks
                           lane:(KKLane *)lane
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
  CGFloat xA = [self _xForFrac:fracA inLane:lane inTracks:tracks];
  CGFloat xB = [self _xForFrac:fracB inLane:lane inTracks:tracks];
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
          KKLaneKeyposeValuesEqual(lane, prev, lane.keyposes[_pressKPIdx])
              ? neutral
              : warn;
      [self _drawDurationPillInRect:g
                             tracks:tracks
                               lane:lane
                              fracA:prev.time
                              fracB:tHere
                               tint:tint
                             rulerY:rulerY];
    }
    if (_pressKPIdx + 1 < (NSInteger)lane.keyposes.count) {
      KKKeyPose *next = lane.keyposes[_pressKPIdx + 1];
      NSColor *tint =
          KKLaneKeyposeValuesEqual(lane, lane.keyposes[_pressKPIdx], next)
              ? neutral
              : warn;
      [self _drawDurationPillInRect:g
                             tracks:tracks
                               lane:lane
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
    NSColor *tint = KKLaneKeyposeValuesEqual(lane, a, b) ? neutral : warn;
    [self _drawDurationPillInRect:g
                           tracks:tracks
                             lane:lane
                            fracA:a.time
                            fracB:b.time
                             tint:tint
                           rulerY:rulerY];
    return;
  }

  // Leading / trailing hold: not an editable interval, so show its duration in
  // gray (informational only) to match the gray line.
  if (_hoverEdgeLabel) {
    KKLane *lane = [self _animatableLaneForLabel:_hoverEdgeLabel];
    if (!lane || lane.keyposes.count < 1)
      return;
    NSColor *gray = [[NSColor inspectorLabel] colorWithAlphaComponent:0.5];
    if (_hoverEdgeLeading) {
      [self _drawDurationPillInRect:g
                             tracks:tracks
                               lane:lane
                              fracA:0.0
                              fracB:lane.keyposes.firstObject.time
                               tint:gray
                             rulerY:rulerY];
    } else {
      [self _drawDurationPillInRect:g
                             tracks:tracks
                               lane:lane
                              fracA:lane.keyposes.lastObject.time
                              fracB:[self _lastFrameFrac]
                               tint:gray
                             rulerY:rulerY];
    }
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
  // Under the warp the snap target is a time, not a cross-lane column, so a
  // full-height guide would zigzag. Draw it only inside the dragged lane's row
  // at that lane's warped x; linear mode keeps the full-height guide.
  if (_dynamicDisplay && _pressLaneLabel) {
    NSArray<KKLane *> *anim = [self _animatableLanes];
    for (NSInteger i = 0; i < (NSInteger)anim.count; i++) {
      if (![anim[i].label isEqualToString:_pressLaneLabel])
        continue;
      NSRect row = [self _rowRectForIndex:i count:anim.count];
      CGFloat y0 = MAX(NSMinY(row), NSMinY(g));
      CGFloat y1 = MIN(NSMaxY(row), NSMaxY(g));
      if (y1 <= y0)
        return;
      CGFloat lx = round([self _xForFrac:_dragSnapFrac
                                  inLane:anim[i]
                                inTracks:tracks]) +
                   0.5;
      NSBezierPath *line = [NSBezierPath bezierPath];
      [line moveToPoint:NSMakePoint(lx, y0)];
      [line lineToPoint:NSMakePoint(lx, y1)];
      line.lineWidth = 1.0;
      [[NSColor systemYellowColor] setStroke];
      [line stroke];
      return;
    }
    return;
  }
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
  // Geometry lanes (Points) have no scalar to plot - swap in a signature line.
  if (lane.oscEditedOnly) {
    lane = KKAdvGeometryLaneForPlot(lane);
    kps = lane.keyposes;
  }
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
  // Composite gradient lanes don't plot their raw [type, angle, stops...] -
  // they plot 1-2 derived lines (a stops "signature", plus angle when linear),
  // all in 0..1, so the scale stays fixed and the raw sampling below is
  // skipped.
  BOOL gradComposite = (lane.valueType == KKLaneValueTypeGradient &&
                        lane.gradientShowsTypeAngle);
  BOOL gradLinear = gradComposite && kps.firstObject.values.count >= 1 &&
                    llround(kps.firstObject.values[0].doubleValue) == 1;
  NSArray<NSNumber *> * (^laneVals)(NSArray<NSNumber *> *) =
      ^NSArray<NSNumber *> *(NSArray<NSNumber *> *raw) {
    return gradComposite ? KKAdvGradientDerived(raw, gradLinear) : raw;
  };
  if (gradComposite)
    compCount = gradLinear ? 2 : 1;
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
  // For a Linear gradient only the angle line (derived component 0) auto-scales
  // to its sampled range so a modulation wiggle shows clean symmetric humps;
  // the signature line stays on the fixed 0..1 scale. A geometry lane's hash
  // signature is already in [0,1) and must stay on that fixed scale (expanding
  // it to the sampled hash range makes the line fill the row and read as if
  // un-normalised). Non-gradient lanes expand all components as before.
  NSUInteger expandCount =
      (gradComposite || lane.oscEditedOnly) ? (gradLinear ? 1 : 0) : compCount;
  for (NSInteger i = 0; expandCount > 0 && i + 1 < (NSInteger)kps.count; i++) {
    KKKeyPose *ka = kps[i];
    KKKeyPose *kb = kps[i + 1];
    BOOL flat =
        KKAdvValuesEqual(ka.values, kb.values) &&
        (!ka.outgoing || ka.outgoing.modulation == KKIntervalModulationNone);
    NSInteger samples = flat ? 1 : 16;
    for (NSInteger k = 0; k <= samples; k++) {
      double t = (samples > 0) ? (double)k / (double)samples : 0.0;
      double gFrac = ka.time + (kb.time - ka.time) * t;
      NSArray<NSNumber *> *vals =
          laneVals(KKTimelineLaneValueAtFraction(lane, gFrac));
      for (NSUInteger c = 0; c < expandCount && c < vals.count; c++) {
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
  // Clip to the boundary pills' pixel-aligned outer edges so the curve's round
  // cap can't poke past them (the pill snaps its x to round(x)+0.5 - see
  // _drawPillForKPInLane - but the curve uses the raw track edge). Clamp to the
  // container (track +/- half a pill, which is the rounded background's edge)
  // so the snap only ever pulls the clip inward, never past the container.
  CGFloat clipL = MAX(NSMinX(tracks) - innerEdgePad,
                      round(NSMinX(tracks)) - innerEdgePad + 0.5);
  CGFloat clipR = MIN(NSMaxX(tracks) + innerEdgePad,
                      round(NSMaxX(tracks)) + innerEdgePad + 0.5);
  [NSGraphicsContext saveGraphicsState];
  NSRectClip(NSMakeRect(clipL, NSMinY(row), clipR - clipL, NSHeight(row)));

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
  CGFloat firstX = [self _xForFrac:firstKP.time inLane:lane inTracks:tracks];
  CGFloat lastX = [self _xForFrac:lastKP.time inLane:lane inTracks:tracks];
  // Leading/trailing flat fills extend out to the widened inner clip
  // (tracks edge minus kPillW/2) so the lane line reaches under the t=0 /
  // t=1 pill's outer half - same edge the per-gap loop's first/last
  // segment will also be extended to below.
  // Leading (pre-first-pill) and trailing (post-last-pill) holds aren't gaps
  // between two pills, so there's no draggable interval there - draw them gray
  // to signal "not editable", distinct from the accent-coloured editable holds.
  NSColor *flatColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:compAlpha * 0.5];
  CGFloat leftEdge = NSMinX(tracks) - innerEdgePad;
  CGFloat rightEdge = NSMaxX(tracks) + innerEdgePad;
  if (firstX > leftEdge) {
    NSArray<NSNumber *> *fv = laneVals(firstKP.values);
    for (NSUInteger c = 0; c < compCount && c < fv.count; c++) {
      double n = KKAdvNormComponent(fv[c].doubleValue, cMin, cMax, c);
      CGFloat y = round(yBot + (yTop - yBot) * n) + 0.5;
      NSPoint pts[2] = {NSMakePoint(leftEdge, y), NSMakePoint(firstX, y)};
      KKStrokeTimelineCurve(pts, 2, lineW, NO, flatColor);
    }
  }
  if (lastX < rightEdge) {
    NSArray<NSNumber *> *lv = laneVals(lastKP.values);
    for (NSUInteger c = 0; c < compCount && c < lv.count; c++) {
      double n = KKAdvNormComponent(lv[c].doubleValue, cMin, cMax, c);
      CGFloat y = round(yBot + (yTop - yBot) * n) + 0.5;
      NSPoint pts[2] = {NSMakePoint(lastX, y), NSMakePoint(rightEdge, y)};
      KKStrokeTimelineCurve(pts, 2, lineW, NO, flatColor);
    }
  }

  for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++) {
    KKKeyPose *a = kps[i];
    KKKeyPose *b = kps[i + 1];
    CGFloat xA = [self _xForFrac:a.time inLane:lane inTracks:tracks];
    CGFloat xB = [self _xForFrac:b.time inLane:lane inTracks:tracks];
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
    // Colour lanes draw each channel in its own tint (R/G/B/A); other
    // multi-component lanes (including the composite gradient's derived
    // angle/signature lines) keep the shared accent/warn.
    NSArray<NSColor *> *compColors = (lane.valueType == KKLaneValueTypeColor)
                                         ? lane.componentLabelColors
                                         : nil;
    NSColor * (^curveColorForComp)(NSUInteger) = ^NSColor *(NSUInteger c) {
      if (compColors && c < compColors.count &&
          [compColors[c] isKindOfClass:[NSColor class]])
        return [compColors[c] colorWithAlphaComponent:compAlpha];
      return color;
    };

    if (!anyDiffer && !hasModulation) {
      NSArray<NSNumber *> *av = laneVals(a.values);
      for (NSUInteger c = 0; c < compCount && c < av.count; c++) {
        double n = KKAdvNormComponent(av[c].doubleValue, cMin, cMax, c);
        CGFloat y = round(yBot + (yTop - yBot) * n) + 0.5;
        NSPoint pts[2] = {NSMakePoint(xA, y), NSMakePoint(xB, y)};
        KKStrokeTimelineCurve(pts, 2, lineW, NO, curveColorForComp(c));
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
          laneVals(KKTimelineLaneValueAtFraction(lane, globalFrac));
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
      KKStrokeTimelineCurve(pts[c], n + 1, lineW, NO, curveColorForComp(c));
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
    CGFloat xA = [self _xForFrac:kps[i].time inLane:lane inTracks:tracks];
    CGFloat xB = [self _xForFrac:kps[i + 1].time inLane:lane inTracks:tracks];
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
    CGFloat xA = [self _xForFrac:kps[i].time inLane:lane inTracks:tracks];
    CGFloat xB = [self _xForFrac:kps[i + 1].time inLane:lane inTracks:tracks];
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
  CGFloat x = [self _xForFrac:kp.time inLane:lane inTracks:tracks];
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
  // The ruler is linear (real time) in both modes, so the knob always sits at
  // the linear playhead position up in the ruler band.
  CGFloat knobX =
      round([self _xForFrac:_playheadFraction inTracks:tracks]) + 0.5;
  CGFloat top = NSMaxY(g) + kRulerGap + kRulerH;
  NSColor *phc = [NSColor inspectorLabel];
  // Contain the scrubber horizontally to the tracks area (not the full
  // container) so a zoomed/panned playhead can't draw over the label gutter -
  // same reason the ruler maps into `tracks`. Expanded by the knob half-width
  // so the frac 0/1 endpoint knobs still show whole. Vertical is left free so
  // the knob sits up in the ruler.
  CGFloat knobHalf = 7.0 / 2.0;
  [NSGraphicsContext saveGraphicsState];
  NSRectClip(NSMakeRect(NSMinX(tracks) - knobHalf, NSMinY(g),
                        NSWidth(tracks) + 2.0 * knobHalf,
                        NSMaxY(self.bounds) - NSMinY(g)));

  if (_dynamicDisplay) {
    // Lanes warp independently, so a single cross-lane line would lie. Draw a
    // per-lane playback line at this real time's warped position in each row;
    // only the ruler thumb spans the linear axis above.
    NSArray<KKLane *> *lanes = [self _animatableLanes];
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
      KKLane *lane = lanes[i];
      if (lane.headerPlaceholder)
        continue;
      NSRect row = [self _rowRectForIndex:i count:lanes.count];
      CGFloat y0 = MAX(NSMinY(row), NSMinY(g));
      CGFloat y1 = MIN(NSMaxY(row), NSMaxY(g));
      if (y1 <= y0)
        continue;
      CGFloat lx = round([self _xForFrac:_playheadFraction
                                  inLane:lane
                                inTracks:tracks]) +
                   0.5;
      NSBezierPath *line = [NSBezierPath bezierPath];
      [line moveToPoint:NSMakePoint(lx, y0)];
      [line lineToPoint:NSMakePoint(lx, y1)];
      line.lineWidth = 1.0;
      [[phc colorWithAlphaComponent:0.85] setStroke];
      [line stroke];
    }
  } else {
    NSBezierPath *line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(knobX, NSMinY(g))];
    [line lineToPoint:NSMakePoint(knobX, top)];
    line.lineWidth = 1.0;
    [[phc colorWithAlphaComponent:0.85] setStroke];
    [line stroke];
  }

  CGFloat kw = 7.0, kh = 6.0;
  NSBezierPath *knob = [NSBezierPath bezierPath];
  [knob moveToPoint:NSMakePoint(knobX - kw / 2.0, top)];
  [knob lineToPoint:NSMakePoint(knobX + kw / 2.0, top)];
  [knob lineToPoint:NSMakePoint(knobX + kw / 2.0, top - kh + 3.0)];
  [knob lineToPoint:NSMakePoint(knobX, top - kh)];
  [knob lineToPoint:NSMakePoint(knobX - kw / 2.0, top - kh + 3.0)];
  [knob closePath];
  [phc setFill];
  [knob fill];
  [NSGraphicsContext restoreGraphicsState];
}

@end
