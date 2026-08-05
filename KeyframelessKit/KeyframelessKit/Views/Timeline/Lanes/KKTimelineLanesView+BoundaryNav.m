/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView.h"
#import "KKPopoverHeaderView.h"
#import "KKPopoverKeepAlive.h"
#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSegmentEditView.h>

@implementation KKTimelineLanesView (BoundaryNav)

- (id<KKBoundaryEditingGraph>)_activeGraph {
  return _activeTab == 1 ? (id<KKBoundaryEditingGraph>)_advancedGraph
                         : (id<KKBoundaryEditingGraph>)_basicGraph;
}

- (void)_suppressBoundaryRedrive {
  _boundaryRedriveSuppressUntil = [NSDate timeIntervalSinceReferenceDate] + 0.4;
}

- (void)_applyKeyposeEditStateWithLanes:(NSArray<KKLane *> *)lanes
                               fraction:(double)fraction
                         excludedLabels:(NSArray<NSString *> *)excludedLabels {
  KKSetBoundaryEditing(self.miniViewerDelegate, YES,
                       [self _snapEditFractionToKeypose:fraction]);
  KKSetSuppressedHandles(self.miniViewerDelegate, excludedLabels);
  _openStaticBoundaryFraction = fraction;
  _openStaticBoundaryLanes = [lanes copy];
  _openStaticBoundaryExcluded = [excludedLabels copy];
}

- (void)_exitKeyposeEditState {
  _lastPublishedBoundarySlots = nil;
  KKSetBoundaryEditing(self.miniViewerDelegate, NO, 0.0);
  KKSetSuppressedHandles(self.miniViewerDelegate, nil);
  KKWriteBoundaryRequest(self.miniViewerRequestPath, 0.0, NO);
}

- (void)_refreshOpenStaticPopoverAnyOptedIn:(BOOL)anyOptedIn {
  if (!_openStaticView)
    return;
  if (!_openStaticIsBoundary) {
    // Constants: re-scope the un-opted row set (a lane flipped to Animated
    // disappears without close/reopen), then re-apply per-lane state (values +
    // smooth + LINK) from the current selected-layer timeline. A
    // same-structure selection change (e.g. drawing another constant-stroke
    // path) reuses the rows and previously never re-read aspectLinked, so the
    // link toggle + its coupling stayed stale from the prior layer.
    // applyValues is focus-safe (skips an in-progress field edit), so this
    // won't clobber active editing.
    [_openStaticView updateUnoptedLanes:[self _unoptedLanes]];
    [_openStaticView rebindLanes:_timeline.lanes];
    // The popover's OWN mini viewer must read the SAME corrected timeline the
    // rows do (template-seeded aspectLinked / aspectLinkable), not the stale
    // applyTimeline copy - otherwise its OSC overlay (e.g. a ring's aspect
    // lock) disagrees with the row's link glyph. The delegate is always a
    // KKMiniViewerRenderer (plugins subclass it).
    if ([self.miniViewerDelegate isKindOfClass:[KKMiniViewerRenderer class]])
      ((KKMiniViewerRenderer *)self.miniViewerDelegate).timeline = _timeline;
    return;
  }
  // Keypose: the popover is built from a snapshot at open; an external
  // timeline change (cmd-Z / redo) reaches the graphs but not the popover, so
  // re-drive it from the active graph at its open fraction - the
  // active/Animate row split and values rebuild from the new state (e.g.
  // cmd-Z re-adding a keypose flips its row from "+ No keypose here" back to
  // editable). Suppressed briefly after a popover edit so the host's echo
  // write doesn't rebuild rows mid-interaction (add/remove already refresh
  // synchronously). No activation fire: re-scoping the open popover to the
  // same layer must not drive the host selection back (ping-pong against a
  // selection the user just changed) - only a user graph-click/nav moves
  // selection.
  if (!([self _editorPanelIsVisible] && anyOptedIn &&
        [NSDate timeIntervalSinceReferenceDate] >=
            _boundaryRedriveSuppressUntil))
    return;
  [[self _activeGraph] requestValuePopoverAtFraction:_openStaticBoundaryFraction
                                      fireActivation:NO];
}

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
    if (l.key)
      [labels addObject:l.key];
  return labels;
}

- (NSArray<NSNumber *> *)_boundarySlotFractionsForFraction:(double)fraction {
  // Filmstrip / Onion = one frame per KP across the lanes participating in
  // the open popover (same-group as the clicked KP), time-sorted. KP-snap
  // (within ~1 frame) so Basic's OutEnd (frac=1.0 click vs endFrac<1.0 KP)
  // doesn't produce a phantom extra cell.
  NSSet<NSString *> *scope = [self _scopedLaneLabelsForOpenPopover];
  NSMutableArray<NSNumber *> *kpTimes = [NSMutableArray array];
  for (KKLane *lane in [self _graphTimeline].lanes) {
    if (!lane.enabled)
      continue;
    if (scope && ![scope containsObject:lane.key])
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
  return [self _fractions:collapsed byRestoringAnchor:snapped from:ordered];
}

- (void)_publishBoundaryRequestForFraction:(double)fraction {
  if (_renderMode != KKMiniViewerRenderModeOff) {
    NSArray<NSNumber *> *slots =
        [self _boundarySlotFractionsForFraction:fraction];
    _lastPublishedBoundarySlots = slots;
    KKWriteBoundaryRequestMulti(self.miniViewerRequestPath, slots, YES);
  } else {
    _lastPublishedBoundarySlots = @[ @(fraction) ];
    KKWriteBoundaryRequest(self.miniViewerRequestPath, fraction, YES);
  }
}

// Snap a boundary fraction to the nearest animatable keypose time before it
// becomes the mini renderer's editFraction. BASIC represents the final boundary
// as the visual clip end (frac 1.0), while its keypose is stored one frame in
// (lastFrameFrac); the mini's on-keypose arc gate (KKLaneKeyedAtFraction) then
// misses it and shows only the anchor dot. Snapping to the actual keypose time
// makes BASIC match Advanced (which already passes the stored time). No-op when
// the fraction already sits on a keypose (interior boundaries).
// The preview must show the moment the user CLICKED, so this resolves against
// the uncollapsed keypose set. The tie-collapse (below) folds a linked pair's
// second keypose into the first on the theory that a flat hold renders an
// identical frame - true for the tied lane alone, false for the composite: the
// other lanes (Mirage rack nodes, Canvas layers) keep animating across that
// span, and a temporal effect (bloom, feedback, motion trails) hasn't
// accumulated at the run's start. Snapping here would preview the LINK SOURCE's
// moment instead of the clicked keypose's.
- (double)_snapEditFractionToKeypose:(double)fraction {
  NSArray<NSNumber *> *all = [self _allKPFractions];
  double best = fraction, bestDist = INFINITY;
  for (NSNumber *f in all) {
    double d = fabs(f.doubleValue - fraction);
    if (d < bestDist) {
      bestDist = d;
      best = f.doubleValue;
    }
  }
  return best;
}

- (NSArray<NSNumber *> *)_allKPFractions {
  NSSet<NSString *> *scope = [self _scopedLaneLabelsForOpenPopover];
  NSMutableArray<NSNumber *> *kpTimes = [NSMutableArray array];
  for (KKLane *lane in [self _graphTimeline].lanes) {
    if (!lane.enabled)
      continue;
    if (scope && ![scope containsObject:lane.key])
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
  return deduped;
}

// The navigable set behind the popover's prev/next buttons and the filmstrip:
// the deduped KP fractions with tie-collapsed runs folded away, but always
// including the keypose the popover is open on.
- (NSArray<NSNumber *> *)_animatableKPFractions {
  NSArray<NSNumber *> *all = [self _allKPFractions];
  NSArray<NSNumber *> *collapsed =
      [self _collapseTiedHolds:all
                         scope:[self _scopedLaneLabelsForOpenPopover]];
  return [self _fractions:collapsed
        byRestoringAnchor:_openStaticBoundaryFraction
                     from:all];
}

// Put the keypose the popover is actually open on back into a collapsed list
// that dropped it. The collapse exists to keep the filmstrip / prev-next from
// showing the same frame twice, but the OPEN keypose is never redundant - a
// dropped anchor previews (and navigates from) its link partner's moment, and
// leaves the live-value push aimed at a slot tag that isn't published.
- (NSArray<NSNumber *> *)_fractions:(NSArray<NSNumber *> *)collapsed
                  byRestoringAnchor:(double)anchor
                               from:(NSArray<NSNumber *> *)all {
  if (all.count == 0)
    return collapsed;
  double kp = all.firstObject.doubleValue, bestDist = INFINITY;
  for (NSNumber *f in all) {
    double d = fabs(f.doubleValue - anchor);
    if (d < bestDist) {
      bestDist = d;
      kp = f.doubleValue;
    }
  }
  const double dedupEps = [self _kpDedupEps];
  for (NSNumber *f in collapsed)
    if (fabs(f.doubleValue - kp) <= dedupEps)
      return collapsed;
  NSMutableArray<NSNumber *> *out = [collapsed mutableCopy];
  [out addObject:@(kp)];
  [out sortUsingSelector:@selector(compare:)];
  return out;
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
  for (KKLane *lane in [self _graphTimeline].lanes) {
    if (!lane.enabled)
      continue;
    if (scope && ![scope containsObject:lane.key])
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
  if (!([self _editorPanelIsVisible] && _openStaticIsBoundary))
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
  [[self _activeGraph] requestValuePopoverAtFraction:newFrac];
}

- (void)_renderModeDidChange:(KKMiniViewerRenderMode)mode {
  _renderMode = mode;
  if (self.onRenderModeChanged)
    self.onRenderModeChanged(mode);
  if (self.onGuideRenderModeChanged)
    self.onGuideRenderModeChanged(mode);
  // Pill toggle while a boundary popover is open → re-publish so the
  // render side switches single↔multi without close/reopen.
  if ([self _editorPanelIsVisible] && _openStaticIsBoundary &&
      _openStaticView) {
    [self _publishBoundaryRequestForFraction:_openStaticBoundaryFraction];
    if (self.onBoundaryPreviewNeedsRender)
      self.onBoundaryPreviewNeedsRender();
  }
}

// Scrub or playback with a keypose popover open: the playhead renders rightly
// take over the mini viewer while the timeline is moving - the user asked to
// see it move. But those renders consume the boundary request, so once the
// playhead SETTLES nothing re-asks for the keypose frame and the preview stays
// stuck on wherever the playhead stopped. Each render-tick push schedules a
// debounced re-request; while pushes keep arriving each one supersedes the
// last, and the final one fires after the playhead has been still for a beat -
// re-publishing the request and nudging a render, exactly what clicking the
// keypose did.
//
// Deliberately NOT via _republishBoundaryRequestIfOpen: that helper is the
// filmstrip re-drive and bails in render-mode Off, while this ping-back is
// wanted in every mode.
- (void)_scheduleBoundaryPingBackForPlayheadFraction:(double)frac {
  if (!_openStaticIsBoundary || !_openStaticView || frac < 0.0)
    return;
  if (fabs(frac - _boundaryPingBackLastFrac) < 1e-6)
    return; // playhead not actually moving: nothing consumed the request
  _boundaryPingBackLastFrac = frac;
  NSInteger gen = ++_boundaryPingBackGeneration;
  __weak typeof(self) weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weak) s = weak;
        if (!s || s->_boundaryPingBackGeneration != gen)
          return; // superseded: the playhead is still moving
        if (!s->_openStaticIsBoundary || !s->_openStaticView)
          return; // popover closed while we waited
        [s _publishBoundaryRequestForFraction:s->_openStaticBoundaryFraction];
        // Bring the playhead back to the keypose too: on an adjustment layer
        // the re-requested frame is only composited correctly with the
        // playhead there, and "settled" means the user has stopped steering.
        if (s.onBoundarySeekHostPlayhead)
          s.onBoundarySeekHostPlayhead(s->_openStaticBoundaryFraction);
        if (s.onBoundaryPreviewNeedsRender)
          s.onBoundaryPreviewNeedsRender();
      });
}

- (void)_republishBoundaryRequestIfOpen {
  if (_renderMode == KKMiniViewerRenderModeOff)
    return;
  if (!([self _editorPanelIsVisible] && _openStaticIsBoundary &&
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
  if (!([self _editorPanelIsVisible] && _openStaticIsBoundary &&
        _openStaticView))
    return;
  BOOL fracChanged = fabs(fraction - _openStaticBoundaryFraction) > 1e-6;
  [self _applyKeyposeEditStateWithLanes:lanes
                               fraction:fraction
                         excludedLabels:excludedLabels];
  // Retargeting to ANOTHER lane's keypose at the same time keeps the fraction
  // but re-scopes the keypose set behind the filmstrip, so the strip would keep
  // rendering the previous lane's frames until a close/reopen. Compare the slot
  // list the request would carry, not just the time. Cheap: a walk of the
  // scoped lanes' keyposes, the same one the fraction-change path already does.
  NSArray<NSNumber *> *slots =
      _renderMode == KKMiniViewerRenderModeOff
          ? @[ @(fraction) ]
          : [self _boundarySlotFractionsForFraction:fraction];
  BOOL slotsChanged = !(_lastPublishedBoundarySlots &&
                        [slots isEqualToArray:_lastPublishedBoundarySlots]);
  // Full row rebuild (not just value rebind): the editable↔Animate split can
  // change between fractions (navigate) or after add/remove, and the one-way
  // applyExcludedLabels: swap can't restore an editable row on its own.
  // rebuildRowsWithLanes: re-fits the popover to the new row count (handles a
  // re-target to a layer with fewer params).
  [_openStaticView rebuildRowsWithLanes:lanes excludedLabels:excludedLabels];
  [_openStaticView setHeaderDetail:[self _timeStringForFraction:fraction]];
  [_openStaticView setHeaderLinked:[self _anyLinkedKeyposeAtFraction:fraction]];
  // The render nudge writes an undoable param to force FCP to resolve the
  // preview frame at a NEW boundary time. A same-fraction, same-slots in-place
  // rebuild (add / remove / undo-refresh) shows the same frames, and the blob
  // write already triggers a render - nudging here would add a phantom undo
  // entry (cmd-Z would then need two presses). Only republish + nudge when the
  // preview content actually moves: a new time, or a new slot set (a retarget
  // to another lane's keypose).
  if (fracChanged) {
    // The popover window never closed, so nothing told the host it is now
    // editing a DIFFERENT moment - and an owner switcher that grays the owners
    // with no keypose here (Mirage's rack strip, Canvas's layer list) keeps the
    // set it derived at open time. Narrow signal, not a DidOpen re-post: the
    // companion panels riding that pair re-slide on every open.
    KKPostStaticValuesPopoverDidNavigate(self, YES, fraction);
  }
  if (fracChanged || slotsChanged) {
    [self _publishBoundaryRequestForFraction:fraction];
    // Navigation is "look at THAT keypose now", so the host playhead goes too -
    // required for adjustment layers, whose source only composites correctly
    // under the playhead. See onBoundarySeekHostPlayhead. Only on a time
    // change: a same-time lane switch is already under the playhead.
    if (fracChanged && self.onBoundarySeekHostPlayhead)
      self.onBoundarySeekHostPlayhead(fraction);
    if (self.onBoundaryPreviewNeedsRender)
      self.onBoundaryPreviewNeedsRender();
  }
  // Redraw the mini on ANY in-place update, not just a fraction change. Source
  // plugins redraw as a side effect of the feed re-publishing, but a generator
  // publishes nothing to the feed, so nothing wakes its paused MTKView. This
  // path runs on keypose nav (fraction changed), add/remove, AND an external
  // timeline change like cmd-Z / redo (SAME fraction, reverted values) - the
  // last case is why this must sit OUTSIDE the fracChanged guard, or an undo
  // updates the popover rows but leaves the generator preview stale. The
  // renderer's editFraction is already current (KKSetBoundaryEditing above);
  // harmless for source plugins (a redundant redraw).
  [_openStaticView.miniViewer setNeedsDisplay:YES];
  [self _refreshBoundaryPopoverNavEnabled];
}

@end
