/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../Math/KKTimelineScrubMath.h"
#import "../Style/KKTokens.h"
#import "KKLocalized.h"
#import "KKTimelineAdvancedView_Private.h"

@implementation KKTimelineAdvancedView (Model)

- (NSArray<KKLane *> *)_animatableLanes {
  NSMutableArray<KKLane *> *out = [NSMutableArray array];
  for (KKLane *l in _timeline.lanes)
    if (l.enabled)
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
  return NSMakeRect(x, NSMinY(g), NSMaxX(g) - x, NSHeight(g));
}

- (CGFloat)_xForFrac:(double)frac inTracks:(NSRect)t {
  double z = _zp ? _zp.zoom : 1.0;
  double pan = _zp ? _zp.panOffset : 0.0;
  return NSMinX(t) + (frac - pan) * NSWidth(t) * z;
}

- (double)_fracForX:(CGFloat)x inTracks:(NSRect)t {
  if (NSWidth(t) <= 0)
    return 0.0;
  double z = _zp ? _zp.zoom : 1.0;
  double pan = _zp ? _zp.panOffset : 0.0;
  double f = pan + (x - NSMinX(t)) / (NSWidth(t) * z);
  return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
}

- (CGFloat)_rowHeightForCount:(NSInteger)n {
  if (n <= 0)
    return 0.0;
  NSRect t = [self _tracksRect];
  CGFloat avail = NSHeight(t) - kRowGap * (CGFloat)(n - 1);
  CGFloat h = avail / (CGFloat)n;
  if (h < kRowMin)
    h = kRowMin;
  return floor(h);
}

- (NSRect)_rowRectForIndex:(NSInteger)i count:(NSInteger)n {
  NSRect t = [self _tracksRect];
  CGFloat h = [self _rowHeightForCount:n];
  CGFloat stride = h + kRowGap;
  CGFloat y = NSMaxY(t) - h - stride * (CGFloat)i;
  return NSMakeRect(NSMinX(t), y, NSWidth(t), h);
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

// Per-label "identity" default from the plugin's lane template — used when
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
// pill gets first refusal — when two pills overlap, the one the user just
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
      CGFloat x = [self _xForFrac:lane.keyposes[j].time inTracks:tracks];
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
  NSArray<KKLane *> *lanes = [self _animatableLanes];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    NSRect row = [self _rowRectForIndex:i count:lanes.count];
    if (pt.y >= NSMinY(row) && pt.y <= NSMaxY(row))
      return i;
  }
  return -1;
}

@end
