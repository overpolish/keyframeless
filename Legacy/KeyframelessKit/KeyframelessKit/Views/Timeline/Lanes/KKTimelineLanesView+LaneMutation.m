/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCheckboxRowView.h"
#import "KKLocalized.h"
#import "KKSegmentEditView.h"
#import "KKTimelineAdvancedView.h"
#import "KKTimelineBasicView.h"
#import "KKTimelineLanesView.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

@implementation KKTimelineLanesView (LaneMutation)

- (NSArray<NSNumber *> *)_defaultValuesForLabel:(NSString *)label {
  KKLane *tmpl = [self _templateForLabel:label];
  if (!tmpl)
    return @[ @0.0 ];
  NSArray<NSNumber *> *tmplDefault = tmpl.keyposes.firstObject.values;
  if (tmplDefault.count)
    return tmplDefault;
  if (tmpl.valueType == KKLaneValueTypeCrop)
    return @[ @1.0, @1.0, @0.0, @0.0 ];
  double def =
      tmpl.componentMin.firstObject ? tmpl.componentMin[0].doubleValue : 0.0;
  return @[ @(def) ];
}

// Replace the lane for `label` with `lane` (always present after seeding),
// persist, and refresh. Single funnel for both animatable + value edits.
- (void)_replaceLane:(KKLane *)lane forLabel:(NSString *)label {
  KKTimeline *updated = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([lanes[i].key isEqualToString:label]) {
      lanes[i] = lane;
      break;
    }
  }
  updated.lanes = lanes;
  _timeline = updated;
  [self _refresh];
  if (self.onTimelineMutated)
    self.onTimelineMutated(updated);
}

// The settled (Hold) value of a lane, independent of which phases it has.
// Mirrors KKTimelineBasicView's _holdValuesForLane: without the shape struct.
- (NSArray<NSNumber *> *)_holdValuesOfLane:(KKLane *)lane
                                  forLabel:(NSString *)label {
  NSArray<KKKeyPose *> *k = lane.keyposes;
  if (k.count == 0)
    return [self _defaultValuesForLabel:label];
  if (k.count == 1)
    return k.firstObject.values;
  static const double kE = 1.0e-4;
  BOOL inEnabled = k.firstObject.time < kE;
  return k[inEnabled ? 1 : 0].values; // the hold-start keypose
}

// Dropdown only: flip a property between animatable and constant. Never
// changes the value - but it does (re)shape the keyposes: turning animatable
// seeds the always-present 2-keypose Hold pair (both = the current constant,
// so every phase starts at the constant, not a stray 0); turning it off
// collapses back to a single constant keypose at the Hold value.
- (void)_setLaneAnimatable:(BOOL)animatable forLabel:(NSString *)label {
  KKLane *lane = [[self _laneForLabel:label] copy];
  if (!lane || lane.enabled == animatable)
    return;
  lane.enabled = animatable;
  if (animatable) {
    // Keep in sync with KKTimelineBasicView's kDefaultInEnd/kDefaultOutStart.
    static const double kDefInEnd = 0.22, kDefOutStart = 0.78;

    // Inherit global In/Out state from existing animated lanes (OR - any
    // lane with In/Out means In/Out is globally on). Without this, a newly
    // animatable lane is always Hold-only even when other lanes have
    // active In/Out phases, which is jarring when the rest of the UI is
    // mid-transition.
    BOOL globalIn = NO, globalOut = NO;
    double tIn = kDefInEnd, tOut = kDefOutStart;
    BOOL tFound = NO;
    // Inherit interval params (curve, intensity, freq, modulation, link) from
    // the first animatable lane so a new lane joins the same In/Hold/Out
    // shape - particularly drift/link state.
    KKInterval *tmplIn = nil, *tmplHold = nil, *tmplOut = nil;
    // Align the new lane's end to whatever the existing animated lanes use, so
    // all lanes' end keyposes line up even if clip/frame duration wasn't known
    // yet when an earlier lane was seeded (which would leave it at 1.0 while a
    // later one lands at outEndFrac). NAN until an existing lane is found.
    double inheritedEndFrac = NAN;
    for (KKLane *l in _timeline.lanes) {
      if (!l.enabled || l.keyposes.count < 2)
        continue;
      NSArray<KKKeyPose *> *kk = l.keyposes;
      if (isnan(inheritedEndFrac))
        inheritedEndFrac = kk.lastObject.time;
      // New model: middle-KP time disambiguates In-only vs Out-only for
      // n==3 (under the old model the first KP's time did, but now both
      // start at t=0).
      NSInteger n = (NSInteger)kk.count;
      BOOL lInEn = NO, lOutEn = NO;
      if (n == 4) {
        lInEn = YES;
        lOutEn = YES;
      } else if (n == 3) {
        if (kk[1].time < 0.5)
          lInEn = YES;
        else
          lOutEn = YES;
      }
      if (lInEn)
        globalIn = YES;
      if (lOutEn)
        globalOut = YES;
      if (!tFound) {
        NSInteger holdStart = lInEn ? 1 : 0;
        NSInteger holdEnd = n - (lOutEn ? 2 : 1);
        if (holdEnd > holdStart) {
          // Inherit the Hold link state from the first existing animated lane -
          // pure-hold lanes included - so a new lane MATCHES the current
          // linked/unlinked choice (Basic: "auto-link iff the others are
          // linked"). Without this, a pure-hold source's link was ignored and
          // the new lane fell back to the fresh=linked default.
          tmplHold = [kk[holdStart].outgoing copy];
          // Boundary times + In/Out interval templates only when the source
          // actually has that phase (≥3 KPs) - pure hold-only lanes sit at
          // [0, outEnd] and would seed silly boundary defaults.
          if (lInEn) {
            tIn = kk[holdStart].time;
            tmplIn = [kk.firstObject.outgoing copy];
          }
          if (lOutEn) {
            tOut = kk[holdEnd].time;
            tmplOut = [kk[holdEnd].outgoing copy];
          }
          tFound = YES;
        }
      }
    }

    // Out-end / hold-end position - one frame before clipEnd so FCP playhead
    // can reach it. Read frame/clip dur off the basic graph.
    double outEndFrac = 1.0;
    double clipDur = _basicGraph.clipDurationSeconds;
    double frameDur = _basicGraph.frameDurationSeconds;
    if (clipDur > 0.0 && frameDur > 0.0 && frameDur < clipDur)
      outEndFrac = (clipDur - frameDur) / clipDur;
    // Prefer the existing lanes' end so a new lane lines up with them exactly,
    // regardless of whether duration was available when each was seeded.
    if (!isnan(inheritedEndFrac) && inheritedEndFrac > 0.5)
      outEndFrac = inheritedEndFrac;

    NSArray<NSNumber *> *v = [self _holdValuesOfLane:lane forLabel:label];
    // Every rebuilt keypose derives from the constant lane's EXISTING keypose
    // (the keyposeBySetting* full-copy builders), so spatial-curve state and a
    // geometry snapshot survive the constant -> animatable flip - the
    // Lanes-view sibling of Basic's KKBasicCopySpatial carry. Intervals are
    // still assigned explicitly per keypose, matching the old constructor's
    // fresh-interval default.
    KKKeyPose *src = lane.keyposes.firstObject;
    KKKeyPose * (^seedAt)(double) = ^KKKeyPose *(double t) {
      if (!src)
        return [KKKeyPose keyposeAtTime:t values:v];
      KKKeyPose *kp = [[src keyposeBySettingValues:v] keyposeBySettingTime:t];
      kp.outgoing = [[KKInterval alloc] init];
      return kp;
    };
    NSMutableArray<KKKeyPose *> *kps = [NSMutableArray array];
    if (globalIn) {
      KKKeyPose *a = seedAt(0.0);
      a.outgoing = tmplIn ?: [[KKInterval alloc] init];
      [kps addObject:a];
    }
    // Hold-start: at 0 when In off, at tIn when In on. A freshly animatable
    // property's Hold pair starts linked (the two interior keyposes move
    // together) - "fresh = linked, then it's on the user". A second lane
    // joining an existing shape inherits that shape's link state via tmplHold.
    KKKeyPose *hs = seedAt(globalIn ? tIn : 0.0);
    if (tmplHold) {
      hs.outgoing = tmplHold;
    } else {
      KKInterval *freshHold = [[KKInterval alloc] init];
      freshHold.endpointsLinked = YES;
      hs.outgoing = freshHold;
    }
    [kps addObject:hs];
    // Hold-end: at outEndFrac when Out off, at tOut when Out on.
    KKKeyPose *he = seedAt(globalOut ? tOut : outEndFrac);
    [kps addObject:he];
    if (globalOut) {
      he.outgoing = tmplOut ?: [[KKInterval alloc] init];
      [kps addObject:seedAt(outEndFrac)];
    }
    lane.keyposes = kps;
  } else {
    NSArray<NSNumber *> *v = [self _holdValuesOfLane:lane forLabel:label];
    KKKeyPose *src = lane.keyposes.firstObject;
    lane.keyposes =
        @[ src ? [[src keyposeBySettingValues:v] keyposeBySettingTime:0.0]
               : [KKKeyPose keyposeAtTime:0.0 values:v] ];
  }
  [self _replaceLane:lane forLabel:label];
}

// Value editor (mini viewer / fields): set the property's constant value
// without changing its animatable status.
- (void)_setLaneValues:(NSArray<NSNumber *> *)values
              forLabel:(NSString *)label {
  KKLane *existing = [self _laneForLabel:label];
  if (!existing)
    return;
  // Copy the existing lane so every property survives a constant value edit -
  // aspectLinked in particular. Rebuilding a fresh lane (carrying only a subset
  // of fields) dropped aspectLinked, so editing the Scale constant cleared the
  // aspect lock. The keypose likewise derives from the existing one
  // (keyposeBySettingValues carries spatial state + geometry snapshot), not a
  // from-scratch rebuild.
  KKLane *lane = [existing copy];
  KKKeyPose *src = lane.keyposes.firstObject;
  lane.keyposes = @[ src ? [src keyposeBySettingValues:values]
                         : [KKKeyPose keyposeAtTime:0.0 values:values] ];
  [self _replaceLane:lane forLabel:label];
}

// Commit a code-lane edit: replace the lane's `codeString` (its value is text,
// not keyposes) and route through the same lane-replace / timeline-commit path.
- (void)_setLaneCode:(NSString *)code forLabel:(NSString *)label {
  KKLane *existing = [self _laneForLabel:label];
  if (!existing)
    return;
  KKLane *lane = [existing copy];
  lane.codeString = code;
  // _replaceLane already persists (onTimelineMutated) + refreshes +
  // render-nudges the edit. Do NOT persist a second time here: a duplicate
  // onTimelineMutated makes the same code edit TWO FCP undo entries (undo needs
  // two Cmd-Z).
  [self _replaceLane:lane forLabel:label];
  // Notify the host that the code changed (debounced upstream), so a host with
  // source-derived lanes (e.g. a shader `// #color` directive) can re-derive
  // and refresh the lane set live.
  if (self.onCodeCommitted)
    self.onCodeCommitted(code);
}

// Commit a tabbed code-lane edit: section 0 -> codeString (the Image pass), the
// rest -> codeTabs (Common / Buffer A). Same lane-replace / commit path.
- (void)_setLaneCodeSections:
            (NSArray<NSDictionary<NSString *, NSString *> *> *)sections
                    forLabel:(NSString *)label {
  KKLane *existing = [self _laneForLabel:label];
  if (!existing || sections.count == 0)
    return;
  KKLane *lane = [existing copy];
  lane.codeString = sections[0][@"code"] ?: @"";
  lane.codeTabs =
      sections.count > 1
          ? [sections subarrayWithRange:NSMakeRange(1, sections.count - 1)]
          : nil;
  // _replaceLane already persists (onTimelineMutated) + refreshes +
  // render-nudges; persisting again below made a code edit TWO undo entries
  // (see _setLaneCode:).
  [self _replaceLane:lane forLabel:label];
  if (self.onCodeCommitted)
    self.onCodeCommitted(lane.codeString);
}

// Commit the save bar's name. Lane-level text like the code itself, so it goes
// through the same lane-replace path - which means it persists, undoes, and
// travels with a copied clip exactly like the source does. No
// `onCodeCommitted`: the SOURCE didn't change, and firing it would also notify
// source-only consumers. Hosts whose derived lane metadata includes this name
// observe the resulting timeline mutation separately.
- (void)_setLaneCodeSaveName:(NSString *)name forLabel:(NSString *)label {
  KKLane *existing = [self _laneForLabel:label];
  if (!existing)
    return;
  NSString *n = name.length ? name : nil;
  if ([(existing.codeSaveName ?: @"") isEqualToString:(n ?: @"")])
    return; // a blur with no change must not cost an undo entry
  KKLane *lane = [existing copy];
  lane.codeSaveName = n;
  [self _replaceLane:lane forLabel:label];
}

- (void)_setLaneAspectLinked:(BOOL)on forLabel:(NSString *)label {
  // The CONSTANTS popover edits the lanes view's own _timeline, not a graph, so
  // its aspect-link toggle persists here (the keypose popover routes to the
  // active graph instead). Reuse the same helper the graphs use so the
  // behaviour matches, then persist through onTimelineMutated like a value edit
  // - without this the toggle only updated the row, so the next constant
  // scrub's _refresh re-read the stale (template-default linked) lane and
  // relocked it.
  KKTimeline *t = KKTimelineSettingAspectLinked(_timeline, label, on);
  if (!t)
    return;
  _timeline = t;
  [self _refresh];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Parameter linking: the lane's transform expression is a lane-level (non-
// fractional) property, so it persists against the lanes view's own _timeline
// the same way the aspect lock does.
- (void)_setLaneLinkExpression:(NSString *)expr forLabel:(NSString *)label {
  KKTimeline *t = KKTimelineSettingLinkExpression(_timeline, label, expr);
  if (!t)
    return;
  _timeline = t;
  [self _refresh];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

@end
