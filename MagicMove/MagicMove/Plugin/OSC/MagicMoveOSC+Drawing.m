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

// Read-only motion path: the trajectory the clip's centre travels across the
// whole effect, sampled from the SAME evaluator the render uses
// (KKTimelineLaneValueAtVisualFractionSmoothed) so the line matches the clip's
// motion exactly, curved segments included. Object→canvas via the OSC API, the
// same mapping the Position handle uses.
- (void)_drawPositionPathToDestination:(FxImageTile *)destinationImage
                            ghostAlpha:(float)ghostAlpha {
  KKLane *lane = _positionLane();
  if (!lane || lane.keyposes.count < 2)
    return;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  // Geometric route (no temporal easing), so overshooting easing curves don't
  // draw loops on the path - the line is the spatial trajectory, not the
  // timing dynamics (which are felt in playback).
  NSArray<NSValue *> *path = KKLanePositionPathPoints(lane, 24);
  NSUInteger n = path.count;
  if (n < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * n);
  for (NSUInteger i = 0; i < n; i++) {
    NSPoint o = path[i].pointValue;
    CGPoint c = CGPointZero;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:o.x
                            fromY:o.y
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&c.x
                              toY:&c.y];
    pts[i] = c;
  }
  simd_float4 red = {1.0f, 0.25f, 0.25f, 0.9f * ghostAlpha};
  [self drawLineStripWithPoints:pts
                          count:n
                          color:red
                      halfWidth:2.0f
               destinationImage:destinationImage];
  free(pts);
}

// Tangent handles for every smooth keypose: a thin connector from the anchor to
// a small dot at the effective handle position (manual, or the auto Catmull-Rom
// tangent the curve uses). An endpoint's missing side is a zero-length handle
// and is skipped.
- (void)_drawHandlesToDestination:(FxImageTile *)destinationImage
                           atTime:(CMTime)time
                       ghostAlpha:(float)ghostAlpha {
  KKLane *lane = _positionLane();
  if (!lane || lane.keyposes.count < 2)
    return;
  self.handleOSC.ghostAlpha = ghostAlpha;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  simd_float4 hc = {1.0f, 1.0f, 1.0f, 0.85f * ghostAlpha};
  for (NSUInteger i = 0; i < kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    CGPoint anchorC = [self _canvasFromObjX:ax y:ay];
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint hCanvas = [self _canvasFromObjX:(ax + sides[s].x)
                                            y:(ay + sides[s].y)];
      [self drawLineFrom:anchorC
                        to:hCanvas
                     color:hc
                 halfWidth:2.0f
          destinationImage:destinationImage];
      [self.handleOSC drawAtCanvasPosition:hCanvas
                                 isHovered:NO
                                  isActive:NO
                          destinationImage:destinationImage
                                    atTime:time];
    }
  }
}

// A small dot at every Position keypose - the draggable anchors of the path.
// Drawn over the path line, under the playhead handle. The keypose under the
// playhead is skipped when `skipActive` (the big arc handle covers it, so its
// dot would be a redundant point inside the arc).
- (void)_drawKeyposeAnchorsToDestination:(FxImageTile *)destinationImage
                                  atTime:(CMTime)time
                                skipFrac:(double)skipFrac
                              skipActive:(BOOL)skipActive
                              ghostAlpha:(float)ghostAlpha {
  KKLane *lane = _positionLane();
  if (!lane || lane.keyposes.count < 2)
    return;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  self.anchorOSC.ghostAlpha = ghostAlpha;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSInteger skipIdx = -1;
  if (skipActive) {
    double bd = 1e9;
    for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
      double d = fabs(kps[i].time - skipFrac);
      if (d < bd) {
        bd = d;
        skipIdx = i;
      }
    }
  }
  // Linked keyposes share the active one's position; KKLaneCoalescedAnchors
  // drops it and any coincident partner (so they collapse under the position
  // handle) and dedups the rest. Returns object-space points to convert + draw.
  for (NSValue *pv in KKLaneCoalescedAnchors(lane, skipIdx)) {
    NSPoint v = pv.pointValue;
    CGPoint c = CGPointZero;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:v.x
                            fromY:v.y
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&c.x
                              toY:&c.y];
    [self.anchorOSC drawAtCanvasPosition:c
                               isHovered:NO
                                isActive:NO
                        destinationImage:destinationImage
                                  atTime:time];
  }
}

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
  BOOL posShownHere = _positionVisibleAtFraction(frac);
  BOOL posEnabled = [self kkOSCElementVisible:@"Position"];
  // The arc handle is the position target only when the interaction is the
  // handle itself, not a grabbed keypose anchor (both report kOSCPositionPart).
  // Drag: dragAnchorFrac is NaN for the handle. Hover: hoverTargetIsAnchor was
  // set by the hit-test.
  BOOL handleTargeted = (activePart == kOSCPositionPart) &&
                        (self.isDragging ? isnan(self.dragAnchorFrac)
                                         : !self.hoverTargetIsAnchor);
  BOOL draggingHandle = self.isDragging && handleTargeted;
  BOOL posVisible = draggingHandle || (posEnabled && posShownHere);
  // Opt-hold reveals a hidden Position handle as a dimmed ghost (clickable to
  // re-show); only when it would otherwise be on screen at this playhead.
  BOOL posGhost = !posVisible && self.optRevealActive &&
                  [self kkOSCRevealEligible:@"Position"] && posShownHere;

  // The motion path (line + anchors + handles) is a SEPARATE hideable OSC from
  // the Position arc handle. Opt-hold reveals a hidden path as a dimmed ghost.
  BOOL pathEnabled = [self kkOSCElementVisible:@"Path"];
  BOOL pathReveal = self.optRevealActive && [self kkOSCRevealEligible:@"Path"];
  if (pathEnabled || pathReveal) {
    float pg = pathEnabled ? 1.0f : [self kkRevealGhostAlpha];
    [self _drawPositionPathToDestination:destinationImage ghostAlpha:pg];
    [self _drawHandlesToDestination:destinationImage atTime:time ghostAlpha:pg];
    [self _drawKeyposeAnchorsToDestination:destinationImage
                                    atTime:time
                                  skipFrac:frac
                                skipActive:posVisible
                                ghostAlpha:pg];
  }

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

  // Position arc handle, drawn above rotation + scale so it stays on top.
  if (posVisible || posGhost) {
    self.fillAlpha = posGhost ? [self kkRevealGhostAlpha] : 1.0f;
    [self drawAtCanvasPosition:pos
                     isHovered:handleTargeted
                      isActive:draggingHandle
              destinationImage:destinationImage
                        atTime:time];
  }

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

  if (self.isDragging && activePart == kOSCPositionPart && self.cmdSnapActive) {
    simd_float4 yellow = {1, 1, 0, 1};
    NSColor *accentNS = [[NSColor accentMatchingHost]
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat ar = 1, ag = 1, ab = 1, aa = 1;
    [accentNS getRed:&ar green:&ag blue:&ab alpha:&aa];
    simd_float4 accent = {(float)ar, (float)ag, (float)ab, (float)aa};
    [self.snapEngine drawSnapGuidesWithOSC:self
                             isObjectSpace:YES
                               canvasColor:yellow
                               objectColor:accent
                          destinationImage:destinationImage];
  }
}

@end
