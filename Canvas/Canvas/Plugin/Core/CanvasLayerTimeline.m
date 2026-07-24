/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerTimeline.h"
#import "CanvasLayerRender.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKLinkBus.h> // KKLinkResolvedLaneValue
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKTimingEvaluation.h> // KKLaneDisplayValueAtFraction

// Process-wide layer-blob snapshot for the viewer OSC (see header).
static NSString *sCanvasLayerBlobSnapshot = nil;

void CanvasSetLayerBlobSnapshot(NSString *b64) {
  sCanvasLayerBlobSnapshot = [b64 copy];
}

NSString *CanvasLayerBlobSnapshot(void) { return sCanvasLayerBlobSnapshot; }

// Process-wide kParamUIState snapshot for the viewer OSC (see header).
static NSString *sCanvasUIStateSnapshot = nil;

void CanvasSetUIStateSnapshot(NSString *json) {
  sCanvasUIStateSnapshot = [json copy];
}

NSString *CanvasUIStateSnapshot(void) { return sCanvasUIStateSnapshot; }

// Process-wide real output-size snapshot for path ops (see header).
static float sCanvasOutputWidth = 0.0f;
static float sCanvasOutputHeight = 0.0f;

void CanvasSetOutputSize(float width, float height) {
  if (width > 0.0f && height > 0.0f) {
    sCanvasOutputWidth = width;
    sCanvasOutputHeight = height;
  }
}

BOOL CanvasOutputSize(float *outWidth, float *outHeight) {
  if (sCanvasOutputWidth <= 0.0f || sCanvasOutputHeight <= 0.0f)
    return NO;
  *outWidth = sCanvasOutputWidth;
  *outHeight = sCanvasOutputHeight;
  return YES;
}

KKBezierPath *CanvasSelectedLayerForPaths(NSArray<KKBezierPath *> *paths,
                                          NSString *selectedLayerID) {
  // Groups animate too (their own explicit transform; no propagation), so they
  // are selectable layers like any other - no isGroup skip.
  KKBezierPath *first = nil;
  for (KKBezierPath *p in paths) {
    if (!first)
      first = p;
    if (selectedLayerID.length && [p.layerID isEqualToString:selectedLayerID])
      return p;
  }
  return first;
}

BOOL CanvasLaneAppliesToPath(KKLane *templateLane, KKBezierPath *path) {
  NSUInteger m = templateLane.templateScopeMask;
  if ((m & CanvasLaneScopeVectorOnly) && (path.isImage || path.isGroup))
    return NO;
  if ((m & CanvasLaneScopeNotGroup) && path.isGroup)
    return NO;
  if ((m & CanvasLaneScopeImageOnly) && !path.isImage)
    return NO;
  // Line caps / end markers draw only on an OPEN end: a closed single contour
  // or any multi-contour path is treated as closed by the renderer.
  if ((m & CanvasLaneScopeOpenEndOnly) &&
      !(path.contourCount <= 1 && !path.closed))
    return NO;
  return YES;
}

KKTimeline *CanvasLayerTimelineForPath(KKBezierPath *path,
                                       NSArray<KKLane *> *templates) {
  KKTimeline *tl = [KKTimeline timeline];
  if (!path) {
    // No layer at all (empty stack): still surface the transform lanes, but
    // LOCKED so the constants popover + graphs render read-only. Editing a
    // value here has nowhere to persist (no owning layer), so it must not look
    // adjustable. The kit's seed preserves `locked` on a present lane, and the
    // templates already carry their identity keypose for the readout.
    NSMutableArray<KKLane *> *lanes =
        [NSMutableArray arrayWithCapacity:templates.count];
    NSMutableArray<NSString *> *order =
        [NSMutableArray arrayWithCapacity:templates.count];
    for (KKLane *t in templates) {
      if (t.oscEditedOnly)
        continue; // no layer = no path geometry (Points)
      KKLane *src = [t copy];
      src.locked = YES;
      [lanes addObject:src];
      if (t.key)
        [order addObject:t.key];
    }
    tl.lanes = lanes;
    tl.paramOrder = order;
    return tl;
  }

  // The layer's own stored lanes, keyed by lane key (preserve enabled +
  // keyposes).
  NSMutableDictionary<NSString *, KKLane *> *stored =
      [NSMutableDictionary dictionary];
  if (path.animationJSON.length) {
    KKTimeline *s = [KKTimeline timelineFromJSON:path.animationJSON];
    for (KKLane *l in s.lanes)
      if (l.key)
        stored[l.key] = l;
  }

  // Build in TEMPLATE order (= the parameter order) so every layer's lanes are
  // ordered identically (Scale, Position, ...), regardless of the order they
  // happened to be stored in. A param with no stored lane uses the template
  // (constant default); a stored one keeps its animated state + keyposes.
  NSString *lid = path.layerID.length ? path.layerID : nil;
  NSString *name = path.name.length ? path.name : @"Layer";
  NSMutableArray<KKLane *> *lanes =
      [NSMutableArray arrayWithCapacity:templates.count];
  NSMutableArray<NSString *> *order =
      [NSMutableArray arrayWithCapacity:templates.count];
  for (KKLane *t in templates) {
    // Applicability is declared ON the template (templateScopeMask, set beside
    // the definition in Plugin+LaneDefinitions.m) - one gate instead of the
    // old per-label cascade.
    if (!CanvasLaneAppliesToPath(t, path))
      continue;
    KKLane *src = [(stored[t.key] ?: t) copy];
    // Re-assert the template's canonical DISPLAY / picker metadata onto a
    // stored (round-tripped) lane - the animationJSON drops non-codable props,
    // notably componentLabelColors (the R/G/B/A graph-line tints), so an
    // animated colour lane drew every channel in the default accent instead of
    // red/green/blue. Mirrors the kit seeder (_timelineSeededFrom); user state
    // (keyposes, enabled, aspectLinked) is untouched.
    [src kkApplyTemplateCanonicalFrom:t];
    // A non-animatable param (a structural enum / toggle like the colour "Mode"
    // or the stroke "Enabled") is ALWAYS constant - it can't be animated, so it
    // must never read as enabled, whatever a stale animationJSON says. Without
    // this an old blob (or a controller carried back by the merged-timeline
    // split) could leave Mode enabled and wrongly show it as an animated row.
    if (!t.animatable)
      src.enabled = NO;
    // No stored lane yet: seed the constant keypose from the layer's flat
    // value via the template's declarative seed (templateSeedProvider, also
    // defined beside the lane). nil provider / nil result = keep the
    // template's default keypose.
    if (!stored[t.key] && t.templateSeedProvider) {
      NSArray<NSNumber *> *seed = t.templateSeedProvider(path);
      if (seed)
        src.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:seed] ];
    }
    // Tag with the layer for the Advanced view's layer header. The LABEL stays
    // plain ("Scale") so the kit's label-keyed edit surfaces are unaffected;
    // only layerKey/layerLabel drive the header. Group layers get a folder
    // glyph (others keep the header's default stacked-squares).
    src.layerKey = lid;
    src.layerLabel = name;
    src.layerSymbol = path.isGroup ? @"folder" : nil;
    src.locked = path.locked; // read-only lanes when the layer is locked
    [lanes addObject:src];
    if (t.key)
      [order addObject:t.key];
  }
  // Stroke group gating is NOT done here: the "Enabled" toggle drives the
  // shared visibleWhen cascade (set on the template lanes), so a disabled
  // stroke drops its lanes out of every timeline surface uniformly - no
  // per-build lock.
  tl.lanes = lanes;
  tl.paramOrder = order;
  return tl;
}

void CanvasSeedGroupAnchor(KKBezierPath *group, NSArray<KKBezierPath *> *paths,
                           NSArray<KKLane *> *templates) {
  if (!group.isGroup)
    return;
  float cx = 0.5f, cy = 0.5f;
  if (!CanvasGroupContentCenterObj(paths, group, &cx, &cy))
    return; // no measurable content: leave the anchor at the clip centre
  // Seed the group onto its content centre (Y-down cy -> 1-cy):
  //  - FROZEN rest (group.translateX/Y, repurposed): the reference the group's
  //    Position is measured from. The render translation is Position - rest, so
  //    seeding Position to the content centre leaves members in place.
  //  - Position lane: the content centre, so the Position handle sits ON the
  //    group, not alone at the clip centre.
  //  - Anchor lane: the content centre too, so the rotation / scale pivot lands
  //    on the content. The Anchor is a free pan-behind pivot afterwards (it
  //    never feeds rest), so dragging it never moves the rendered content.
  group.translateX = cx;
  group.translateY = (float)(1.0 - cy);
  KKTimeline *tl = CanvasLayerTimelineForPath(group, templates);
  for (KKLane *l in tl.lanes) {
    if (![l.key isEqualToString:@"Anchor"] &&
        ![l.key isEqualToString:@"Position"])
      continue;
    l.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                      values:@[ @(cx), @(1.0 - cy) ]] ];
  }
  CanvasApplyTimelineToPath(tl, group);
}

void CanvasApplyTimelineToPath(KKTimeline *timeline, KKBezierPath *path) {
  if (!path)
    return;
  // No lock guard here: lock is enforced at the UI (Advanced graph blocks
  // locked lanes; Advanced keypose + Constants popovers render read-only).
  // Basic deliberately ignores lock (shared timings), and Basic edits flow
  // through here - guarding would wrongly revert them.
  path.animationJSON = timeline ? [KKTimeline jsonFromTimeline:timeline] : nil;
}

BOOL CanvasLayerHasConstant(KKBezierPath *path, NSArray<KKLane *> *templates) {
  if (!path)
    return NO;
  if (path.animationJSON.length == 0)
    return YES; // nothing animated => every param is constant
  KKTimeline *s = [KKTimeline timelineFromJSON:path.animationJSON];
  NSUInteger animated = 0;
  for (KKLane *l in s.lanes)
    if (l.enabled)
      animated++;
  return animated < templates.count; // some template isn't animated here
}

BOOL CanvasAnyLayerHasConstant(NSArray<KKBezierPath *> *paths,
                               NSArray<KKLane *> *templates) {
  for (KKBezierPath *p in paths)
    if (CanvasLayerHasConstant(p, templates))
      return YES;
  return NO;
}

// Thread-local so concurrent FxPlug render threads each carry their own scope
// and non-render processes read "inactive". Plain C thread-local (no ObjC
// object storage) - the scope holds only the clip's absolute span.
static _Thread_local struct {
  BOOL active;
  double startTLSec;
  double durSec;
} gCanvasLinkScope;

// The scope's live override, as a manually-bridged CF ref: ARC forbids ObjC
// ownership in _Thread_local storage, so push retains and pop releases.
static _Thread_local void *gCanvasLinkOverrideRef;

void CanvasLinkScopePushWithOverride(double clipStartTLSec, double clipDurSec,
                                     CanvasLinkLaneOverride live) {
  gCanvasLinkScope.active = YES;
  gCanvasLinkScope.startTLSec = clipStartTLSec;
  gCanvasLinkScope.durSec = clipDurSec;
  if (gCanvasLinkOverrideRef) {
    CFRelease(gCanvasLinkOverrideRef);
    gCanvasLinkOverrideRef = NULL;
  }
  if (live)
    gCanvasLinkOverrideRef = (void *)CFBridgingRetain([live copy]);
}

void CanvasLinkScopePush(double clipStartTLSec, double clipDurSec) {
  CanvasLinkScopePushWithOverride(clipStartTLSec, clipDurSec, nil);
}

void CanvasLinkScopePop(void) {
  gCanvasLinkScope.active = NO;
  if (gCanvasLinkOverrideRef) {
    CFRelease(gCanvasLinkOverrideRef);
    gCanvasLinkOverrideRef = NULL;
  }
}

NSArray<NSNumber *> *CanvasResolvedLaneValue(KKLane *lane, double frac) {
  if (!gCanvasLinkScope.active || lane.linkExpression.length == 0)
    return KKLaneDisplayValueAtFraction(lane, frac);
  // Linear frac -> project seconds, the same mapping the published curves use
  // (KKLinkedCurve samples by (tlSec - start) / span).
  double tlSec = gCanvasLinkScope.startTLSec + frac * gCanvasLinkScope.durSec;
  KKLinkRefOverride refOv = nil;
  if (gCanvasLinkOverrideRef) {
    CanvasLinkLaneOverride live =
        (__bridge CanvasLinkLaneOverride)gCanvasLinkOverrideRef;
    refOv = ^NSArray<NSNumber *> *(NSString *refName) {
      return live(refName, frac);
    };
  }
  return KKLinkResolvedLaneValueWithOverride(lane, frac, tlSec,
                                             gCanvasLinkScope.durSec, refOv);
}

NSArray<NSNumber *> *CanvasResolvedDiscreteLaneValue(KKLane *lane,
                                                     double frac) {
  if (lane.linkExpression.length)
    return CanvasResolvedLaneValue(lane, frac);
  return KKTimelineLaneValueAtFraction(lane, frac);
}
