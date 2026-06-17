/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "OSC_Internal.h"
#import "Plugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

@implementation MagicMoveOSC (Drawing)

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  // Clear the draw surface (the encode call is a no-op draw but resets the
  // attachment) so the handle is the only thing visible.
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  double frac = [self _fractionAtTime:time];

  // The Position handle + motion path are owned by the Position controller.
  // Mirror our FxPlug drag state into it (its draw gating reads `dragging`),
  // then draw the motion path FIRST so it sits under rotation/scale.
  self.positionController.dragging = self.isDragging;
  [self.positionController drawPathInDestination:destinationImage
                                          atTime:time
                                      activePart:activePart];

  // Layering (bottom -> top): path, rotation, scale, position, anchor. `pos` is
  // needed by rotation/scale below, but the Position arc itself is drawn after
  // them so the arc sits on top of the rings/box and stays easy to see + grab.
  CGPoint pos = [self oscPositionAtTime:time];

  // Feed the guide bridge this tick's canvas geometry so the timing guide's
  // watch-back step can highlight the viewer.
  [self _ingestGuideDrawTickWithPosition:pos];

  // Rotation sphere is centred on the same canvas point as Position (the
  // image rotates around its centre, which is where Position translates it).
  // The shared KKRotationOSC owns its own visibility gating, colour sync, pose
  // read and draw; we just feed it this tick's centre + drag/reveal state.
  self.rotationOSC.center = pos;
  self.rotationOSC.dragging = self.isDragging;
  self.rotationOSC.optRevealActive = self.optRevealActive;
  [self.rotationOSC drawInDestination:destinationImage
                               atTime:time
                           activePart:activePart];
  // Scale transform box, drawn outside the rotation rings. The control owns its
  // own visibility gating (Scale lane shown here + element enabled + opt-reveal
  // ghost); we just feed it this tick's centre, gizmo size and drag state.
  self.scaleControl.center = pos;
  self.scaleControl.frameMin = [self _onScreenFrameMin];
  self.scaleControl.dragging = self.isDragging;
  self.scaleControl.optRevealActive = self.optRevealActive;
  [self.scaleControl drawInDestination:destinationImage
                                atTime:time
                            activePart:activePart];

  // Position arc handle (+ Cmd-snap guides during a Position drag), drawn above
  // rotation + scale so it stays on top.
  [self.positionController drawHandleInDestination:destinationImage
                                            atTime:time
                                        activePart:activePart];

  // Anchor-point pivot square, at the clip's pivot (Position + Anchor offset).
  // Shown where the Anchor lane is visible (keypose times / constant), same as
  // Scale/Position; opt-hold reveals a hidden one as a dimmed ghost.
  BOOL anchorShownHere = _anchorVisibleAtFraction(frac);
  BOOL anchorEnabled = [self kkOSCElementVisible:@"Anchor"];
  BOOL anchorDragging = self.isDragging && activePart == kOSCAnchorPart;
  BOOL anchorVisible = anchorDragging || (anchorEnabled && anchorShownHere);
  BOOL anchorGhost = !anchorVisible && self.optRevealActive &&
                     [self kkOSCRevealEligible:@"Anchor"] && anchorShownHere;
  if (anchorVisible || anchorGhost) {
    self.anchorPointOSC.ghostAlpha =
        anchorGhost ? [self kkRevealGhostAlpha] : 1.0f;
    CGPoint ac = [self _anchorCanvasAtFraction:frac];
    [self.anchorPointOSC drawAtCanvasPosition:ac
                                    isHovered:self.anchorHovered
                                     isActive:anchorDragging
                             destinationImage:destinationImage
                                       atTime:time];
  }

  [self.anchorSnap drawSnapGuidesWithOSC:self
                           isObjectSpace:YES
                        destinationImage:destinationImage];
}

@end
