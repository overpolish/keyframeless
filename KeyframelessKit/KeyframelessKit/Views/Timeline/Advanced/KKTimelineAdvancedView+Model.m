/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineAdvancedView_Private.h"
#import "KKTimelineScrubMath.h"
#import "KKTokens.h"

@implementation KKAdvancedRow {
  KKAdvancedRowKind _kind;
  KKLane *_lane;
  NSString *_collapseKey;
  NSString *_headerTitle;
  NSString *_headerSymbol;
  BOOL _headerLocked;
  BOOL _headerIndented;
}

@synthesize kind = _kind, lane = _lane, collapseKey = _collapseKey,
            headerTitle = _headerTitle, headerSymbol = _headerSymbol,
            headerLocked = _headerLocked, headerIndented = _headerIndented;

- (BOOL)isHeader {
  return _kind != KKAdvancedRowLane;
}

+ (instancetype)rowWithLane:(KKLane *)lane {
  KKAdvancedRow *r = [[KKAdvancedRow alloc] init];
  r->_kind = KKAdvancedRowLane;
  r->_lane = lane;
  return r;
}

+ (instancetype)layerHeaderWithKey:(NSString *)layerKey
                             title:(NSString *)title
                            symbol:(NSString *)symbol
                            locked:(BOOL)locked {
  KKAdvancedRow *r = [[KKAdvancedRow alloc] init];
  r->_kind = KKAdvancedRowLayerHeader;
  r->_collapseKey = [layerKey copy];
  r->_headerTitle = [title copy];
  r->_headerSymbol = [symbol copy];
  r->_headerLocked = locked;
  return r;
}

+ (instancetype)categoryHeaderWithKey:(NSString *)collapseKey
                                title:(NSString *)title
                               symbol:(NSString *)symbol
                             indented:(BOOL)indented {
  KKAdvancedRow *r = [[KKAdvancedRow alloc] init];
  r->_kind = KKAdvancedRowCategoryHeader;
  r->_collapseKey = [collapseKey copy];
  r->_headerTitle = [title copy];
  r->_headerSymbol = [symbol copy];
  r->_headerIndented = indented;
  return r;
}

@end

@implementation KKTimelineAdvancedView (Model)

- (NSArray<KKAdvancedRow *> *)_rows {
  // Mode-gated lanes (visibleWhen) drop out of the graph when their
  // controller's current value doesn't match - e.g. an animated Gradient lane
  // is hidden while Mode = Solid. Computed over the full lane set so the
  // controller resolves; display-only, the blob keeps every lane.
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneKeys(_timeline.lanes, nil);
  NSMutableArray<KKLane *> *out = [NSMutableArray array];
  for (KKLane *l in _timeline.lanes)
    if (l.enabled && ![_hiddenLaneLabels containsObject:l.key] &&
        [condVisible containsObject:l.key])
      [out addObject:l];

  NSMutableArray<KKAdvancedRow *> *result = [NSMutableArray array];

  // Single-owner plugins (no layerKey on any lane): no layer level, so the
  // category headers (if any) sit at the top level. Plugins without categories
  // append flat - no headers, layout unchanged.
  BOOL hasLayers = NO;
  for (KKLane *l in out)
    if (l.layerKey.length) {
      hasLayers = YES;
      break;
    }
  if (!hasLayers) {
    [self _appendCategoryGroupedLanes:out layerKey:nil into:result];
    return result;
  }

  // Multi-owner: emit, per layer in stack order, a layer HEADER row then
  // (unless collapsed) that layer's lanes - themselves grouped under
  // collapsible category headers. The layer header is always present so a
  // collapsed layer stays visible + re-expandable.
  for (NSString *lk in [self _orderedLayerKeysForLanes:out]) {
    KKLane *sample = nil;
    for (KKLane *l in out)
      if ([(l.layerKey ?: @"") isEqualToString:lk]) {
        sample = l;
        break;
      }
    [result addObject:[KKAdvancedRow layerHeaderWithKey:lk
                                                  title:sample.layerLabel ?: @""
                                                 symbol:sample.layerSymbol
                                                 locked:sample.locked]];
    if ([_collapsedLayerKeys containsObject:lk])
      continue;
    NSMutableArray<KKLane *> *layerLanes = [NSMutableArray array];
    for (KKLane *l in out)
      if ([(l.layerKey ?: @"") isEqualToString:lk])
        [layerLanes addObject:l];
    [self _appendCategoryGroupedLanes:layerLanes layerKey:lk into:result];
  }
  return result;
}

// The collapse identity for a category, scoped by its owning layer so the same
// categoryKey (e.g. "Transform") collapses independently in each Canvas layer.
// Single-owner plugins pass a nil layerKey, giving a bare category key.
- (NSString *)_categoryCollapseKeyForLayer:(nullable NSString *)layerKey
                                  category:(NSString *)category {
  return [NSString stringWithFormat:@"%@\x1f%@", layerKey ?: @"", category];
}

// Append `lanes` (already in display order, all from one owner) to `result`,
// injecting a synthetic CATEGORY HEADER row before the first lane of each
// categorised run and skipping that run's lanes while the category is
// collapsed. Uncategorised lanes are always appended with no header, so a
// plugin that sets no categoryKey keeps the flat layout.
- (void)_appendCategoryGroupedLanes:(NSArray<KKLane *> *)lanes
                           layerKey:(nullable NSString *)layerKey
                               into:(NSMutableArray<KKAdvancedRow *> *)result {
  NSString *prevCat = nil;
  BOOL collapsedRun = NO;
  for (KKLane *l in lanes) {
    NSString *cat = l.categoryKey.length ? l.categoryKey : nil;
    if (cat && ![cat isEqualToString:prevCat]) {
      NSString *collapseKey = [self _categoryCollapseKeyForLayer:layerKey
                                                        category:cat];
      [result
          addObject:[KKAdvancedRow categoryHeaderWithKey:collapseKey
                                                   title:cat
                                                  symbol:l.categorySymbol
                                                indented:layerKey.length > 0]];
      collapsedRun = [_collapsedCategoryKeys containsObject:collapseKey];
    } else if (!cat) {
      collapsedRun = NO;
    }
    prevCat = cat;
    if (cat && collapsedRun)
      continue;
    [result addObject:[KKAdvancedRow rowWithLane:l]];
  }
}

// Layer keys present among `lanes`, in layerOrder (stack) order, extras last.
- (NSArray<NSString *> *)_orderedLayerKeysForLanes:(NSArray<KKLane *> *)lanes {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  for (NSString *lk in (self.layerOrder ?: @[])) {
    if ([seen containsObject:lk])
      continue;
    for (KKLane *l in lanes)
      if ([(l.layerKey ?: @"") isEqualToString:lk]) {
        [keys addObject:lk];
        [seen addObject:lk];
        break;
      }
  }
  for (KKLane *l in lanes) {
    NSString *lk = l.layerKey ?: @"";
    if (lk.length && ![seen containsObject:lk]) {
      [keys addObject:lk];
      [seen addObject:lk];
    }
  }
  return keys;
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
  for (KKAdvancedRow *r in [self _rows]) {
    if (r.isHeader)
      continue; // header rows draw a full-width name, not a gutter label
    NSString *label = KKLocalizedParamName(r.lane.displayName ?: @"");
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

// Inter-row gaps that precede row `upto`. Layer AND category headers are full
// rows now (no thin divider strips), so every row below the top carries a plain
// kRowGap above it; there are no dividers. `upto` == n totals them all. The
// dividers out-param is retained (always 0) so the height formulas keep their
// general `gaps*kRowGap + dividers*kGroupDividerH` shape.
- (void)_dividerCount:(NSInteger *)outDividers
             gapCount:(NSInteger *)outGaps
              through:(NSInteger)upto {
  NSInteger g = 0;
  for (NSInteger j = 1; j < upto; j++)
    g++;
  if (outDividers)
    *outDividers = 0;
  if (outGaps)
    *outGaps = g;
}

// The height of a single LANE row. Layer-header rows take a fixed compact
// height (kLayerHeaderRowH) and are excluded from the equal split, so the real
// lanes share whatever is left - a collapsed layer (header only) frees its
// space for the others instead of holding a full row.
- (CGFloat)_rowHeightForCount:(NSInteger)n {
  if (n <= 0)
    return 0.0;
  NSArray<KKAdvancedRow *> *rows = [self _rows];
  NSInteger headers = 0;
  for (KKAdvancedRow *r in rows)
    if (r.isHeader)
      headers++;
  NSInteger laneRows = n - headers;
  if (laneRows <= 0)
    return 0.0; // only headers visible (every layer collapsed)
  NSRect t = [self _tracksRect];
  NSInteger dividers = 0, gaps = 0;
  [self _dividerCount:&dividers gapCount:&gaps through:n];
  CGFloat avail = NSHeight(t) - kRowGap * (CGFloat)gaps -
                  kGroupDividerH * (CGFloat)dividers -
                  kLayerHeaderRowH * (CGFloat)headers;
  CGFloat h = avail / (CGFloat)laneRows;
  if (h < kRowMin)
    h = kRowMin;
  return floor(h);
}

// Own height of row `i`: fixed for a layer-header row, the shared lane height
// otherwise.
- (CGFloat)_ownHeightForRow:(NSInteger)i
                     inRows:(NSArray<KKAdvancedRow *> *)rows
                   laneRowH:(CGFloat)laneRowH {
  if (i >= 0 && i < (NSInteger)rows.count && rows[i].isHeader)
    return kLayerHeaderRowH;
  return laneRowH;
}

- (NSRect)_rowRectForIndex:(NSInteger)i count:(NSInteger)n {
  NSRect t = [self _tracksRect];
  NSArray<KKAdvancedRow *> *rows = [self _rows];
  CGFloat laneRowH = [self _rowHeightForCount:n];
  // Sum the own-heights of rows 0..i (headers fixed, lanes shared) plus the
  // dividers + gaps stacked above this row's top (the row's own leading divider
  // is counted; its preceding plain gap is not, since a group-start row has a
  // strip instead). +_scrollY raises the rows (y-up). Single funnel: drawing,
  // hit-testing and popover anchors all read row positions from here.
  CGFloat rowsAbove = 0.0;
  for (NSInteger j = 0; j <= i && j < (NSInteger)rows.count; j++)
    rowsAbove += [self _ownHeightForRow:j inRows:rows laneRowH:laneRowH];
  CGFloat ownH = [self _ownHeightForRow:i inRows:rows laneRowH:laneRowH];
  NSInteger dAbove = 0, gAbove = 0;
  [self _dividerCount:&dAbove gapCount:&gAbove through:i + 1];
  CGFloat y = NSMaxY(t) + _scrollY -
              (rowsAbove + (CGFloat)gAbove * kRowGap +
               (CGFloat)dAbove * kGroupDividerH);
  return NSMakeRect(NSMinX(t), y, NSWidth(t), ownH);
}

- (CGFloat)_maxScrollY {
  NSInteger n = [self _animatableCount];
  if (n <= 0)
    return 0.0;
  NSArray<KKAdvancedRow *> *rows = [self _rows];
  CGFloat laneRowH = [self _rowHeightForCount:n];
  NSInteger dividers = 0, gaps = 0;
  [self _dividerCount:&dividers gapCount:&gaps through:n];
  CGFloat rowsH = 0.0;
  for (NSInteger j = 0; j < (NSInteger)rows.count; j++)
    rowsH += [self _ownHeightForRow:j inRows:rows laneRowH:laneRowH];
  CGFloat contentH =
      rowsH + kRowGap * (CGFloat)gaps + kGroupDividerH * (CGFloat)dividers;
  CGFloat avail = NSHeight([self _tracksRect]);
  return MAX(0.0, contentH - avail);
}

- (void)_clampScroll {
  CGFloat maxY = [self _maxScrollY];
  CGFloat clamped = MAX(0.0, MIN(_scrollY, maxY));
  if (clamped != _scrollY)
    _scrollY = clamped;
}

- (void)_ensureLaneRowVisible:(NSInteger)i count:(NSInteger)n {
  if (i < 0 || n <= 0)
    return;
  NSRect g = [self _graphRect];
  NSRect row = [self _rowRectForIndex:i count:n];
  // _scrollY raises rows (y-up): + moves them up, - moves them down. Nudge the
  // minimum amount to bring the row fully inside [NSMinY(g), NSMaxY(g)].
  CGFloat newScroll = _scrollY;
  if (NSMinY(row) < NSMinY(g))
    newScroll += NSMinY(g) - NSMinY(row);
  else if (NSMaxY(row) > NSMaxY(g))
    newScroll -= NSMaxY(row) - NSMaxY(g);
  newScroll = MAX(0.0, MIN(newScroll, [self _maxScrollY]));
  if (newScroll != _scrollY) {
    _scrollY = newScroll;
    [self setNeedsDisplay:YES];
  }
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
  // Index into the DISPLAYED row list (-_rows), which injects layer/
  // category header rows and drops hidden/collapsed/mode-gated lanes - the same
  // list -_rowRectForIndex:count: walks. Walking _timeline.lanes instead
  // mis-mapped every row below a category header (e.g. Core/Noise), so a
  // guide cutout for a lane/keypose landed on the wrong row. Returns -1 when
  // the lane isn't currently a visible row (collapsed/hidden), so the guide
  // rect methods yield NSZeroRect.
  NSArray<KKAdvancedRow *> *rows = [self _rows];
  for (NSInteger i = 0; i < (NSInteger)rows.count; i++)
    if (!rows[i].isHeader && [rows[i].lane.key isEqualToString:label])
      return i;
  return -1;
}

- (NSInteger)_animatableCount {
  return (NSInteger)[self _rows].count;
}

- (KKLane *)_animatableLaneForLabel:(NSString *)label {
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled && [lane.key isEqualToString:label])
      return lane;
  return nil;
}

// Per-label "identity" default from the plugin's lane template - used when
// a lane has zero keyposes and the user is adding the first one back.
- (NSArray<NSNumber *> *)_templateDefaultValuesForLabel:(NSString *)label {
  KKLane *tmpl = nil;
  for (KKLane *l in _availableLanes)
    if ([l.key isEqualToString:label]) {
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
  return [_selection containsObject:[self _selectionKeyForLabel:lane.key
                                                          kpIdx:idx]];
}

- (NSString *)_gapKeyForLabel:(NSString *)label aIdx:(NSInteger)aIdx {
  return [NSString stringWithFormat:@"%@#%ld", label, (long)aIdx];
}

- (BOOL)_gapSelected:(KKLane *)lane aIdx:(NSInteger)aIdx {
  return [_selectedGaps containsObject:[self _gapKeyForLabel:lane.key
                                                        aIdx:aIdx]];
}

// Find a pill under `pt`: returns the lane index in _rows and the
// keypose index within that lane, or both -1 if no pill is hit. Last-touched
// pill gets first refusal - when two pills overlap, the one the user just
// dragged into the stack draws on top and stays the click target.
- (BOOL)_pillAtPoint:(NSPoint)pt
                lane:(NSInteger *)outLaneIdx
                  kp:(NSInteger *)outKPIdx {
  NSArray<KKAdvancedRow *> *rows = [self _rows];
  NSRect tracks = [self _tracksRect];
  CGFloat halfHit = kPillW * 0.5 + 3.0;
  if (_topLaneLabel) {
    for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
      KKLane *top = rows[i].lane;
      if (![top.key isEqualToString:_topLaneLabel])
        continue;
      NSRect row = [self _rowRectForIndex:i count:rows.count];
      if (pt.y < NSMinY(row) || pt.y > NSMaxY(row))
        break;
      if (_topKPIdx < 0 || _topKPIdx >= (NSInteger)top.keyposes.count)
        break;
      CGFloat x = [self _xForFrac:top.keyposes[_topKPIdx].time
                           inLane:top
                         inTracks:tracks];
      if (fabs(pt.x - x) <= halfHit) {
        *outLaneIdx = i;
        *outKPIdx = _topKPIdx;
        return YES;
      }
      break;
    }
  }
  for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
    NSRect row = [self _rowRectForIndex:i count:rows.count];
    if (pt.y < NSMinY(row) || pt.y > NSMaxY(row))
      continue;
    KKLane *lane = rows[i].lane;
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
  NSArray<KKAdvancedRow *> *rows = [self _rows];
  for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
    NSRect row = [self _rowRectForIndex:i count:rows.count];
    if (pt.y >= NSMinY(row) && pt.y <= NSMaxY(row))
      return i;
  }
  return -1;
}

@end
