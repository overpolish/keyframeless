/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAdvancedView_Private.h"

#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKLocalized.h>
#import <KeyframelessKit/KKPathMorph.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineAdvancedView (Popovers)

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

- (void)writeGradientTypeForLabel:(NSString *)label type:(NSInteger)type {
  KKTimeline *t = KKTimelineSettingGradientType(_timeline, label, type);
  if (!t)
    return;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)_openValuePopoverForLane:(NSInteger)laneIdx kp:(NSInteger)kpIdx {
  [self _openValuePopoverForLane:laneIdx kp:kpIdx fireActivation:YES];
}

- (void)_openValuePopoverForLane:(NSInteger)laneIdx
                              kp:(NSInteger)kpIdx
                  fireActivation:(BOOL)fireActivation {
  if (!self.onValuePopover)
    return;
  NSArray<KKLane *> *lanes = [self _animatableLanes];
  if (laneIdx < 0 || laneIdx >= (NSInteger)lanes.count)
    return;
  KKLane *lane = lanes[laneIdx];
  if (kpIdx < 0 || kpIdx >= (NSInteger)lane.keyposes.count)
    return;
  KKKeyPose *kp = lane.keyposes[kpIdx];
  double frac = kp.time;

  // The keypose popover scopes to this lane's layer (multi-owner timelines).
  // Tell the host so it selects/highlights that layer. Fire EVERY open (not
  // only when _activeLayerKey changes): the host selection can diverge from the
  // keypose owner via an external change (drawing a new path, picking a
  // no-keypose layer in Constants) while _activeLayerKey already equals the
  // owner - a change-gated fire would never correct it. Set _activeLayerKey
  // FIRST so the host's retarget (which compares against it) early-returns - no
  // re-entrancy; the host handler also no-ops when already on that layer.
  if (lane.layerKey.length) {
    _activeLayerKey = [lane.layerKey copy];
    // Only a USER landing on this keypose (a graph click / nav) moves the host
    // selection to its owner. A selection-DRIVEN re-drive (retarget after the
    // host already changed layers, or a timeline re-feed) passes NO - firing
    // here would drive selection back to the popover's stale owner, the
    // ping-pong.
    if (fireActivation && self.onKeyposeLayerActivated)
      self.onKeyposeLayerActivated(_activeLayerKey);
  }

  // Scroll the target row fully into view first (e.g. when re-targeting to a
  // layer whose row was scrolled off), so the popover doesn't anchor to a
  // clipped/off-screen pill.
  [self _ensureLaneRowVisible:laneIdx count:lanes.count];

  // Anchor: transient invisible subview the size of the clicked pill so the
  // popover arrow lands on the pill body.
  NSRect tracks = [self _tracksRect];
  NSRect row = [self _rowRectForIndex:laneIdx count:lanes.count];
  CGFloat x = [self _xForFrac:frac inLane:lane inTracks:tracks];
  CGFloat pillBot = NSMinY(row) + kPillInsetY;
  CGFloat pillTop = NSMaxY(row) - kPillInsetY;
  if (pillTop <= pillBot) {
    pillBot = NSMinY(row);
    pillTop = NSMaxY(row);
  }
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame =
      NSMakeRect(x - kPillW * 0.5, pillBot, kPillW, pillTop - pillBot);

  // Display lanes: every animatable lane in the same group that has a KP at
  // *exactly* this time goes into the active zone (editable + mini-viewer
  // handle visible). Same-group lanes without a co-time KP go into
  // excludedLabels - shown as the "available zone" row with an "Animate"
  // button.
  NSString *groupKey = lane.groupKey;
  NSString *layerKey = lane.layerKey;
  NSMutableArray<KKLane *> *displayLanes = [NSMutableArray array];
  NSMutableArray<NSString *> *excludedLabels = [NSMutableArray array];
  for (KKLane *l in lanes) {
    if (l.headerPlaceholder)
      continue; // layer header rows aren't editable params
    // Multi-owner timelines: scope the popover to the clicked lane's LAYER, so
    // a keypose popover shows only that layer's params (not every layer's).
    BOOL sameLayer =
        (l.layerKey == layerKey) || [l.layerKey isEqualToString:layerKey];
    if (!sameLayer)
      continue;
    BOOL sameGroup =
        (l.groupKey == groupKey) || [l.groupKey isEqualToString:groupKey];
    if (!sameGroup)
      continue;
    KKKeyPose *match = nil;
    for (KKKeyPose *k in l.keyposes)
      if (fabs(k.time - frac) < 1.0e-4) {
        match = k;
        break;
      }
    // A same-group lane with no co-time keypose still gets a (base) display
    // row so the static popover can swap it to an "Animate" row IN PLACE,
    // preserving property order - matching Basic. Without a base row,
    // applyExcludedLabels: no-ops (it only transforms an existing row), so
    // the property silently vanished from the popover.
    NSArray<NSNumber *> *vals = match ? match.values
                                      : (KKTimelineLaneValueAtFraction(l, frac)
                                             ?: l.keyposes.firstObject.values);
    if (!match)
      [excludedLabels addObject:l.label];
    KKLane *display = [KKLane laneWithLabel:l.label];
    display.valueType = l.valueType;
    display.componentMin = l.componentMin;
    display.componentMax = l.componentMax;
    display.componentUnits = l.componentUnits;
    display.componentLabels = l.componentLabels;
    display.componentLabelColors = l.componentLabelColors;
    // spatialCurvable is lane metadata, not per-project state, so source it
    // from the template - an older blob (saved before the flag existed) would
    // otherwise leave it off and hide the curve toggle.
    // Multi-owner lanes are layer-tagged ("Stroke Width\x1f<id>"); match the
    // template on the PLAIN label or the metadata lookup fails for every tagged
    // lane (integerValued / autoSizesComponentLabels / scaleWithMedia lost, so
    // the keypose popover diverged from constants).
    NSString *plain = KKPlainLaneLabel(l.label);
    KKLane *tmpl = nil;
    for (KKLane *t in _availableLanes)
      if ([t.label isEqualToString:plain]) {
        tmpl = t;
        break;
      }
    display.spatialCurvable = tmpl ? tmpl.spatialCurvable : l.spatialCurvable;
    // aspectLinkable is metadata (template); aspectLinked is user state (blob).
    display.aspectLinkable = tmpl ? tmpl.aspectLinkable : l.aspectLinkable;
    display.aspectLinked = l.aspectLinked;
    display.integerValued = tmpl ? tmpl.integerValued : l.integerValued;
    // Media-scaled (normalised 0..1 shown as pixels) is template metadata; the
    // row keys pixel display off it. Without it the keypose popover showed the
    // raw 0.5 instead of pixels (Constants copies it, so it worked there).
    display.componentsScaleWithMedia =
        tmpl ? tmpl.componentsScaleWithMedia : l.componentsScaleWithMedia;
    // OSC-edited-only (geometry lanes like Points) shows the "edit on canvas"
    // message instead of value fields. It's template metadata, but fall back to
    // the source lane (it's serialized too) so a keypose popover still matches
    // the constants row when the template isn't resolved.
    display.oscEditedOnly = tmpl ? tmpl.oscEditedOnly : l.oscEditedOnly;
    display.locked = l.locked; // locked layer -> read-only value row
    [display kkApplyPickerMetadataFrom:tmpl]; // category / animatable / seed
    // Display label lives on the TEMPLATE (a dynamic plugin's separate identity
    // vs label) - it isn't serialized on the timeline lane, so `l.displayLabel`
    // is nil here and would clobber the good value kkApplyPickerMetadataFrom
    // just copied from tmpl. Prefer the template; fall back to the source lane
    // only when no template resolved.
    display.displayLabel = tmpl.displayLabel ?: l.displayLabel;
    KKKeyPose *displayKp = [KKKeyPose keyposeAtTime:0.0
                                             values:vals ?: @[ @0.0 ]];
    // Carry the curve state so the row's toggle reflects this keypose.
    if (match) {
      displayKp.spatialSmooth = match.spatialSmooth;
      displayKp.inHandle = match.inHandle;
      displayKp.outHandle = match.outHandle;
    }
    display.keyposes = @[ displayKp ];
    [displayLanes addObject:display];
  }
  if (displayLanes.count == 0 && excludedLabels.count == 0)
    return;

  _currentPopoverFrac = frac;
  __weak typeof(self) weak = self;
  void (^onValue)(NSString *, NSArray<NSNumber *> *) =
      ^(NSString *lab, NSArray<NSNumber *> *values) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        [s _writeValueForLabel:lab atFrac:s->_currentPopoverFrac values:values];
      };
  void (^onAnimate)(NSString *) = ^(NSString *lab) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    double f = s->_currentPopoverFrac;
    [s _addKeyposeAtFrac:f forLabel:lab];
    // Re-drive the popover so the just-added lane flips from an Animate row to
    // an editable row in place (the present path detects it's open → rebuilds
    // rows, no reopen / canvas blink).
    [s requestValuePopoverAtFraction:f];
  };
  NSString *capGroup = groupKey;
  void (^onRemove)(NSString *) = ^(NSString *lab) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    double f = s->_currentPopoverFrac;
    [s _removeKeyposeAtFrac:f forLabel:lab];
    // Other same-group lanes still keyed here → refresh in place so the
    // removed row flips back to "No keypose here"; nothing left → close.
    if ([s _anySameGroupKeyposeAtFrac:f group:capGroup])
      [s requestValuePopoverAtFraction:f];
    else if (s.onRequestClosePopover)
      s.onRequestClosePopover();
  };
  void (^onDragBegin)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s.onDragBegin)
      s.onDragBegin();
  };
  void (^onDragEnd)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s.onDragEnd)
      s.onDragEnd();
  };
  self.onValuePopover(_popoverAnchor, displayLanes, frac, excludedLabels,
                      lane.categoryKey, onValue, onAnimate, onRemove,
                      onDragBegin, onDragEnd);
  _valuePopoverShowing = YES;
  [self setNeedsDisplay:YES];
}

// A candidate lane for the keypose popover: a real lane in the active layer
// (when one is set) - never a header placeholder or another layer's lane.
- (BOOL)_laneEligibleForValuePopover:(KKLane *)lane {
  if (lane.headerPlaceholder)
    return NO;
  if (_activeLayerKey.length)
    return [lane.layerKey isEqualToString:_activeLayerKey];
  return YES;
}

- (void)requestValuePopoverAtFraction:(double)fraction {
  [self requestValuePopoverAtFraction:fraction fireActivation:YES];
}

- (void)requestValuePopoverAtFraction:(double)fraction
                       fireActivation:(BOOL)fireActivation {
  NSArray<KKLane *> *lanes = [self _animatableLanes];
  NSInteger preferredLane = -1;
  if (_topLaneLabel) {
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
      if ([lanes[i].label isEqualToString:_topLaneLabel] &&
          [self _laneEligibleForValuePopover:lanes[i]]) {
        preferredLane = i;
        break;
      }
  }
  const double kEps = 1.0e-4;
  NSInteger foundLane = -1, foundKP = -1;
  if (preferredLane >= 0) {
    KKLane *l = lanes[preferredLane];
    for (NSInteger k = 0; k < (NSInteger)l.keyposes.count; k++) {
      if (fabs(l.keyposes[k].time - fraction) < kEps) {
        foundLane = preferredLane;
        foundKP = k;
        break;
      }
    }
  }
  if (foundLane < 0) {
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
      KKLane *l = lanes[i];
      if (![self _laneEligibleForValuePopover:l])
        continue;
      for (NSInteger k = 0; k < (NSInteger)l.keyposes.count; k++) {
        if (fabs(l.keyposes[k].time - fraction) < kEps) {
          foundLane = i;
          foundKP = k;
          break;
        }
      }
      if (foundLane >= 0)
        break;
    }
  }
  if (foundLane < 0) {
    // The active layer has no keypose at this time (e.g. it's constant, or a
    // new path was just drawn and stole the selection). Fall through to ANY
    // layer with a keypose here - mirrors Basic - so the popover, and the
    // selection it drives via onKeyposeLayerActivated, move to a real keypose
    // owner instead of leaving the popover (and the layer-list highlight)
    // stranded.
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
      KKLane *l = lanes[i];
      if (l.headerPlaceholder)
        continue;
      for (NSInteger k = 0; k < (NSInteger)l.keyposes.count; k++) {
        if (fabs(l.keyposes[k].time - fraction) < kEps) {
          foundLane = i;
          foundKP = k;
          break;
        }
      }
      if (foundLane >= 0)
        break;
    }
  }
  if (foundLane < 0 && !fireActivation) {
    // Programmatic re-drive (tab switch / timeline re-feed) from a boundary
    // fraction that's pinned to the clip edge: Basic projects its out-end /
    // in-start diamonds to 1.0 / 0.0 even when the real keypose sits short of
    // the edge, so an exact match finds nothing and the popover (and its
    // highlight) wouldn't follow the tab switch. Snap to the nearest eligible
    // keypose - mirroring Basic mapping any fraction to its nearest diamond.
    // Gated to the re-drive path (fireActivation == NO) so user graph clicks
    // still require a real hit.
    double bestDist = INFINITY;
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
      KKLane *l = lanes[i];
      if (![self _laneEligibleForValuePopover:l])
        continue;
      for (NSInteger k = 0; k < (NSInteger)l.keyposes.count; k++) {
        double dist = fabs(l.keyposes[k].time - fraction);
        if (dist < bestDist) {
          bestDist = dist;
          foundLane = i;
          foundKP = k;
        }
      }
    }
  }
  if (foundLane < 0)
    return;
  _topLaneLabel = [lanes[foundLane].label copy];
  _topKPIdx = foundKP;
  [self _openValuePopoverForLane:foundLane
                              kp:foundKP
                  fireActivation:fireActivation];
}

// Equal endpoints → modulation pills (Wiggle / Oscillate / Handheld) - curve
// type has no visible effect when values are equal. Different endpoints →
// curve pills, modulation isn't useful there. Mirrors Basic's
// `_openGapPopoverForSection:` vs `_openHoldPopover` routing.
- (void)_openGapPopoverForLabel:(NSString *)label kpIdx:(NSInteger)aIdx {
  KKLane *lane = nil;
  for (KKLane *l in _timeline.lanes)
    if ([l.label isEqualToString:label]) {
      lane = l;
      break;
    }
  if (!lane || aIdx < 0 || aIdx + 1 >= (NSInteger)lane.keyposes.count)
    return;
  KKKeyPose *a = lane.keyposes[aIdx];
  KKKeyPose *b = lane.keyposes[aIdx + 1];
  KKInterval *iv = a.outgoing ?: [[KKInterval alloc] init];

  // A Radial gradient hold has nothing to wiggle (angle is meaningless), so no
  // modulation popover opens for it. Bail BEFORE repositioning the shared
  // anchor (otherwise an already-open curve popover would slide onto this gap)
  // and close whatever is open. A Linear gradient DOES expose an Angle wiggle
  // below.
  if (lane.valueType == KKLaneValueTypeGradient &&
      KKAdvValuesEqual(a.values, b.values) &&
      (a.values.count < 1 || llround(a.values[0].doubleValue) != 1)) {
    if (self.onRequestClosePopover)
      self.onRequestClosePopover();
    return;
  }

  // Geometry lane (Points): a hold (identical shapes at both ends) has nothing
  // to ease or modulate, so close any open popover rather than show dead
  // controls. A transition (different shapes) falls through to the curve pills
  // below (endpointsEqual is forced NO for geometry).
  if (lane.oscEditedOnly && KKMorphSnapshotSignature(a.geometrySnapshot) ==
                                KKMorphSnapshotSignature(b.geometrySnapshot)) {
    if (self.onRequestClosePopover)
      self.onRequestClosePopover();
    return;
  }

  NSArray<KKLane *> *anim = [self _animatableLanes];
  NSInteger animIdx = -1;
  for (NSInteger i = 0; i < (NSInteger)anim.count; i++)
    if ([anim[i].label isEqualToString:label]) {
      animIdx = i;
      break;
    }
  if (animIdx < 0)
    return;
  NSRect tracks = [self _tracksRect];
  NSRect row = [self _rowRectForIndex:animIdx count:anim.count];
  CGFloat xA = [self _xForFrac:a.time inLane:anim[animIdx] inTracks:tracks];
  CGFloat xB = [self _xForFrac:b.time inLane:anim[animIdx] inTracks:tracks];
  // When zoomed + scrolled, the gap's mathematical midpoint may sit outside
  // the visible scroll region OR under the label gutter (left of tracks).
  // NSPopover refuses to anchor to an offscreen view, and anchoring under
  // the labels makes the arrow point at "Position"/"Rotation" instead of
  // the gap. Confine the anchor to the visible portion of the tracks rect
  // (tracks ∩ visibleRect) intersected with the gap's own span - the arrow
  // lands in the centre of what the user can actually see of the gap.
  NSRect vis = self.visibleRect;
  CGFloat leftBound = MAX(NSMinX(tracks), NSMinX(vis));
  CGFloat rightBound = MIN(NSMaxX(tracks), NSMaxX(vis));
  CGFloat visStart = MAX(xA, leftBound);
  CGFloat visEnd = MIN(xB, rightBound);
  if (visStart >= visEnd) {
    // Gap is entirely outside the visible tracks region. Park the anchor
    // on whichever tracks edge the gap is closest to so the popover at
    // least appears next to the row.
    visStart = visEnd = (xB < leftBound)
                            ? leftBound
                            : ((xA > rightBound) ? rightBound : leftBound);
  }
  CGFloat anchorX = (visStart + visEnd) * 0.5;
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame = NSMakeRect(anchorX - 1.0, NSMidY(row) - 1.0, 2.0, 2.0);

  __weak typeof(self) weak = self;
  void (^onDragBegin)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s.onDragBegin)
      s.onDragBegin();
  };
  void (^onDragEnd)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s.onDragEnd)
      s.onDragEnd();
  };

  // Geometry lanes (Points) carry no scalar of their own, so value-equality
  // always reads "equal" - but the shape DOES change between keyposes and the
  // morph eases via the curve (modulation is a no-op for geometry). Always
  // route them to the curve pills, never the modulation popover.
  BOOL endpointsEqual =
      lane.oscEditedOnly ? NO : KKAdvValuesEqual(a.values, b.values);
  if (endpointsEqual) {
    if (!self.onHoldModulationPopover)
      return;
    void (^onModulation)(KKIntervalModulation) = ^(KKIntervalModulation m) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulation = m;
                                  }];
    };
    void (^onIntensity)(double) = ^(double v) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulationIntensity = v;
                                  }];
    };
    void (^onFrequency)(double) = ^(double v) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulationFrequency = v;
                                  }];
    };
    void (^onSeed)(uint32_t) = ^(uint32_t s) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulationSeed = s;
                                  }];
    };
    NSArray<NSString *> *compLabels = KKLaneComponentLabels(lane);
    NSUInteger compCount = lane.keyposes.firstObject.values.count;
    // Solid colour and gradient stay one lane-level toggle (no per-channel
    // wiggle). A Linear gradient's single toggle reads "Angle" - that is the
    // only part the evaluator wiggles.
    BOOL multiComp = (lane.valueType != KKLaneValueTypeColor &&
                      lane.valueType != KKLaneValueTypeGradient &&
                      compLabels.count > 1 && compCount > 1);
    BOOL laneModActive = iv.modulation != KKIntervalModulationNone;
    // Advanced is per-lane: the curve-type pill already toggles THIS lane's
    // modulation, so a single-component lane needs no "Applies to" (disabling
    // it == picking None). A multi-component lane shows just its axes (X / Y)
    // as flat rows - no redundant master row - so they can be wiggled
    // independently.
    NSMutableArray<NSArray<NSString *> *> *partCompoundLabels =
        [NSMutableArray array];
    NSMutableArray<NSArray<NSNumber *> *> *partCompoundStates =
        [NSMutableArray array];
    if (multiComp) {
      NSIndexSet *mask = iv.modulationComponents;
      for (NSUInteger c = 0; c < compCount; c++) {
        NSString *cn =
            (c < compLabels.count)
                ? compLabels[c]
                : [NSString stringWithFormat:@"%lu", (unsigned long)c];
        BOOL on = laneModActive && (!mask || [mask containsIndex:c]);
        [partCompoundLabels addObject:@[ cn ]];
        [partCompoundStates addObject:@[ @(on) ]];
      }
    }
    void (^onParticipation)(NSInteger, BOOL) = ^(NSInteger idx, BOOL on) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    // Each row IS one axis (no master). When
                                    // the lane isn't modulating yet, checking
                                    // an axis arms just that one; unchecking
                                    // the last axis drops back to None.
                                    NSUInteger c = (NSUInteger)idx;
                                    NSUInteger n =
                                        lane.keyposes.firstObject.values.count;
                                    BOOL wasNone = iv2.modulation ==
                                                   KKIntervalModulationNone;
                                    NSMutableIndexSet *m;
                                    if (wasNone) {
                                      m = [NSMutableIndexSet indexSet];
                                    } else {
                                      m = iv2.modulationComponents
                                              ? [iv2.modulationComponents
                                                        mutableCopy]
                                              : ({
                                                  NSMutableIndexSet *all =
                                                      [NSMutableIndexSet
                                                          indexSet];
                                                  [all addIndexesInRange:
                                                           NSMakeRange(0, n)];
                                                  all;
                                                });
                                    }
                                    if (on)
                                      [m addIndex:c];
                                    else
                                      [m removeIndex:c];
                                    iv2.modulationComponents = m;
                                    if (m.count == 0)
                                      iv2.modulation = KKIntervalModulationNone;
                                    else if (wasNone)
                                      iv2.modulation =
                                          KKIntervalModulationWiggle;
                                  }];
    };
    BOOL showsModLinked = multiComp;
    void (^onLinked)(BOOL) = ^(BOOL on) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulationLinked = on;
                                  }];
    };
    NSString *capturedLabel = label;
    NSInteger capturedAIdx = aIdx;
    NSArray<NSArray<NSNumber *> *> * (^partRebuilder)(void) =
        ^NSArray<NSArray<NSNumber *> *> * {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return nil;
      KKLane *l2 = nil;
      for (KKLane *cand in strong->_timeline.lanes)
        if ([cand.label isEqualToString:capturedLabel] && cand.enabled) {
          l2 = cand;
          break;
        }
      if (!l2 || capturedAIdx < 0 ||
          capturedAIdx >= (NSInteger)l2.keyposes.count)
        return nil;
      KKInterval *iv2 = l2.keyposes[capturedAIdx].outgoing;
      BOOL active = iv2 && iv2.modulation != KKIntervalModulationNone;
      NSArray<NSString *> *cl2 = KKLaneComponentLabels(l2);
      NSUInteger cc2 = l2.keyposes.firstObject.values.count;
      // One single-segment compound per axis (matches the builder); empty for a
      // single-component lane (no "Applies to" section).
      NSMutableArray<NSArray<NSNumber *> *> *out = [NSMutableArray array];
      BOOL multi =
          (l2.valueType != KKLaneValueTypeColor &&
           l2.valueType != KKLaneValueTypeGradient && cl2.count > 1 && cc2 > 1);
      if (multi) {
        NSIndexSet *mask = iv2.modulationComponents;
        for (NSUInteger c = 0; c < cc2; c++) {
          BOOL on = active && (!mask || [mask containsIndex:c]);
          [out addObject:@[ @(on) ]];
        }
      }
      return out;
    };
    NSString *capLabelMut = label;
    NSInteger capIdxMut = aIdx;
    KKGapIntervalReader reader = ^KKInterval *(void) {
      __strong typeof(weak) s = weak;
      if (!s)
        return nil;
      for (KKLane *l in s->_timeline.lanes)
        if ([l.label isEqualToString:capLabelMut] && l.enabled &&
            capIdxMut >= 0 && capIdxMut < (NSInteger)l.keyposes.count)
          return l.keyposes[capIdxMut].outgoing;
      return nil;
    };
    KKGapIntervalMutator mutator =
        ^(void (^_Nonnull mutate)(KKInterval *_Nonnull)) {
          [weak _mutateIntervalInLaneLabel:capLabelMut
                                     kpIdx:capIdxMut
                                      with:mutate];
        };
    self.onHoldModulationPopover(
        _popoverAnchor, a.time, b.time, iv.modulation, iv.modulationIntensity,
        iv.modulationFrequency, iv.modulationSeed, iv.modulationLinked,
        showsModLinked, partCompoundLabels, partCompoundStates, partRebuilder,
        onModulation, onIntensity, onFrequency, onSeed, onLinked,
        onParticipation, onDragBegin, onDragEnd, label, iv, reader, mutator);
    // Set AFTER present: presenting closes any previously-open popover, whose
    // close notification clears these flags (mirrors _valuePopoverShowing).
    _gapPopoverShowing = YES;
    _activeGapLabel = [label copy];
    _activeGapAIdx = aIdx;
    [self setNeedsDisplay:YES];
    return;
  }
  // animateOut mirrors the pill glyphs when the interval descends so the
  // glyph reads the same way the lane graph does.
  if (!self.onGapPopover)
    return;
  double meanA = 0.0, meanB = 0.0;
  NSUInteger n = MIN(a.values.count, b.values.count);
  for (NSUInteger c = 0; c < n; c++) {
    meanA += KKAdvNormComponent(a.values[c].doubleValue, lane.componentMin,
                                lane.componentMax, c);
    meanB += KKAdvNormComponent(b.values[c].doubleValue, lane.componentMin,
                                lane.componentMax, c);
  }
  BOOL descending = (n > 0) && (meanB < meanA);
  void (^onCurve)(KKIntervalCurve) = ^(KKIntervalCurve c) {
    [weak _mutateIntervalInLaneLabel:label
                               kpIdx:aIdx
                                with:^(KKInterval *iv2) {
                                  iv2.curve = c;
                                }];
  };
  void (^onIntensity)(double) = ^(double v) {
    [weak _mutateIntervalInLaneLabel:label
                               kpIdx:aIdx
                                with:^(KKInterval *iv2) {
                                  iv2.intensity = v;
                                }];
  };
  void (^onFrequency)(double) = ^(double v) {
    [weak _mutateIntervalInLaneLabel:label
                               kpIdx:aIdx
                                with:^(KKInterval *iv2) {
                                  iv2.frequency = v;
                                }];
  };
  NSString *capturedLabel = label;
  NSInteger capturedIdx = aIdx;
  KKGapIntervalReader reader = ^KKInterval *(void) {
    __strong typeof(weak) s = weak;
    if (!s)
      return nil;
    for (KKLane *l in s->_timeline.lanes)
      if ([l.label isEqualToString:capturedLabel] && l.enabled &&
          capturedIdx >= 0 && capturedIdx < (NSInteger)l.keyposes.count)
        return l.keyposes[capturedIdx].outgoing;
    return nil;
  };
  KKGapIntervalMutator mutator =
      ^(void (^_Nonnull mutate)(KKInterval *_Nonnull)) {
        [weak _mutateIntervalInLaneLabel:capturedLabel
                                   kpIdx:capturedIdx
                                    with:mutate];
      };
  self.onGapPopover(_popoverAnchor, descending, a.time, b.time, iv.curve,
                    iv.intensity, iv.frequency, @[], @[], nil, onCurve,
                    onIntensity, onFrequency,
                    ^(NSInteger _, BOOL __){
                    },
                    onDragBegin, onDragEnd, label, iv, reader, mutator);
  // See the modulation branch: set AFTER present so the outgoing popover's
  // close notification doesn't clear the flag we just set.
  _gapPopoverShowing = YES;
  _activeGapLabel = [label copy];
  _activeGapAIdx = aIdx;
  [self setNeedsDisplay:YES];
}

// Ctrl+click on a gap → flip `endpointsLinked`. Linking ON collapses the
// second endpoint's values to match the first (matches Basic's
// _toggleHoldLink). Unlink leaves values alone but resets curve to Linear.
- (void)_toggleLinkForLabel:(NSString *)label kpIdx:(NSInteger)aIdx {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *src = lanes[i];
    if (aIdx < 0 || aIdx + 1 >= (NSInteger)src.keyposes.count)
      return;
    KKLane *nl = [src copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *a = kps[aIdx];
    KKKeyPose *b = kps[aIdx + 1];
    KKInterval *iv = [a.outgoing copy] ?: [[KKInterval alloc] init];
    BOOL newLinked = !iv.endpointsLinked;
    iv.endpointsLinked = newLinked;
    if (!newLinked)
      iv.curve = KKIntervalCurveLinear;
    // Copy-preserve A (keyposeAtTime:values: would drop its spatial state +
    // geometrySnapshot); only its outgoing interval changes.
    KKKeyPose *newA = [a copy];
    newA.outgoing = iv;
    kps[aIdx] = newA;
    if (newLinked) {
      // Linking collapses B onto A's value (a hold). For a geometry lane the
      // "value" IS the shape, so carry A's snapshot too - otherwise B keeps its
      // own shape (or falls back to base) and the link doesn't actually hold.
      KKKeyPose *newB = [b copy];
      newB.values = a.values;
      newB.geometrySnapshot = a.geometrySnapshot;
      kps[aIdx + 1] = newB;
    }
    nl.keyposes = kps;
    lanes[i] = nl;
    changed = YES;
    break;
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Bulk-edit fan-out: if the clicked gap is in the multi-select, apply the
// mutation to every selected gap; otherwise it's a single-target edit.
- (void)_mutateIntervalInLaneLabel:(NSString *)label
                             kpIdx:(NSInteger)aIdx
                              with:(void (^)(KKInterval *iv))mut {
  NSString *clickedKey = [self _gapKeyForLabel:label aIdx:aIdx];
  NSArray<NSString *> *targetKeys = [_selectedGaps containsObject:clickedKey]
                                        ? _selectedGaps.allObjects
                                        : @[ clickedKey ];

  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *byLabel =
      [NSMutableDictionary dictionary];
  for (NSString *key in targetKeys) {
    NSString *kLabel;
    NSInteger kIdx;
    if (![self _decodeSelectionKey:key label:&kLabel kpIdx:&kIdx])
      continue;
    NSMutableArray *arr = byLabel[kLabel];
    if (!arr) {
      arr = [NSMutableArray array];
      byLabel[kLabel] = arr;
    }
    [arr addObject:@(kIdx)];
  }
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    NSMutableArray<NSNumber *> *indices = byLabel[lanes[i].label];
    if (indices.count == 0)
      continue;
    KKLane *nl = [lanes[i] copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    BOOL laneChanged = NO;
    for (NSNumber *n in indices) {
      NSInteger idx = n.integerValue;
      if (idx < 0 || idx + 1 >= (NSInteger)kps.count)
        continue;
      KKKeyPose *src = kps[idx];
      // Copy-preserve: keyposeAtTime:values: would drop the keypose's spatial
      // state (spatialSmooth / in-out handles) AND its geometrySnapshot, so a
      // curve change would silently reset a Points keypose's shape to the base
      // (i.e. the last-edited keypose's). See
      // [[project_keypose_copy_preserve_spatial]].
      KKKeyPose *newKP = [src copy];
      KKInterval *iv = [src.outgoing copy] ?: [[KKInterval alloc] init];
      mut(iv);
      newKP.outgoing = iv;
      kps[idx] = newKP;
      laneChanged = YES;
    }
    if (laneChanged) {
      nl.keyposes = kps;
      lanes[i] = nl;
      changed = YES;
    }
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

@end
