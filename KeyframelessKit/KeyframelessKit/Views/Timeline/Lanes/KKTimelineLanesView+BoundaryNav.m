/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKMiniCanvasRenderer.h"
#import "KKMiniCanvasView.h"
#import "KKPopoverHeaderView.h"
#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSegmentEditView.h>

@implementation KKTimelineLanesView (BoundaryNav)

- (nullable NSSet<NSString *> *)_scopedLaneLabelsForOpenPopover {
  if (_advancedGraph && !_advancedGraph.hidden) {
    NSString *primary = _advancedGraph.primaryLaneLabel;
    if (primary)
      return [NSSet setWithObject:primary];
  }
  if (_openStaticBoundaryLanes.count == 0)
    return nil;
  NSMutableSet<NSString *> *labels = [NSMutableSet set];
  for (KKLane *l in _openStaticBoundaryLanes)
    if (l.label)
      [labels addObject:l.label];
  return labels;
}

- (void)_publishBoundaryRequestForFraction:(double)fraction {
  // Filmstrip / Onion = one frame per KP across the lanes participating in
  // the open popover (same-group as the clicked KP), time-sorted. Off =
  // single-frame at the clicked fraction. KP-snap (within ~1 frame) so
  // Basic's OutEnd (frac=1.0 click vs endFrac<1.0 KP) doesn't produce a
  // phantom extra cell.
  if (_renderMode != KKMiniCanvasRenderModeOff) {
    NSSet<NSString *> *scope = [self _scopedLaneLabelsForOpenPopover];
    NSMutableArray<NSNumber *> *kpTimes = [NSMutableArray array];
    for (KKLane *lane in _timeline.lanes) {
      if (!lane.enabled)
        continue;
      if (scope && ![scope containsObject:lane.label])
        continue;
      for (KKKeyPose *kp in lane.keyposes)
        [kpTimes addObject:@(kp.time)];
    }
    const double kSnapToKP = 0.05;
    double snapped = fraction;
    double bestDt = kSnapToKP;
    for (NSNumber *t in kpTimes) {
      double dt = fabs(t.doubleValue - fraction);
      if (dt < bestDt) {
        bestDt = dt;
        snapped = t.doubleValue;
      }
    }
    NSMutableArray<NSNumber *> *all = [NSMutableArray array];
    [all addObject:@(snapped)];
    [all addObjectsFromArray:kpTimes];
    [all sortUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *ordered = [NSMutableArray array];
    const double dedupEps = [self _kpDedupEps];
    for (NSNumber *f in all) {
      if (ordered.count == 0 ||
          fabs(f.doubleValue - ordered.lastObject.doubleValue) > dedupEps)
        [ordered addObject:f];
    }
    NSArray<NSNumber *> *collapsed = [self _collapseTiedHolds:ordered
                                                        scope:scope];
    KKWriteBoundaryRequestMulti(self.miniCanvasRequestPath, collapsed, YES);
  } else {
    KKWriteBoundaryRequest(self.miniCanvasRequestPath, fraction, YES);
  }
}

// Time-sorted, eps-deduped list of every KP fraction across animatable
// lanes - the navigable set behind the popover's prev/next buttons.
- (NSArray<NSNumber *> *)_animatableKPFractions {
  NSSet<NSString *> *scope = [self _scopedLaneLabelsForOpenPopover];
  NSMutableArray<NSNumber *> *kpTimes = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    if (scope && ![scope containsObject:lane.label])
      continue;
    for (KKKeyPose *kp in lane.keyposes)
      [kpTimes addObject:@(kp.time)];
  }
  [kpTimes sortUsingSelector:@selector(compare:)];
  NSMutableArray<NSNumber *> *deduped = [NSMutableArray array];
  const double dedupEps = [self _kpDedupEps];
  for (NSNumber *f in kpTimes) {
    if (deduped.count == 0 ||
        fabs(f.doubleValue - deduped.lastObject.doubleValue) > dedupEps)
      [deduped addObject:f];
  }
  return [self _collapseTiedHolds:deduped scope:scope];
}

// YES when every in-scope lane is constant across the open span (a,b) *because
// it's a tied/linked flat hold* (or the lane simply isn't animating there) -
// i.e. the frame at b is identical to the one at a by user intent, not
// coincidence. A lane with a real transition straddling the span returns NO
// (keep the cell). Spans passed here are consecutive entries in the KP-time
// union, so no lane has an interior KP between a and b: each sits in exactly
// one interval, found by the midpoint.
- (BOOL)_spanIsTiedHoldBetween:(double)a
                           and:(double)b
                         scope:(nullable NSSet<NSString *> *)scope {
  double mid = 0.5 * (a + b);
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    if (scope && ![scope containsObject:lane.label])
      continue;
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    if (kps.count < 2)
      continue; // constant lane - never blocks
    KKKeyPose *ia = nil, *ib = nil;
    for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++) {
      if (kps[i].time <= mid && mid < kps[i + 1].time) {
        ia = kps[i];
        ib = kps[i + 1];
        break;
      }
    }
    if (!ia)
      continue; // span lies outside this lane's KP range - constant there
    if (!(ia.outgoing.endpointsLinked &&
          _kkBoundaryValuesEqual(ia.values, ib.values)))
      return NO;
  }
  return YES;
}

// Drop KP times whose span from the previous time is a tied/linked flat hold
// across all in-scope lanes - collapsing a tie-bar hold to a single
// representative (the earlier KP) so the filmstrip / onion / prev-next nav
// don't show identical frames twice. Input must be time-sorted.
- (NSArray<NSNumber *> *)_collapseTiedHolds:(NSArray<NSNumber *> *)sorted
                                      scope:
                                          (nullable NSSet<NSString *> *)scope {
  if (sorted.count < 2)
    return sorted;
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  [out addObject:sorted[0]];
  for (NSUInteger i = 1; i < sorted.count; i++) {
    if ([self _spanIsTiedHoldBetween:sorted[i - 1].doubleValue
                                 and:sorted[i].doubleValue
                               scope:scope])
      continue;
    [out addObject:sorted[i]];
  }
  return out;
}

// Returns the index of the KP closest to `frac` in `fracs` (NSNotFound only
// if the list is empty). Mirrors the snap behaviour used when publishing
// the boundary request so prev/next agree with the rendered filmstrip.
- (NSInteger)_indexOfFraction:(double)frac
                     inSorted:(NSArray<NSNumber *> *)fracs {
  if (fracs.count == 0)
    return NSNotFound;
  NSInteger best = 0;
  double bestDt = INFINITY;
  for (NSInteger i = 0; i < (NSInteger)fracs.count; i++) {
    double dt = fabs(fracs[i].doubleValue - frac);
    if (dt < bestDt) {
      bestDt = dt;
      best = i;
    }
  }
  return best;
}

- (void)_refreshBoundaryPopoverNavEnabled {
  if (!_openStaticView)
    return;
  NSArray<NSNumber *> *fracs = [self _animatableKPFractions];
  NSInteger idx = [self _indexOfFraction:_openStaticBoundaryFraction
                                inSorted:fracs];
  BOOL prev = (idx != NSNotFound && idx > 0);
  BOOL next = (idx != NSNotFound && idx + 1 < (NSInteger)fracs.count);
  [_openStaticView setNavPrevEnabled:prev nextEnabled:next];
}

- (void)_navigateBoundaryPopoverDirection:(NSInteger)direction {
  if (!(_openContentPopover.isShown && _openStaticIsBoundary))
    return;
  NSArray<NSNumber *> *fracs = [self _animatableKPFractions];
  NSInteger idx = [self _indexOfFraction:_openStaticBoundaryFraction
                                inSorted:fracs];
  if (idx == NSNotFound)
    return;
  NSInteger target = idx + direction;
  if (target < 0 || target >= (NSInteger)fracs.count)
    return;
  double newFrac = fracs[target].doubleValue;
  // Same path the filmstrip cell click uses - graph rebuilds the display
  // lanes for the new KP, then calls back into the in-place updater.
  if (_activeTab == 1) {
    [_advancedGraph requestValuePopoverAtFraction:newFrac];
  } else {
    [_basicGraph requestValuePopoverAtFraction:newFrac];
  }
}

- (void)_renderModeDidChange:(KKMiniCanvasRenderMode)mode {
  _renderMode = mode;
  if (self.onRenderModeChanged)
    self.onRenderModeChanged(mode);
  if (self.onGuideRenderModeChanged)
    self.onGuideRenderModeChanged(mode);
  // Pill toggle while a boundary popover is open → re-publish so the
  // render side switches single↔multi without close/reopen.
  if (_openContentPopover.isShown && _openStaticIsBoundary && _openStaticView) {
    [self _publishBoundaryRequestForFraction:_openStaticBoundaryFraction];
    if (self.onBoundaryPreviewNeedsRender)
      self.onBoundaryPreviewNeedsRender();
  }
}

- (void)_republishBoundaryRequestIfOpen {
  if (_renderMode == KKMiniCanvasRenderModeOff)
    return;
  if (!(_openContentPopover.isShown && _openStaticIsBoundary &&
        _openStaticView))
    return;
  [self _publishBoundaryRequestForFraction:_openStaticBoundaryFraction];
  [self _refreshBoundaryPopoverNavEnabled];
  if (self.onBoundaryPreviewNeedsRender)
    self.onBoundaryPreviewNeedsRender();
}

- (void)_updateBoundaryPopoverInPlaceWithLanes:(NSArray<KKLane *> *)lanes
                                      fraction:(double)fraction
                                excludedLabels:
                                    (NSArray<NSString *> *)excludedLabels {
  if (!(_openContentPopover.isShown && _openStaticIsBoundary &&
        _openStaticView))
    return;
  BOOL fracChanged = fabs(fraction - _openStaticBoundaryFraction) > 1e-6;
  KKSetBoundaryEditing(self.miniCanvasDelegate, YES, fraction);
  KKSetSuppressedHandles(self.miniCanvasDelegate, excludedLabels);
  // Full row rebuild (not just value rebind): the editable↔Animate split can
  // change between fractions (navigate) or after add/remove, and the one-way
  // applyExcludedLabels: swap can't restore an editable row on its own.
  [_openStaticView rebuildRowsWithLanes:lanes excludedLabels:excludedLabels];
  [_openStaticView setHeaderDetail:[self _timeStringForFraction:fraction]];
  [_openStaticView setHeaderLinked:[self _anyLinkedKeyposeAtFraction:fraction]];
  _openStaticBoundaryFraction = fraction;
  _openStaticBoundaryLanes = [lanes copy];
  _openStaticBoundaryExcluded = [excludedLabels copy];
  // The render nudge writes an undoable param to force FCP to resolve the
  // preview frame at a NEW boundary time. A same-fraction in-place rebuild
  // (add / remove / undo-refresh) keeps the time, and the blob write already
  // triggers a render - nudging here would add a phantom undo entry (cmd-Z
  // would then need two presses). Only republish + nudge on a real time change
  // (navigation between boundaries).
  if (fracChanged) {
    [self _publishBoundaryRequestForFraction:fraction];
    if (self.onBoundaryPreviewNeedsRender)
      self.onBoundaryPreviewNeedsRender();
  }
  [self _refreshBoundaryPopoverNavEnabled];
}

@end
