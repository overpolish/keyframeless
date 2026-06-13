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

// Scale transform box: border + 8 handles (4 corners, 4 edge midpoints) + a
// "X% x Y%" readout, centred on `center`. Half-extents come from the scale
// percent through the KKScaleGizmo curve (per axis), so the box is a compact
// screen-space gizmo that stays grabbable at any value rather than tracking the
// clip's real pixel bounds.
- (void)_drawScaleBoxAtCenter:(CGPoint)center
                       atTime:(CMTime)time
                   ghostAlpha:(float)ghostAlpha
                 activeHandle:(NSInteger)activeHandle
             destinationImage:(FxImageTile *)destinationImage {
  double frac = [self _fractionAtTime:time];
  NSArray<NSNumber *> *sv = _scaleValuesAtFraction(frac);
  double sclX = sv.count > 0 ? sv[0].doubleValue : 100.0;
  double sclY = sv.count > 1 ? sv[1].doubleValue : 100.0;
  double e0 = 0, span = 0;
  [self _scaleGizmoE0:&e0 span:&span];
  CGPoint handles[8];
  MMScaleHandlePositions(center, sclX, sclY, e0, span, handles);
  CGPoint bl = handles[0], tr = handles[2];

  self.scaleBox.ghostAlpha = ghostAlpha;
  NSString *readout =
      [NSString stringWithFormat:@"%.0f%% x %.0f%%", sclX, sclY];
  [self.scaleBox drawWithTopRight:tr
                       bottomLeft:bl
                          readout:readout
                     activeHandle:activeHandle
                 destinationImage:destinationImage
                           atTime:time];
}

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
  BOOL rotDragging = self.isDragging && activePart == kOSCRotationPart;
  if ([self _configureRotationRingsAtFraction:frac dragging:rotDragging]) {
    [self _syncRotationColorsFromLane];
    NSArray<NSNumber *> *r = _rotationValuesAtFraction(frac);
    self.rotationOSC.rotX = (float)(r[0].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotY = (float)(r[1].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotZ = (float)(r[2].doubleValue * M_PI / 180.0);
    self.rotationOSC.center = pos;
    [self.rotationOSC
        drawAtCanvasPosition:pos
                   isHovered:(activePart == kOSCRotationPart)
                    isActive:self.isDragging && (activePart == kOSCRotationPart)
            destinationImage:destinationImage
                      atTime:time];
  }
  // Scale transform box, drawn outside the rotation rings. Only on screen where
  // the Scale lane is visible (keypose times / constant), same as Position.
  // Opt-hold reveals a hidden box as a dimmed ghost.
  BOOL scaleShownHere = _scaleVisibleAtFraction(frac);
  BOOL scaleEnabled = [self kkOSCElementVisible:@"Scale"];
  BOOL scaleDragging = self.isDragging && activePart == kOSCScalePart;
  BOOL scaleVisible = scaleDragging || (scaleEnabled && scaleShownHere);
  BOOL scaleGhost = !scaleVisible && self.optRevealActive &&
                    [self kkOSCRevealEligible:@"Scale"] && scaleShownHere;
  if (scaleVisible || scaleGhost) {
    NSInteger activeHandle = scaleDragging ? self.scaleGrabHandle : -1;
    [self _drawScaleBoxAtCenter:pos
                         atTime:time
                     ghostAlpha:(scaleGhost ? [self kkRevealGhostAlpha]
                                            : 1.0f)activeHandle:activeHandle
               destinationImage:destinationImage];
  }

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
