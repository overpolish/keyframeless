/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "GlowOSCRadiusMath.h"
#import "OSC_Internal.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

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
  }
  return self;
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

// Map the per-axis radius value (px, 0..500) to a canvas ring radius. The sqrt
// keeps a large blur from sending the ring far off-screen while still growing
// monotonically. Matches the pre-v3 Glow ring sizing.
- (void)updateRingForFraction:(double)frac {
  double minDim = [self canvasMinDimension];
  NSArray<NSNumber *> *v = GlowOSCRadiusValuesAtFraction(frac);
  double rx = v[0].doubleValue;
  double ry = v.count > 1 ? v[1].doubleValue : rx;
  _radiusRing.ringRadius = (float)(minDim * 0.012 * sqrt(MAX(0.0, rx)));
  _radiusRing.ringRadiusY = (float)(minDim * 0.012 * sqrt(MAX(0.0, ry)));
}

// Override the base OSC-visibility hooks: Glow exposes only the Radius ring in
// M1. The master tick / pills / opt-click-hide / opt-reveal all live in
// KKOnScreenControl.
- (NSArray<NSString *> *)oscElementKeys {
  return @[ @"Radius" ];
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  return (activePart == kOSCRadiusPart) ? @"Radius" : nil;
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

  // Visibility rule (matches Rounded / mini-viewer): show when the lane is a
  // constant (always) or animated and the playhead is on a keypose; mid-drag
  // the active ring always draws so the handle tracks the cursor. Opt-reveal
  // surfaces a hidden ring so an opt-click can re-show it.
  double frac = [self fractionAtTime:time];
  BOOL shownHere =
      _ringDragging || GlowOSCLaneVisibleAtFraction(@"Radius", frac);
  BOOL enabled = [self kkOSCElementVisible:@"Radius"];
  BOOL visible = shownHere && enabled;
  BOOL reveal = !visible && self.optRevealActive && shownHere &&
                [self kkOSCRevealEligible:@"Radius"];
  if (!visible && !reveal) {
    [_radiusRing clearCursorIfSet];
    return;
  }

  [self updateRingForFraction:frac];
  CGPoint center = [self canvasCenter];
  _radiusRing.center = center;
  // When only shown via Opt-reveal, dim it to a re-enable ghost - BUT not in
  // "peek and use" mode (master off + Opt), where kkRevealGhostAlpha
  // returns 1.0 because the revealed controls are fully interactive. Remap the
  // base 0.3 dim to 0.6 (0.3 reads too faint for a thin ring).
  float revealGA = reveal ? [self kkRevealGhostAlpha] : 1.0f;
  _radiusRing.ghostAlpha = (revealGA < 1.0f) ? 0.6f : 1.0f;
  [_radiusRing drawAtCanvasPosition:center
                          isHovered:(activePart == kOSCRadiusPart)
                           isActive:_ringDragging
                   destinationImage:destinationImage
                             atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  double frac = [self fractionAtTime:time];
  BOOL enabled = [self kkOSCElementVisible:@"Radius"];
  BOOL revealOnly =
      !enabled && self.optRevealActive && [self kkOSCRevealEligible:@"Radius"];
  BOOL interactive =
      (enabled || revealOnly) && GlowOSCLaneVisibleAtFraction(@"Radius", frac);
  if (interactive) {
    [self updateRingForFraction:frac];
    _radiusRing.center = [self canvasCenter];
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
}

@end
