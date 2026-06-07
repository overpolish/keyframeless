/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineBasicView_Private.h"

#import "KKKeyposeSymbol.h"
#import "KKMiniViewerView.h"
#import "KKSegmentEditView.h"
#import "KKTimelineScale.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineBasicView (BoundaryPopover)

- (void)_openBoundaryPopoverForDiamond:(NSInteger)d {
  if (_onDiamondTapped)
    _onDiamondTapped(d);
  if (!self.onBoundaryValuePopover)
    return;
  KKBasicProj p = [self _projection];
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0)
    return;

  KKBasicBoundary boundary;
  double frac;
  if (d == 1)
    boundary = p.inEnabled ? KKBasicBoundaryInStart : KKBasicBoundaryHold;
  else if (d == 4)
    boundary = p.outEnabled ? KKBasicBoundaryOutEnd : KKBasicBoundaryHold;
  else
    boundary = KKBasicBoundaryHold;

  if (boundary == KKBasicBoundaryInStart)
    frac = 0.0;
  else if (boundary == KKBasicBoundaryOutEnd)
    frac = 1.0;
  else if (d == 2)
    frac = p.inEndFrac;
  else if (d == 3)
    frac = p.outStartFrac;
  else
    frac = p.inEnabled ? p.inEndFrac : (p.outEnabled ? p.outStartFrac : 0.0);

  // Build synthetic single-keypose lanes carrying the value at this boundary
  // - with valueType / component bounds taken from the plugin template
  // (canonical), exactly like _timelineSeededFrom:, so the reused
  // static-values rows pick the right editor (Radius float 0–100, Crop grid).
  NSMutableArray<KKLane *> *displayLanes = [NSMutableArray array];
  NSMutableArray<NSString *> *excludedLabels = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    // A property "doesn't apply to" this boundary's phase when it has no
    // keypose there OR its phase interval is flat (holdsFlat) - either way it
    // sits at Hold through the phase. Flag it excluded (row becomes a message +
    // Animate, in place, preserving property order). Hold always participates.
    if (lane.keyposes.count >= 2) {
      KKHoldShape sh = KKShapeOfLane(lane);
      BOOL participates;
      if (boundary == KKBasicBoundaryInStart)
        participates =
            sh.inEnabled && !lane.keyposes.firstObject.outgoing.holdsFlat;
      else if (boundary == KKBasicBoundaryOutEnd)
        participates =
            sh.outEnabled && !lane.keyposes[sh.holdEnd].outgoing.holdsFlat;
      else
        participates = YES;
      if (!participates)
        [excludedLabels addObject:lane.label];
    }
    NSArray<NSNumber *> *vals = KKTimelineLaneValueAtFraction(lane, frac)
                                    ?: lane.keyposes.firstObject.values;
    KKLane *tmpl = nil;
    for (KKLane *t in _availableLanes)
      if ([t.label isEqualToString:lane.label]) {
        tmpl = t;
        break;
      }
    KKLane *dl = [KKLane laneWithLabel:lane.label];
    dl.valueType = tmpl ? tmpl.valueType : lane.valueType;
    dl.componentMin = tmpl ? tmpl.componentMin : lane.componentMin;
    dl.componentMax = tmpl ? tmpl.componentMax : lane.componentMax;
    dl.componentUnits = tmpl ? tmpl.componentUnits : lane.componentUnits;
    dl.componentLabels = tmpl ? tmpl.componentLabels : lane.componentLabels;
    dl.componentLabelColors =
        tmpl ? tmpl.componentLabelColors : lane.componentLabelColors;
    dl.spatialCurvable = tmpl ? tmpl.spatialCurvable : lane.spatialCurvable;
    // aspectLinkable is metadata (template); aspectLinked is user state (blob).
    dl.aspectLinkable = tmpl ? tmpl.aspectLinkable : lane.aspectLinkable;
    dl.aspectLinked = lane.aspectLinked;
    dl.integerValued = tmpl ? tmpl.integerValued : lane.integerValued;
    KKKeyPose *dlKp = [KKKeyPose keyposeAtTime:0.0 values:vals ?: @[ @0.0 ]];
    // Carry the curve state from the keypose nearest this boundary (matches the
    // nearest-match write) so the row's toggle reflects it.
    KKKeyPose *near = nil;
    double nd = INFINITY;
    for (KKKeyPose *k in lane.keyposes) {
      double d = fabs(k.time - frac);
      if (d < nd) {
        nd = d;
        near = k;
      }
    }
    if (near) {
      dlKp.spatialSmooth = near.spatialSmooth;
      dlKp.inHandle = near.inHandle;
      dlKp.outHandle = near.outHandle;
    }
    dl.keyposes = @[ dlKp ];
    [displayLanes addObject:dl];
  }
  if (displayLanes.count == 0 && excludedLabels.count == 0)
    return;

  // Anchor on the boundary pill (full track height) so the popover arrow
  // lands on the pill body regardless of where the click hit it.
  CGFloat pillX = KKBasicXForFrac((d == 1 ? 0.0 : d == 4 ? 1.0 : frac), g, p);
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame =
      NSMakeRect(pillX - kPillW * 0.5, NSMinY(g) + kPillInsetY, kPillW,
                 NSHeight(g) - 2.0 * kPillInsetY);

  // For an unlinked Hold, this picks the single targeted interior keypose
  // (d==2 → hold-start, d==3 → hold-end); ignored for In/Out boundaries.
  // Must be the *stored* keypose time, not `frac` - when a phase is off,
  // the projection pins frac to the clip edge (0/1) while the keypose stays
  // at its boundary, so frac would match neither Hold keypose and the edit
  // would be dropped.
  double holdStartTime = p.inEndFrac, holdEndTime = p.outStartFrac;
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled && lane.keyposes.count >= 2) {
      KKHoldShape s = KKShapeOfLane(lane);
      holdStartTime = lane.keyposes[s.holdStart].time;
      holdEndTime = lane.keyposes[s.holdEnd].time;
      break;
    }
  // Bind the popover's state into ivars so the closures below read live
  // values - that's what lets requestValuePopoverAtFraction: (filmstrip
  // click) swap boundaries on the open popover without rebuilding it.
  _curBoundary = boundary;
  _curBoundaryInOn = p.inEnabled;
  _curBoundaryOutOn = p.outEnabled;
  _curBoundaryHoldFrac = (d == 3) ? holdEndTime : holdStartTime;
  _curAnimateSec = (boundary == KKBasicBoundaryInStart) ? KKBasicSectionIn
                                                        : KKBasicSectionOut;
  _curDiamond = d;
  __weak typeof(self) weak = self;
  // Remove only applies to In/Out boundaries (their "applies to" set). Hold
  // always participates, so the Hold popover has no − gutter (onRemove nil).
  BOOL isInOut =
      (boundary == KKBasicBoundaryInStart || boundary == KKBasicBoundaryOutEnd);
  void (^onRemove)(NSString *) =
      isInOut ? ^(NSString *label) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        // Drop the property from this phase's applies-to (same as unticking
        // it in the gap popover). The projection derives In/Out enabled from
        // participation, so removing the last one turns the phase off - then
        // the boundary is gone and the popover closes.
        [s _setLaneParticipation:NO forLabel:label section:s->_curAnimateSec];
        KKBasicProj pp = [s _projection];
        BOOL phaseStillOn = (s->_curAnimateSec == KKBasicSectionOut)
                                ? pp.outEnabled
                                : pp.inEnabled;
        if (phaseStillOn)
          [s _openBoundaryPopoverForDiamond:s->_curDiamond];
        else if (s.onRequestClosePopover)
          s.onRequestClosePopover();
      }
              : nil;
  self.onBoundaryValuePopover(
      _popoverAnchor, displayLanes, frac, excludedLabels,
      ^(NSString *label, NSArray<NSNumber *> *values) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        [s _writeBoundary:s->_curBoundary
                    values:values
                  forLabel:label
                      inOn:s->_curBoundaryInOn
                     outOn:s->_curBoundaryOutOn
            holdTargetFrac:s->_curBoundaryHoldFrac];
      },
      ^(NSString *label) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        [s _setLaneParticipation:YES forLabel:label section:s->_curAnimateSec];
        [s _openBoundaryPopoverForDiamond:s->_curDiamond];
      },
      onRemove, self.onDragBegin, self.onDragEnd);
}

- (void)requestValuePopoverAtFraction:(double)fraction {
  // Map the requested fraction to whichever of the 4 boundary diamonds is
  // closest, then re-open at that diamond. Reuses the lanes-view in-place
  // rebind path for an already-open popover.
  KKBasicProj p = [self _projection];
  double in0 = 0.0, inE = p.inEndFrac, outS = p.outStartFrac, out1 = 1.0;
  double dists[4] = {fabs(fraction - in0), fabs(fraction - inE),
                     fabs(fraction - outS), fabs(fraction - out1)};
  NSInteger best = 0;
  double bestDt = dists[0];
  for (NSInteger i = 1; i < 4; i++)
    if (dists[i] < bestDt) {
      bestDt = dists[i];
      best = i;
    }
  // Diamond IDs are 1-indexed (1=InStart, 2=Hold-start, 3=Hold-end,
  // 4=OutEnd); array index `best` maps directly to (best + 1).
  [self _openBoundaryPopoverForDiamond:(best + 1)];
}

- (void)writeSpatialSmoothForLabel:(NSString *)label
                            atFrac:(double)frac
                              isOn:(BOOL)on {
  KKTimeline *t = KKTimelineSettingSpatialSmooth(_timeline, label, frac, on);
  if (!t)
    return;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)writeAspectLinkedForLabel:(NSString *)label isOn:(BOOL)on {
  KKTimeline *t = KKTimelineSettingAspectLinked(_timeline, label, on);
  if (!t)
    return;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Rewrite the keyposes that make up `boundary` for the lane `label`,
// preserving times + intervals. Hold sets every interior/edge hold keypose
// equal (stays flat); In-start / Out-end set just their endpoint keypose.
- (void)_writeBoundary:(KKBasicBoundary)boundary
                values:(NSArray<NSNumber *> *)values
              forLabel:(NSString *)label
                  inOn:(BOOL)inOn
                 outOn:(BOOL)outOn
        holdTargetFrac:(double)holdTargetFrac {
  // A linked Hold mirrors the value to both interior keyposes; an unlinked
  // Hold writes only the one the user grabbed, so the two can drift apart.
  BOOL holdLinked = [self _holdLinked];
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *nl = [lanes[i] copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    // Identify In-start / Out-end by INDEX from the lane's own shape, not by
    // comparing time to 0.0 / 1.0: the Out-end keypose is stored at
    // outEndFrac (≈0.99, one frame short of clip end so FCP can reach it), so
    // a `tm > 1.0 - kEps` test never matched it and the OutEnd edit was
    // silently dropped (the graph then re-read the old value, looking undone).
    KKHoldShape sh = KKShapeOfLane(nl);
    NSInteger lastIdx = (NSInteger)kps.count - 1;
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      double tm = kps[k].time;
      BOOL isIn = inOn && sh.inEnabled && k == 0;
      BOOL isOut = outOn && sh.outEnabled && k == lastIdx;
      BOOL isHold = !isIn && !isOut;
      if (isHold && !holdLinked && kps.count >= 2 &&
          fabs(tm - holdTargetFrac) > kEps)
        continue; // unlinked: only the grabbed interior keypose
      BOOL belongs = boundary == KKBasicBoundaryInStart  ? isIn
                     : boundary == KKBasicBoundaryOutEnd ? isOut
                                                         : isHold;
      if (!belongs)
        continue;
      KKKeyPose *nk = [kps[k] keyposeBySettingTime:tm];
      nk.values = values;
      kps[k] = nk;
    }
    nl.keyposes = kps;
    lanes[i] = nl;
    break;
  }
  [self _clearHoldModulationIfDrifted:lanes];
  t.lanes = lanes;
  _timeline = t;
  self.needsLayout = YES;
  [self layoutSubtreeIfNeeded]; // flush now so the Hold/Drift label
                                // refreshes in lockstep with the curve
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Drift and modulation are alternative authoring states in Basic - the Hold
// popover routes to one or the other based on `_holdDrift`, so a modulation
// field lingering on a now-drifting Hold has no UI access and would still
// wiggle the rendered curve. If the edit just caused the global Hold pair to
// drift, wipe modulation from every animatable lane's hold-start interval
// (re-linking won't bring it back - matches the mental model that drift
// replaced the wobble). Mutates `lanes` in place.
- (void)_clearHoldModulationIfDrifted:(NSMutableArray<KKLane *> *)lanes {
  BOOL nowDrifts = NO;
  for (KKLane *lane in lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (s.holdEnd > s.holdStart &&
        !KKValuesEqual(lane.keyposes[s.holdStart].values,
                       lane.keyposes[s.holdEnd].values)) {
      nowDrifts = YES;
      break;
    }
  }
  if (!nowDrifts)
    return;
  for (NSInteger li = 0; li < (NSInteger)lanes.count; li++) {
    KKLane *lane = lanes[li];
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    KKInterval *iv = lane.keyposes[s.holdStart].outgoing;
    if (!iv || iv.modulation == KKIntervalModulationNone)
      continue;
    KKLane *nl2 = [lane copy];
    NSMutableArray<KKKeyPose *> *kps2 = [nl2.keyposes mutableCopy];
    KKKeyPose *kp = [kps2[s.holdStart] copy];
    KKInterval *niv = [iv copy];
    niv.modulation = KKIntervalModulationNone;
    kp.outgoing = niv;
    kps2[s.holdStart] = kp;
    nl2.keyposes = kps2;
    lanes[li] = nl2;
  }
}

@end
