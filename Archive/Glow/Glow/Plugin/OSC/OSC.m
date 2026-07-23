/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "GlowOSCRadiusMath.h"
#import "OSC_Internal.h"
#import "Plugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KeyframelessKit.h>

// The live OSC for this XPC process, so the inspector's guide functions (same
// process) can reach the ring geometry through the C entry points below.
static GlowOSC *sCurrentOSC = nil;

// One generic OSC-guide engine per XPC process (the affine / staleness / step +
// position notifications). Reused unchanged by the KKJoyrideOSCSegment the
// inspector builds; the ring-specific math is the two C functions below it.
static KKOSCGuideBridge *GlowGuideBridge(void) {
  static KKOSCGuideBridge *sBridge = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sBridge = [[KKOSCGuideBridge alloc] init];
    // The default 30pt spotlight suits a small point handle (Rounded's dot);
    // Glow's ring is a large thin ellipse, so a wide cutout just frames empty
    // canvas with the stroke lost inside it. Match the mini-viewer's spotlight:
    // its handle radius is kKKMiniHandleOuterPt (4.5), and both cutouts go
    // through the same -8/-3 inset, so 4.5 here reproduces the mini's size.
    sBridge.spotlightHandleRadius = 4.5;
  });
  return sBridge;
}

KKOSCGuideBridge *GlowSharedOSCGuideBridge(void) { return GlowGuideBridge(); }

// Guide-scoped [X, Y] radius. The OSC cannot read the timeline blob from the
// drawOSC tick (FxParameterRetrievalAPI is nil there), so during the guide the
// strategy pushes the live radius here (same XPC process) and the ring tracks
// it without the unreadable blob.
static NSArray<NSNumber *> *sGuideRadiusValues = nil;

void GlowSetGuideRadiusValues(NSArray<NSNumber *> *values) {
  if (values.count >= 1)
    sGuideRadiusValues = [values copy];
}

// Re-anchor the bridge's screen↔canvas map by pairing a screen point with the
// ring handle's current canvas position (the bridge supplies the live scale).
static BOOL GlowReanchor(GlowOSC *osc, NSPoint screenPt) {
  if (!osc)
    return NO;
  CGPoint handle = [osc
      ringHandleCanvasPositionForFraction:[osc fractionAtTime:kCMTimeZero]];
  return [GlowGuideBridge() reanchorAtScreen:screenPt handleCanvasPos:handle];
}

void GlowOSCCaptureGuideAnchorAtScreen(NSPoint screenPt) {
  GlowOSC *osc = sCurrentOSC;
  if (!osc) {
    KKLogWarn(@"[GlowOSCGuide] capture anchor skipped: no current OSC");
    return;
  }
  if (!GlowReanchor(osc, screenPt))
    KKLogWarn(@"[GlowOSCGuide] capture anchor skipped: no live scale yet "
              @"(drawOSC has not run)");
}

// Inverse of the ring's radius mapping: screen → canvas (via the bridge's
// affine), then distance from the clip centre back through the scale-gizmo
// curve (GlowOSCRadiusForRingExtent), linked so both axes match - the same
// uniform path a real ring drag takes. Falls back to the last guide radius
// until the bridge has cached usable geometry.
NSArray<NSNumber *> *GlowGuideRadiusValuesForScreenPoint(NSPoint screenPt) {
  KKOSCGuideBridge *b = GlowGuideBridge();
  NSArray<NSNumber *> *fallback =
      sGuideRadiusValues ?: @[ @(kGlowM1Radius), @(kGlowM1Radius) ];
  CGPoint tr = b.currentCanvasTopRight, bl = b.currentCanvasBottomLeft;
  double cx = 0, cy = 0;
  if (!b.geometryValid || ![b screenToCanvas:screenPt outX:&cx outY:&cy])
    return fallback;
  double centerX = (tr.x + bl.x) * 0.5;
  double centerY = (tr.y + bl.y) * 0.5;
  double minDim = fmin(fabs(tr.x - bl.x), fabs(tr.y - bl.y));
  if (minDim <= 0.0)
    return fallback;
  double dist = hypot(cx - centerX, cy - centerY);
  double val = MAX(0.0, MIN(500.0, GlowOSCRadiusForRingExtent(dist, minDim)));
  return @[ @(val), @(val) ];
}

@implementation GlowOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _radiusRing = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _radiusRing.clearsOnDraw = NO;
    // Leave tintColor nil so the ring keeps KKRingOSC's default idle/hover/
    // active fill + stroke (the pre-v3 Glow ring look). Leave hoverCursor nil
    // too, so the ring picks the resize cursor from the hover angle
    // (left/right, up/down, or the two diagonals) instead of a fixed one.
    _positionController = [[KKPositionOSC alloc] initWithAPIManager:apiManager
                                                          laneLabel:@"Position"
                                                          pathLabel:@"Path"];
    _positionController.positionActivePart = kOSCPositionPart;
    _positionController.tangentActivePart = kOSCPathHandlePart;
    // No Position guide in Glow (the OSC guide is the radius ring only).
    _positionController.guideProvider = nil;
    for (KKLane *l in [GlowPlugin availableLanes])
      if ([l.label isEqualToString:@"Position"])
        _positionController.templateLane = l;
    sCurrentOSC = self;
  }
  return self;
}

- (void)dealloc {
  if (sCurrentOSC == self)
    sCurrentOSC = nil;
}

- (BOOL)getCanvasTopRight:(CGPoint *)outTopRight
               bottomLeft:(CGPoint *)outBottomLeft {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;
  CGPoint tr = {0, 0}, bl = {0, 0};
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1.0
                          fromY:1.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&tr.x
                            toY:&tr.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.0
                          fromY:0.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&bl.x
                            toY:&bl.y];
  if (outTopRight)
    *outTopRight = tr;
  if (outBottomLeft)
    *outBottomLeft = bl;
  return YES;
}

// During a guide step the ring draws the strategy-pushed value (the blob is
// unreadable in the drawOSC tick); otherwise the parameterChanged snapshot.
- (NSArray<NSNumber *> *)guideRadiusValuesForFraction:(double)frac {
  if (GlowGuideBridge().guideStep > 0 && sGuideRadiusValues.count >= 1)
    return sGuideRadiusValues;
  return GlowOSCRadiusValuesAtFraction(frac);
}

// A point on the ellipse at 45 degrees (top-right) - the single "handle" the
// guide bridge spotlights and drives. Any point on the ring works; the drag
// itself maps the cursor's distance from centre, not this point.
- (CGPoint)ringHandleCanvasPositionForFraction:(double)frac {
  CGPoint center = [self canvasCenter];
  double minDim = [self canvasMinDimension];
  NSArray<NSNumber *> *v = [self guideRadiusValuesForFraction:frac];
  double rx = v.count > 0 ? v[0].doubleValue : kGlowM1Radius;
  double ry = v.count > 1 ? v[1].doubleValue : rx;
  double rrx = GlowOSCRingExtentForRadius(rx, minDim);
  double rry = GlowOSCRingExtentForRadius(ry, minDim);
  const double k = M_SQRT1_2;
  return CGPointMake(center.x + rrx * k, center.y + rry * k);
}

- (CGPoint)guideTargetCanvasPosition {
  CGPoint center = [self canvasCenter];
  double minDim = [self canvasMinDimension];
  double rr = GlowOSCRingExtentForRadius(kGlowOSCGuideTargetRadius, minDim);
  const double k = M_SQRT1_2;
  return CGPointMake(center.x + rr * k, center.y + rr * k);
}

- (double)fractionAtTime:(CMTime)time {
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return 0.0;
  CMTime effectStart = kCMTimeZero, effectDur = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDur];
  double durSec = CMTimeGetSeconds(effectDur);
  if (durSec <= 0)
    return 0.0;
  return MAX(0.0,
             MIN(1.0, (CMTimeGetSeconds(time) - CMTimeGetSeconds(effectStart)) /
                          durSec));
}

- (CGPoint)canvasCenter {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  CGPoint c = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.5
                          fromY:0.5
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c.x
                            toY:&c.y];
  return c;
}

// Min dimension of the clip's frame in canvas space (object [0,1]^2 corners
// converted to canvas). Scales with viewer zoom, so the ring tracks the clip
// rather than staying a fixed screen size.
- (double)canvasMinDimension {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return 1000.0;
  CGPoint c0 = CGPointZero, cx = CGPointZero, cy = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0
                          fromY:0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c0.x
                            toY:&c0.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1
                          fromY:0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cx.x
                            toY:&cx.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0
                          fromY:1
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cy.x
                            toY:&cy.y];
  double w = hypot(cx.x - c0.x, cx.y - c0.y);
  double h = hypot(cy.x - c0.x, cy.y - c0.y);
  double m = MIN(w, h);
  return (m > 1.0) ? m : 1000.0;
}

// Map the per-axis radius value (px, 0..500) to a canvas ring radius via the
// shared scale-gizmo curve, so the ring matches the MagicMove scale box: a
// visible minimum size at 0 (never collapses to a point) growing linearly then
// sqrt-compressed past the pivot. See GlowOSCRingExtentForRadius.
- (void)updateRingForFraction:(double)frac {
  double minDim = [self canvasMinDimension];
  NSArray<NSNumber *> *v = [self guideRadiusValuesForFraction:frac];
  double rx = v[0].doubleValue;
  double ry = v.count > 1 ? v[1].doubleValue : rx;
  _radiusRing.ringRadius = (float)GlowOSCRingExtentForRadius(rx, minDim);
  _radiusRing.ringRadiusY = (float)GlowOSCRingExtentForRadius(ry, minDim);
}

// Override the base OSC-visibility hooks: Glow exposes only the Radius ring in
// M1. The master tick / pills / opt-click-hide / opt-reveal all live in
// KKOnScreenControl.
- (NSArray<NSString *> *)oscElementKeys {
  return @[ @"Radius", @"Position", @"Path" ];
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart == kOSCRadiusPart)
    return @"Radius";
  // A tangent handle is part of the motion path; the arc handle / anchor dot is
  // the Position lane. The controller's hover state disambiguates an arc handle
  // (Position) from a keypose anchor dot (also Position, but the dot belongs to
  // the path element so opt-click hides Path).
  if (activePart == kOSCPathHandlePart)
    return @"Path";
  if (activePart == kOSCPositionPart)
    return self.positionController.hoverTargetIsAnchor ? @"Path" : @"Position";
  return nil;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  double frac = [self fractionAtTime:time];

  // Pull the live geometry FCP only exposes from this tick and feed it to the
  // generic OSC-guide bridge - it owns the zoom-invariant CANVAS→screen affine,
  // the viewer-rect recompute, and the spotlight position notifications. spC=0
  // means "no scale this tick" (the bridge keeps the last).
  CGPoint trC = {0, 0}, blC = {0, 0};
  [self getCanvasTopRight:&trC bottomLeft:&blC];
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 0.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC =
      (rawZoom > 0.0 && displayScale > 0.0) ? rawZoom / displayScale : 0.0;
  [GlowGuideBridge()
      ingestDrawTickWithCanvasTopRight:trC
                            bottomLeft:blC
                           canvasScale:spC
                       handleCanvasPos:
                           [self ringHandleCanvasPositionForFraction:frac]
                       targetCanvasPos:[self guideTargetCanvasPosition]
                             hasTarget:YES];

  // Motion path (line + keypose anchors + tangent handles) is drawn FIRST, so
  // it sits under the ring. The controller owns its own visibility gating
  // (Position/Path element keys, shared per-instance state) and reads the live
  // drag flag for mid-drag draw.
  _positionController.dragging = _positionDragging;
  // Feed opt-reveal so a hidden Position handle / path surfaces as a dim ghost
  // on Opt-hold, matching the radius ring (without it the viewer never peeks
  // Position even though the mini-viewer does).
  _positionController.optRevealActive = self.optRevealActive;
  [_positionController drawPathInDestination:destinationImage
                                      atTime:time
                                  activePart:activePart];

  // Visibility rule (matches Rounded / mini-viewer): show when the lane is a
  // constant (always) or animated and the playhead is on a keypose; mid-drag
  // the active ring always draws so the handle tracks the cursor. While a guide
  // step runs the ring is always drawn so the user has it to grab. Opt-reveal
  // surfaces a hidden ring so an opt-click can re-show it.
  BOOL inGuide = GlowGuideBridge().guideStep > 0;
  BOOL shownHere =
      _ringDragging || inGuide || GlowOSCLaneVisibleAtFraction(@"Radius", frac);
  BOOL enabled = inGuide || [self kkOSCElementVisible:@"Radius"];
  BOOL visible = shownHere && enabled;
  BOOL reveal = !visible && self.optRevealActive && shownHere &&
                [self kkOSCRevealEligible:@"Radius"];
  if (visible || reveal) {
    [self updateRingForFraction:frac];
    // The glow is offset by Position (render: offset = pos-0.5), so the ring
    // centres on the Position handle, not the fixed clip centre - it tracks the
    // glow like MagicMove's rings/box track its Position.
    CGPoint center = [self.positionController positionCanvasAtTime:time];
    _radiusRing.center = center;
    // During a guide, FCP doesn't run its own hover hitTest (the guide panel is
    // frontmost), so take the hover emphasis from the bridge instead of
    // activePart.
    BOOL guideHover = inGuide && GlowGuideBridge().handleHovered;
    // When only shown via Opt-reveal, dim it to a re-enable ghost - BUT not in
    // "peek and use" mode (master off + Opt), where kkRevealGhostAlpha
    // returns 1.0 because the revealed controls are fully interactive. Remap
    // the base 0.3 dim to 0.6 (0.3 reads too faint for a thin ring).
    float revealGA = reveal ? [self kkRevealGhostAlpha] : 1.0f;
    _radiusRing.ghostAlpha = (revealGA < 1.0f) ? 0.6f : 1.0f;
    [_radiusRing
        drawAtCanvasPosition:center
                   isHovered:(activePart == kOSCRadiusPart || guideHover)
                    isActive:_ringDragging
            destinationImage:destinationImage
                      atTime:time];
  } else {
    [_radiusRing clearCursorIfSet];
  }

  // Position arc handle (+ Cmd-snap guides during a Position drag) drawn LAST,
  // on top of the ring so it stays grabbable at the clip centre.
  [_positionController drawHandleInDestination:destinationImage
                                        atTime:time
                                    activePart:activePart];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  double frac = [self fractionAtTime:time];

  // Position handle / motion path is the foreground control (tangent > arc >
  // anchor precedence, owned by the controller); it sets its own viewer cursor
  // on a hit. Map a non-None result to our activePart and skip the ring so the
  // small centre handle wins over the ring stroke passing through it.
  KKPositionHit ph = [self.positionController hitTestAtX:positionX
                                                       y:positionY
                                                  atTime:time];
  if (ph != KKPositionHitNone)
    *activePart = (ph == KKPositionHitTangentHandle) ? kOSCPathHandlePart
                                                     : kOSCPositionPart;

  BOOL enabled = [self kkOSCElementVisible:@"Radius"];
  BOOL revealOnly =
      !enabled && self.optRevealActive && [self kkOSCRevealEligible:@"Radius"];
  BOOL interactive =
      (enabled || revealOnly) && GlowOSCLaneVisibleAtFraction(@"Radius", frac);
  if (*activePart == 0 && interactive) {
    [self updateRingForFraction:frac];
    _radiusRing.center = [self.positionController positionCanvasAtTime:time];
    // Reveal-only = a dim ghost: the ring keeps the arrow cursor (not resize)
    // but still reports the hit so an Opt-click can re-enable it. Peek mode
    // (master off + Opt) stays full (kkRevealGhostAlpha == 1.0) so it's
    // interactive.
    float revealGA = revealOnly ? [self kkRevealGhostAlpha] : 1.0f;
    _radiusRing.ghostAlpha = (revealGA < 1.0f) ? 0.6f : 1.0f;
    // Opt-hover hide/show affordance (only when an Opt-click would actually
    // toggle - i.e. master on, not the peek-and-use mode where Opt just reveals
    // an interactive control): eye.slash over a visible ring, eye over a ghost.
    BOOL optToggle = self.optRevealActive && ![self kkOSCMasterOff];
    _radiusRing.visibilityHint = optToggle ? (revealOnly ? 2 : 1) : 0;
    if ([_radiusRing hitTestAtMousePositionX:positionX
                                   positionY:positionY
                                      atTime:time])
      *activePart = kOSCRadiusPart;
  }
  if (*activePart != kOSCRadiusPart)
    [_radiusRing clearCursorIfSet];
  // Motion full-preview Opt-reveal fallback (shared kit machinery): claim a
  // background part over empty canvas so Motion keeps reporting OPTION on hover.
  *activePart = [self kkOSCBackgroundPartFallbackForActivePart:*activePart];

  // The only place screen + canvas coords arrive together. Feed the bridge: it
  // velocity-gates the sample, re-anchors the screen↔canvas map, recomputes the
  // viewer rect, and posts the spotlight position. The handle position is only
  // needed while a guide step is active.
  CGPoint tr = {0, 0}, bl = {0, 0};
  if (![self getCanvasTopRight:&tr bottomLeft:&bl])
    return;
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 1.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC = rawZoom / displayScale;
  CGPoint handle = CGPointZero;
  if (GlowGuideBridge().guideStep > 0)
    handle =
        [self ringHandleCanvasPositionForFraction:[self fractionAtTime:time]];
  [GlowGuideBridge() ingestHitTestAtScreen:NSEvent.mouseLocation
                                 canvasPos:CGPointMake(positionX, positionY)
                               canvasScale:spC
                                  topRight:tr
                                bottomLeft:bl
                                  onHandle:(*activePart == kOSCRadiusPart)
                           handleCanvasPos:handle];
}

@end
