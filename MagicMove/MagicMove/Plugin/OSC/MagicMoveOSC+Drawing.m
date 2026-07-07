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

  // The Position handle + motion path are owned by the Position controller.
  // Mirror our FxPlug drag state into it (its draw gating reads `dragging`),
  // then draw the motion path FIRST so it sits under rotation/scale.
  self.positionController.dragging = self.isDragging;
  // Feed opt-reveal so a hidden Position handle / path surfaces as a dim ghost
  // on Opt-hold (the rotation + scale controls below get the same; without it
  // the viewer never shows the Position peek, though the mini-viewer does).
  self.positionController.optRevealActive = self.optRevealActive;
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

  // The gizmo cluster (rotation rings + scale box) centres on the ANCHOR pivot
  // (Position + Anchor offset), which is where the render actually rotates /
  // scales the image - so a moved anchor swings/grows the gizmo from there, not
  // from the bare Position handle.
  CGPoint pivot = [self.anchorControl pivotCanvasAtTime:time];

  // Rotation sphere, centred on the anchor pivot. The shared KKRotationOSC owns
  // its own visibility gating, colour sync, pose read and draw; we just feed it
  // this tick's centre + drag/reveal state.
  self.rotationOSC.center = pivot;
  self.rotationOSC.dragging = self.isDragging;
  self.rotationOSC.optRevealActive = self.optRevealActive;
  [self.rotationOSC drawInDestination:destinationImage
                               atTime:time
                           activePart:activePart];
  // Scale transform box, drawn outside the rotation rings. The control owns its
  // own visibility gating (Scale lane shown here + element enabled + opt-reveal
  // ghost); we just feed it this tick's centre, gizmo size and drag state. It
  // scales from the anchor (opted in at init via anchorLaneLabel).
  self.scaleControl.center = pivot;
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

  // Anchor-point pivot square (topmost), drawn by the shared kit control: it
  // owns its visibility gating + ghost + Cmd-snap guides; we just feed it this
  // tick's drag / opt-reveal state.
  self.anchorControl.dragging = self.isDragging;
  self.anchorControl.optRevealActive = self.optRevealActive;
  [self.anchorControl drawInDestination:destinationImage
                                 atTime:time
                             activePart:activePart];
}

@end
