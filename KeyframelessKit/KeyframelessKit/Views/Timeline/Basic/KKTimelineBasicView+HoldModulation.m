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

@implementation KKTimelineBasicView (HoldModulation)

// Hold-modulation param edits apply only to lanes the modulation is ON for
// (Hold interval modulation != None) so tweaking a param never silently
// re-enables an excluded lane. If none participate yet, target all
// animatable lanes - picking a type from the None state turns it on for all
// (the user then unticks individual properties).
- (void)_mutateHoldModWith:(void (^)(KKInterval *iv))mut {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL anyParticipating = NO;
  for (KKLane *lane in lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKInterval *iv = lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
    if (iv && iv.modulation != KKIntervalModulationNone) {
      anyParticipating = YES;
      break;
    }
  }
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    // Only a Linear gradient is modulatable (its Angle); a Radial gradient is
    // never a target (see +Popovers). Non-gradient lanes are unaffected.
    if (lane.valueType == KKLaneValueTypeGradient &&
        (lane.keyposes.firstObject.values.count < 1 ||
         llround(lane.keyposes.firstObject.values[0].doubleValue) != 1))
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    KKInterval *cur = lane.keyposes[s.holdStart].outgoing;
    if (anyParticipating &&
        (!cur || cur.modulation == KKIntervalModulationNone))
      continue; // excluded - leave it None
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *kp = [kps[s.holdStart] copy];
    KKInterval *iv = [kp.outgoing copy] ?: [[KKInterval alloc] init];
    mut(iv);
    kp.outgoing = iv;
    kps[s.holdStart] = kp;
    nl.keyposes = kps;
    lanes[i] = nl;
  }
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Toggle whether the Hold modulation applies to one lane. On → copy the
// shared type/params onto its Hold interval (defaulting to Wiggle if no
// type chosen yet); off → modulation None (curve/intensity kept for drift).
- (void)_setHoldModApplied:(BOOL)on forLabel:(NSString *)label {
  KKBasicProj p = [self _projection];
  KKIntervalModulation type = (p.holdMod != KKIntervalModulationNone)
                                  ? p.holdMod
                                  : KKIntervalModulationWiggle;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || ![lane.label isEqualToString:label] ||
        lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *kp = [kps[s.holdStart] copy];
    KKInterval *iv = [kp.outgoing copy] ?: [[KKInterval alloc] init];
    if (on) {
      iv.modulation = type;
      iv.modulationIntensity = p.holdModIntensity;
      iv.modulationFrequency = p.holdModFrequency;
      iv.modulationSeed = p.holdModSeed;
    } else {
      iv.modulation = KKIntervalModulationNone;
    }
    kp.outgoing = iv;
    kps[s.holdStart] = kp;
    nl.keyposes = kps;
    lanes[i] = nl;
    break;
  }
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Per-component modulation participation for a multi-component lane. Adds
// or removes `componentIdx` in the lane's Hold-interval modulationComponents
// mask. When the mask empties out the lane's modulation flips to None (the
// pill row reads the lane as excluded); turning a component on while the
// lane is excluded re-arms the modulation with the current shared type +
// intensity/freq/seed taken from the projection so it lights up immediately.
- (void)_setHoldModComponent:(NSUInteger)componentIdx
                          on:(BOOL)on
                    forLabel:(NSString *)label {
  KKBasicProj p = [self _projection];
  KKIntervalModulation type = (p.holdMod != KKIntervalModulationNone)
                                  ? p.holdMod
                                  : KKIntervalModulationWiggle;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || ![lane.label isEqualToString:label] ||
        lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *kp = [kps[s.holdStart] copy];
    KKInterval *iv = [kp.outgoing copy] ?: [[KKInterval alloc] init];
    NSUInteger compCount = lane.keyposes.firstObject.values.count;
    // Seed the mask from current state: nil ⇒ all components active.
    NSMutableIndexSet *mask =
        iv.modulationComponents ? [iv.modulationComponents mutableCopy] : ({
          NSMutableIndexSet *all = [NSMutableIndexSet indexSet];
          [all addIndexesInRange:NSMakeRange(0, compCount)];
          all;
        });
    if (on)
      [mask addIndex:componentIdx];
    else
      [mask removeIndex:componentIdx];
    iv.modulationComponents = mask;
    if (mask.count == 0) {
      iv.modulation = KKIntervalModulationNone;
    } else if (iv.modulation == KKIntervalModulationNone) {
      iv.modulation = type;
      iv.modulationIntensity = p.holdModIntensity;
      iv.modulationFrequency = p.holdModFrequency;
      iv.modulationSeed = p.holdModSeed;
    }
    kp.outgoing = iv;
    kps[s.holdStart] = kp;
    nl.keyposes = kps;
    lanes[i] = nl;
    break;
  }
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Toggle whether one lane participates in the Hold drift. On → unlink its
// Hold interval (drift-capable, starts linear; the user then edits its
// hold-end value); off → relink and collapse hold-end back to hold-start so
// it's a flat hold again.
- (void)_setHoldDriftApplied:(BOOL)on forLabel:(NSString *)label {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || ![lane.label isEqualToString:label] ||
        lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (s.holdEnd <= s.holdStart)
      continue;
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *b = [kps[s.holdStart] copy];
    KKKeyPose *c = [kps[s.holdEnd] copy];
    KKInterval *iv = [b.outgoing copy] ?: [[KKInterval alloc] init];
    iv.endpointsLinked = !on;
    if (on)
      iv.curve = KKIntervalCurveLinear; // a fresh drift starts linear
    b.outgoing = iv;
    if (!on) { // relink → flatten: hold-end mirrors hold-start
      c.values = b.values;
      c.geometrySnapshot = b.geometrySnapshot; // geometry lane: hold the shape too
    }
    c.outgoing = kps[s.holdEnd].outgoing;
    kps[s.holdStart] = b;
    kps[s.holdEnd] = c;
    nl.keyposes = kps;
    lanes[i] = nl;
    break;
  }
  t.lanes = lanes;
  _timeline = t;
  self.needsLayout = YES;
  [self layoutSubtreeIfNeeded];
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

@end
