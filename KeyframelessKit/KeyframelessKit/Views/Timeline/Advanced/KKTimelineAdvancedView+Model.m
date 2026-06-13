/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineAdvancedView_Private.h"
#import "KKTimelineScrubMath.h"
#import "KKTokens.h"

@implementation KKTimelineAdvancedView (Model)

- (NSArray<KKLane *> *)_animatableLanes {
  // Mode-gated lanes (visibleWhen) drop out of the graph when their
  // controller's current value doesn't match - e.g. an animated Gradient lane
  // is hidden while Mode = Solid. Computed over the full lane set so the
  // controller resolves; display-only, the blob keeps every lane.
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneLabels(_timeline.lanes, nil);
  NSMutableArray<KKLane *> *out = [NSMutableArray array];
  for (KKLane *l in _timeline.lanes)
    if (l.enabled && ![_hiddenLaneLabels containsObject:l.label] &&
        [condVisible containsObject:l.label])
      [out addObject:l];
  return out;
}

- (double)_clipDuration {
  if (_clipDurationSeconds > 0.0)
    return _clipDurationSeconds;
  double m = 0.0;
  for (KKLane *l in _timeline.lanes)
    if (l.lastKnownClipDuration > m)
      m = l.lastKnownClipDuration;
  return m;
}

// Fraction of the last RENDERABLE frame: FCP's last frame sits one frame before
// the clip's out-point. The visible track maps data [0, lastFrameFrac] onto
// [0, 1] of its width, so a final keypose (snapped to lastFrameFrac by the
// apply-time rule) and the out-point playhead both park at the right edge -
// matching Basic, which draws its out-end pill at the visual edge. Returns 1.0
// (identity mapping) when durations are unknown or a frame spans the whole
// clip.
- (double)_lastFrameFrac {
  double clipDur = [self _clipDuration];
  if (clipDur <= 0.0 || _frameDurationSeconds <= 0.0 ||
      _frameDurationSeconds >= clipDur)
    return 1.0;
  return (clipDur - _frameDurationSeconds) / clipDur;
}

- (NSRect)_graphRect {
  CGFloat top = kRulerH + kRulerGap + kGraphPadTop;
  CGFloat bottom = kGraphPadBottom;
  return NSMakeRect(kGraphPadX, bottom, NSWidth(self.bounds) - 2 * kGraphPadX,
                    NSHeight(self.bounds) - bottom - top);
}

// Tracks start after the lane-label gutter. The gutter grows to fit the widest
// localized label (e.g. German "Zuschnitt" is wider than the English default),
// floored at the original English width so en/short languages are unchanged and
// capped at half the graph so a very long name can never swallow the timeline.
- (CGFloat)_trackLeftOffset {
  NSRect g = [self _graphRect];
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightMedium]
  };
  CGFloat maxW = 0.0;
  for (KKLane *lane in [self _animatableLanes]) {
    NSString *label = KKLocalizedParamName(lane.label ?: @"");
    maxW = MAX(maxW, ceil([label sizeWithAttributes:attrs].width));
  }
  // inset (left) + label + inset (gap before tracks)
  CGFloat needed = kRowLabelInset + maxW + kRowLabelInset;
  CGFloat floor = kRowLabelW + kRowLabelInset;
  CGFloat cap = NSWidth(g) * 0.5;
  return MAX(floor, MIN(needed, cap));
}

- (NSRect)_tracksRect {
  NSRect g = [self _graphRect];
  CGFloat x = NSMinX(g) + [self _trackLeftOffset];
  // Inset by half a pill on each side so a keypose at frac 0/1 sits fully
  // inside the track background (its center lands halfPill in from the edge)
  // and the curve can't escape the bounds when a lane has no end pill. Every
  // frac<->x consumer (pills, curve, ruler, playhead, scrub, zoom/pan) reads
  // this rect, so they all stay aligned.
  CGFloat pad = kPillW / 2.0;
  // Extra padding on the right so the content (pills, ruler, curve) is pushed
  // off the container's right edge slightly; the container background (g) keeps
  // its full width.
  return NSMakeRect(x + pad, NSMinY(g),
                    MAX(0.0, NSMaxX(g) - x - 2.0 * pad - KKPaddingMD),
                    NSHeight(g));
}

- (CGFloat)_xForFrac:(double)frac inTracks:(NSRect)t {
  double z = _zp ? _zp.zoom : 1.0;
  double pan = _zp ? _zp.panOffset : 0.0;
  // Map data frac through [0, lastFrameFrac] -> [0, 1] (visual) so the last
  // frame lands on the right edge - see _lastFrameFrac.
  double lf = [self _lastFrameFrac];
  double vf = lf < 1.0 ? frac / lf : frac;
  return NSMinX(t) + (vf - pan) * NSWidth(t) * z;
}

- (double)_fracForX:(CGFloat)x inTracks:(NSRect)t {
  if (NSWidth(t) <= 0)
    return 0.0;
  double z = _zp ? _zp.zoom : 1.0;
  double pan = _zp ? _zp.panOffset : 0.0;
  double vf = pan + (x - NSMinX(t)) / (NSWidth(t) * z);
  double lf = [self _lastFrameFrac];
  double f = lf < 1.0 ? vf * lf : vf;
  // Clamp to the last renderable frame (the visual right edge where the final
  // pill parks), not 1.0 - otherwise scrub + snap run past the last pill into
  // the one-frame out-point overshoot.
  double hi = lf < 1.0 ? lf : 1.0;
  return f < 0.0 ? 0.0 : (f > hi ? hi : f);
}

- (NSArray<NSNumber *> *)_groupDividerFlags {
  NSArray<KKLane *> *lanes = [self _animatableLanes];
  NSMutableArray<NSNumber *> *flags =
      [NSMutableArray arrayWithCapacity:lanes.count];
  NSString *prev = nil;
  for (KKLane *l in lanes) {
    NSString *cat = l.categoryKey.length ? l.categoryKey : nil;
    // A header sits above the first lane of each categorised run, and stays
    // even when only that one group is shown - so e.g. Amount / Spread / Speed
    // keep the "Noise" header that gives them meaning. Uncategorised lanes get
    // no header, so plugins without categories keep the flat layout.
    BOOL start = cat != nil && ![cat isEqualToString:prev];
    [flags addObject:@(start)];
    prev = cat;
  }
  return flags;
}

// Divider strips + inter-lane gaps that precede lane `upto` (exclusive when
// negative-sentinel), summed from the group flags. `upto` == n totals them all.
- (void)_dividerCount:(NSInteger *)outDividers
             gapCount:(NSInteger *)outGaps
              through:(NSInteger)upto {
  NSArray<NSNumber *> *flags = [self _groupDividerFlags];
  NSInteger d = 0, g = 0;
  for (NSInteger j = 0; j < upto; j++) {
    BOOL start = j < (NSInteger)flags.count && flags[j].boolValue;
    if (start)
      d++;
    else if (j > 0)
      g++; // a non-start row below the top carries a plain gap above it
  }
  if (outDividers)
    *outDividers = d;
  if (outGaps)
    *outGaps = g;
}

- (CGFloat)_rowHeightForCount:(NSInteger)n {
  if (n <= 0)
    return 0.0;
  NSRect t = [self _tracksRect];
  NSInteger dividers = 0, gaps = 0;
  [self _dividerCount:&dividers gapCount:&gaps through:n];
  CGFloat avail = NSHeight(t) - kRowGap * (CGFloat)gaps -
                  kGroupDividerH * (CGFloat)dividers;
  CGFloat h = avail / (CGFloat)n;
  if (h < kRowMin)
    h = kRowMin;
  return floor(h);
}

- (NSRect)_rowRectForIndex:(NSInteger)i count:(NSInteger)n {
  NSRect t = [self _tracksRect];
  CGFloat h = [self _rowHeightForCount:n];
  // Dividers + gaps stacked above this row's top (the row's own leading divider
  // is counted; its preceding plain gap is not, since a group-start row has a
  // strip instead). +_scrollY raises the rows (y-up). Single funnel: drawing,
  // hit-testing and popover anchors all read row positions from here.
  NSInteger dAbove = 0, gAbove = 0;
  [self _dividerCount:&dAbove gapCount:&gAbove through:i + 1];
  CGFloat y = NSMaxY(t) + _scrollY -
              ((CGFloat)(i + 1) * h + (CGFloat)gAbove * kRowGap +
               (CGFloat)dAbove * kGroupDividerH);
  return NSMakeRect(NSMinX(t), y, NSWidth(t), h);
}

- (CGFloat)_maxScrollY {
  NSInteger n = [self _animatableCount];
  if (n <= 0)
    return 0.0;
  CGFloat h = [self _rowHeightForCount:n];
  NSInteger dividers = 0, gaps = 0;
  [self _dividerCount:&dividers gapCount:&gaps through:n];
  CGFloat contentH = h * (CGFloat)n + kRowGap * (CGFloat)gaps +
                     kGroupDividerH * (CGFloat)dividers;
  CGFloat avail = NSHeight([self _tracksRect]);
  return MAX(0.0, contentH - avail);
}

- (void)_clampScroll {
  CGFloat maxY = [self _maxScrollY];
  CGFloat clamped = MAX(0.0, MIN(_scrollY, maxY));
  if (clamped != _scrollY)
    _scrollY = clamped;
}

// Candidate snap fractions = every distinct keypose time across all
// animatable lanes (de-duped to within a frame's worth so a Crop KP and a
// Radius KP at the same boundary count as one target).
- (NSArray<NSNumber *> *)_snapCandidates {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (KKLane *l in _timeline.lanes) {
    if (!l.enabled)
      continue;
    for (KKKeyPose *kp in l.keyposes)
      [out addObject:@(kp.time)];
  }
  [out sortUsingSelector:@selector(compare:)];
  NSMutableArray<NSNumber *> *deduped = [NSMutableArray array];
  double last = -1.0;
  for (NSNumber *n in out) {
    if (n.doubleValue - last > 1.0e-4) {
      [deduped addObject:n];
      last = n.doubleValue;
    }
  }
  return deduped;
}

// Index of the KP that starts the interval containing `frac` in this lane,
// or -1 if `frac` is before the first or after the last KP (no interval).
- (NSInteger)_intervalStartKPIdxInLane:(KKLane *)lane atFrac:(double)frac {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++) {
    if (kps[i].time <= frac && frac <= kps[i + 1].time)
      return i;
  }
  return -1;
}

- (NSInteger)_animatableIndexForLabel:(NSString *)label {
  NSInteger i = 0;
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    if ([lane.label isEqualToString:label])
      return i;
    i++;
  }
  return -1;
}

- (NSInteger)_animatableCount {
  NSInteger n = 0;
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled)
      n++;
  return n;
}

- (KKLane *)_animatableLaneForLabel:(NSString *)label {
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled && [lane.label isEqualToString:label])
      return lane;
  return nil;
}

// Per-label "identity" default from the plugin's lane template - used when
// a lane has zero keyposes and the user is adding the first one back.
- (NSArray<NSNumber *> *)_templateDefaultValuesForLabel:(NSString *)label {
  KKLane *tmpl = nil;
  for (KKLane *l in _availableLanes)
    if ([l.label isEqualToString:label]) {
      tmpl = l;
      break;
    }
  if (!tmpl)
    return @[ @0.0 ];
  NSArray<NSNumber *> *tmplDefault = tmpl.keyposes.firstObject.values;
  if (tmplDefault.count)
    return tmplDefault;
  if (tmpl.valueType == KKLaneValueTypeCrop)
    return @[ @1.0, @1.0, @0.0, @0.0 ];
  if (tmpl.componentMin.count)
    return @[ tmpl.componentMin[0] ];
  return @[ @0.0 ];
}

- (NSString *)_selectionKeyForLabel:(NSString *)label kpIdx:(NSInteger)idx {
  return [NSString stringWithFormat:@"%@#%ld", label, (long)idx];
}

- (BOOL)_decodeSelectionKey:(NSString *)key
                      label:(NSString *_Nullable *_Nullable)outLabel
                      kpIdx:(NSInteger *_Nullable)outIdx {
  NSRange r = [key rangeOfString:@"#" options:NSBackwardsSearch];
  if (r.location == NSNotFound)
    return NO;
  if (outLabel)
    *outLabel = [key substringToIndex:r.location];
  if (outIdx)
    *outIdx = [[key substringFromIndex:r.location + 1] integerValue];
  return YES;
}

- (BOOL)_pillSelected:(KKLane *)lane atIdx:(NSInteger)idx {
  return [_selection containsObject:[self _selectionKeyForLabel:lane.label
                                                          kpIdx:idx]];
}

- (NSString *)_gapKeyForLabel:(NSString *)label aIdx:(NSInteger)aIdx {
  return [NSString stringWithFormat:@"%@#%ld", label, (long)aIdx];
}

- (BOOL)_gapSelected:(KKLane *)lane aIdx:(NSInteger)aIdx {
  return [_selectedGaps containsObject:[self _gapKeyForLabel:lane.label
                                                        aIdx:aIdx]];
}

// Find a pill under `pt`: returns the lane index in _animatableLanes and the
// keypose index within that lane, or both -1 if no pill is hit. Last-touched
// pill gets first refusal - when two pills overlap, the one the user just
// dragged into the stack draws on top and stays the click target.
- (BOOL)_pillAtPoint:(NSPoint)pt
                lane:(NSInteger *)outLaneIdx
                  kp:(NSInteger *)outKPIdx {
  NSArray<KKLane *> *lanes = [self _animatableLanes];
  NSRect tracks = [self _tracksRect];
  CGFloat halfHit = kPillW * 0.5 + 3.0;
  if (_topLaneLabel) {
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
      if (![lanes[i].label isEqualToString:_topLaneLabel])
        continue;
      NSRect row = [self _rowRectForIndex:i count:lanes.count];
      if (pt.y < NSMinY(row) || pt.y > NSMaxY(row))
        break;
      if (_topKPIdx < 0 || _topKPIdx >= (NSInteger)lanes[i].keyposes.count)
        break;
      CGFloat x = [self _xForFrac:lanes[i].keyposes[_topKPIdx].time
                           inLane:lanes[i]
                         inTracks:tracks];
      if (fabs(pt.x - x) <= halfHit) {
        *outLaneIdx = i;
        *outKPIdx = _topKPIdx;
        return YES;
      }
      break;
    }
  }
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    NSRect row = [self _rowRectForIndex:i count:lanes.count];
    if (pt.y < NSMinY(row) || pt.y > NSMaxY(row))
      continue;
    KKLane *lane = lanes[i];
    for (NSInteger j = (NSInteger)lane.keyposes.count - 1; j >= 0; j--) {
      CGFloat x = [self _xForFrac:lane.keyposes[j].time
                           inLane:lane
                         inTracks:tracks];
      if (fabs(pt.x - x) <= halfHit) {
        *outLaneIdx = i;
        *outKPIdx = j;
        return YES;
      }
    }
  }
  *outLaneIdx = -1;
  *outKPIdx = -1;
  return NO;
}

- (NSInteger)_laneRowAtPoint:(NSPoint)pt {
  // Rows are clipped to the graph rect; a row scrolled partly under the pinned
  // ruler must not register a hit through the ruler band.
  NSRect g = [self _graphRect];
  if (pt.y < NSMinY(g) || pt.y > NSMaxY(g))
    return -1;
  NSArray<KKLane *> *lanes = [self _animatableLanes];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    NSRect row = [self _rowRectForIndex:i count:lanes.count];
    if (pt.y >= NSMinY(row) && pt.y <= NSMaxY(row))
      return i;
  }
  return -1;
}

@end
