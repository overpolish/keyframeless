/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Scope-gating analyzers for the Layers panel, split from
// CanvasLayerListController.m: given a popover kind (+ time), they derive which
// layers can't be acted on in it - no keypose at the time, fully animated, no
// constant lane, or a move lane already animated - and push that set onto the
// list view and the mini-viewer.

#import "CanvasLayerListController_Private.h"

#import "CanvasLayerListView.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation CanvasLayerListController (NonSelectable)

// The non-selectable layer set for a popover `kind` at `frac` (keypose: no
// keypose there; constants: move-lane animated; appliesTo: not animated).
- (nullable NSSet<NSString *> *)_nonSelectableForKind:(NSString *)kind
                                             fraction:(double)frac {
  if ([kind isEqualToString:@"keypose"])
    return [self _layersWithoutKeyposeAtFraction:frac];
  if ([kind isEqualToString:@"constants"])
    return [self _layersWithoutConstant];
  if ([kind isEqualToString:@"appliesTo"])
    return [self _layersWithoutAnimation];
  return nil;
}

// Re-derive + push the open popover's non-selectable set against the CURRENT
// layer stack. Called on reload so a layer added/removed while a popover is open
// (e.g. a path drawn during a keypose popover) is greyed immediately, without a
// reopen. No-op when no popover is open.
- (void)_refreshNonSelectableForOpenPopover {
  if (!_openPopoverKind.length)
    return;
  NSSet<NSString *> *ns = [self _nonSelectableForKind:_openPopoverKind
                                             fraction:_openPopoverFraction];
  if (self.onNonSelectableLayersChanged)
    self.onNonSelectableLayersChanged(ns);
  NSSet<NSString *> *mq =
      [_openPopoverKind isEqualToString:@"constants"]
          ? [self _layersWithMoveLaneAnimated]
          : ns;
  if (self.onMarqueeNonSelectableLayersChanged)
    self.onMarqueeNonSelectableLayersChanged(mq);
  [_listView setNonSelectableLayerIDs:ns];
}

// Layers (by layerID) that have NO keypose at clip fraction `frac` in any of
// their animated lanes - they can't be the edit target of a keypose popover.
- (NSSet<NSString *> *)_layersWithoutKeyposeAtFraction:(double)frac {
  NSArray<KKBezierPath *> *paths = [self currentLayerPaths];
  // The Basic out-end boundary is EDGE-PARKED: its pill (and the popover's
  // reported fraction) sits at 1.0, but the keypose itself lands at
  // lastFrameFrac (<1.0). An exact match against 1.0 finds no keypose on ANY
  // layer, so the whole list dims (yet the layer is fully editable - navigating
  // to the same keypose shows it un-dimmed). Basic keypose times are shared
  // across layers, so snap `frac` to the nearest actual keypose time first,
  // then match against that. A genuinely-constant layer (no keyposes near the
  // snapped time) still dims correctly.
  double snapped = frac, bestD = INFINITY;
  for (KKBezierPath *p in paths) {
    if (!p.animationJSON.length)
      continue;
    KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
    for (KKLane *l in tl.lanes) {
      if (!l.enabled)
        continue;
      for (KKKeyPose *kp in l.keyposes) {
        double d = fabs(kp.time - frac);
        if (d < bestD) {
          bestD = d;
          snapped = kp.time;
        }
      }
    }
  }

  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKBezierPath *p in paths) {
    if (!p.layerID.length)
      continue;
    BOOL has = NO;
    if (p.animationJSON.length) {
      KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
      for (KKLane *l in tl.lanes) {
        if (!l.enabled)
          continue;
        for (KKKeyPose *kp in l.keyposes)
          if (fabs(kp.time - snapped) < 1.0e-4) {
            has = YES;
            break;
          }
        if (has)
          break;
      }
    }
    if (!has)
      [out addObject:p.layerID];
  }
  return out;
}

// Layers (by layerID) that are fully animated (no constant param) - they can't
// be the edit target of a Constants popover.
// Layers (by layerID) with NO animated lanes - nothing for a curve / modulation
// ("Applies to") popover to act on, so they can't be the target.
- (NSSet<NSString *> *)_layersWithoutAnimation {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKBezierPath *p in [self currentLayerPaths]) {
    if (!p.layerID.length)
      continue;
    if (p.animationJSON.length == 0) {
      [out addObject:p.layerID]; // no animation blob at all
      continue;
    }
    KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
    BOOL anyAnimated = NO;
    for (KKLane *l in tl.lanes)
      if (l.enabled) {
        anyAnimated = YES;
        break;
      }
    if (!anyAnimated)
      [out addObject:p.layerID];
  }
  return out;
}

// SINGLE-click / layer-list gating for the Constants popover: a layer is
// non-selectable only when FULLY animated (no constant lane to edit at all). A
// layer with any constant lane stays clickable - you can edit that constant.
- (NSSet<NSString *> *)_layersWithoutConstant {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKBezierPath *p in [self currentLayerPaths]) {
    if (!p.layerID.length || p.animationJSON.length == 0)
      continue; // no animationJSON => all constant => selectable
    KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
    NSUInteger animated = 0;
    for (KKLane *l in tl.lanes)
      if (l.enabled)
        animated++;
    if (animated >= _templateLaneCount)
      [out addObject:p.layerID]; // fully animated: no constants to edit
  }
  return out;
}

// STRICTER gating used only for the MARQUEE / body-drag in the Constants popover:
// a layer is non-selectable when its MOVE lane is animated - Points for a vector
// path, Position for an image / group. That lane is the ground truth for where
// the layer sits, so when it's animated the layer can't be positioned via
// constants (and a marquee selects to MOVE). Single-click stays lenient above.
- (NSSet<NSString *> *)_layersWithMoveLaneAnimated {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKBezierPath *p in [self currentLayerPaths]) {
    if (!p.layerID.length || p.animationJSON.length == 0)
      continue;
    NSString *moveLane = (p.isImage || p.isGroup) ? @"Position" : @"Points";
    KKTimeline *tl = [KKTimeline timelineFromJSON:p.animationJSON];
    for (KKLane *l in tl.lanes)
      if ([l.label isEqualToString:moveLane]) {
        if (l.enabled && l.keyposes.count >= 2)
          [out addObject:p.layerID];
        break;
      }
  }
  return out;
}

@end
