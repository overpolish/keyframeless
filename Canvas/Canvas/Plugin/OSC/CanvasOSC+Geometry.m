/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h" // CanvasComposedGroupPointObj / GroupRotation
#import "CanvasOSC_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <simd/simd.h>

@implementation CanvasOSC (Geometry)

// Raw OBJECT (Y-down, FCP convention) -> CANVAS, no control offset applied.
- (CGPoint)_rawCanvasFromObjX:(double)ox y:(double)oy {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  CGPoint c = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:ox
                          fromY:oy
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c.x
                            toY:&c.y];
  return c;
}

// Raw CANVAS (ioSurface px) -> OBJECT (Y-down), no control offset applied.
- (CGPoint)_rawObjFromCanvasX:(double)cx y:(double)cy {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  CGPoint o = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:cx
                          fromY:cy
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&o.x
                            toY:&o.y];
  return o;
}

// Read a 2-component lane value from the published (selected-layer) snapshot at
// `frac`, defaulting to `def` when the lane is absent / empty.
- (void)_snapshotValuesForLabel:(NSString *)label
                            frac:(double)frac
                            outX:(double *)outX
                            outY:(double *)outY
                         default:(double)def {
  *outX = def;
  *outY = def;
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:label]) {
      if (l.keyposes.count == 0)
        return;
      NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(l, frac);
      if (v.count > 0)
        *outX = v[0].doubleValue;
      if (v.count > 1)
        *outY = v[1].doubleValue;
      return;
    }
}

// Composed object point (FCP OBJECT Y-down) of a member-local clip point: apply
// the ancestor groups (render space is Y-up, so flip Y across the boundary).
- (CGPoint)_composedObjForObjX:(double)ox
                             y:(double)oy
                        member:(KKBezierPath *)sel
                         paths:(NSArray<KKBezierPath *> *)paths
                          frac:(double)frac
                        aspect:(float)aspect {
  float gx = (float)ox, gy = (float)(1.0 - oy);
  CanvasComposedGroupPointObj(paths, sel, frac, aspect, (float)ox,
                              (float)(1.0 - oy), &gx, &gy);
  return CGPointMake(gx, 1.0 - gy);
}

- (void)_applyGroupComposeOffsetAtTime:(CMTime)time {
  KKBezierPath *sel = [self _selectedLayer];
  NSArray<KKBezierPath *> *paths = [self _snapshotPaths];
  double frac = [self fractionAtTime:time];
  float aspect = (float)[self _canvasAspect];

  // Object-space PROJECTIVE map (homography) taking a member-local clip-object
  // point through its ancestor groups (identity for an ungrouped layer / group
  // selection), so the member's OSCs draw where the TRANSFORMED group actually
  // renders the member. Sampled at the 4 unit-square corners (a 3-point affine
  // dropped the perspective term and offset the OSC under group tilt). Computed
  // LIVE every tick: it depends only on the groups' stored transforms + stored
  // Anchor pivots, NEVER on the member value being dragged - the group pivot is
  // the stored Anchor lane now, not the live content centre - so there's no
  // feedback (the old content-centre pivot fed back and forced a freeze hack).
  CGPoint p0 = [self _composedObjForObjX:0 y:0 member:sel paths:paths frac:frac aspect:aspect];
  CGPoint p1 = [self _composedObjForObjX:1 y:0 member:sel paths:paths frac:frac aspect:aspect];
  CGPoint p2 = [self _composedObjForObjX:1 y:1 member:sel paths:paths frac:frac aspect:aspect];
  CGPoint p3 = [self _composedObjForObjX:0 y:1 member:sel paths:paths frac:frac aspect:aspect];
  simd_float3x3 A = CanvasSquareToQuadHomography(p0, p1, p2, p3);
  // The controls stay flat; their drawn position warps through A (the perspective
  // divide happens in KKPositionOSC / the pivot; drag inverts A to the member's
  // own value).
  self.position.parentObjectTransform = A;
  self.anchor.parentObjectTransform = A;

  // Rotation rings additionally tilt with the group's rotation (member-local
  // drag - the group factors out).
  self.rotation.baseRotation = CanvasComposedGroupRotation(paths, sel, frac);

  // The gizmo cluster (rings + scale box) centres on the composed ANCHOR pivot
  // (AE-standard): (Position + Anchor offset) run through A.
  double posX, posY, ax, ay;
  [self _snapshotValuesForLabel:@"Position" frac:frac outX:&posX outY:&posY default:0.5];
  [self _snapshotValuesForLabel:@"Anchor" frac:frac outX:&ax outY:&ay default:0.5];
  simd_float3 piv =
      simd_mul(A, simd_make_float3((float)(posX + ax - 0.5),
                                   (float)(posY + ay - 0.5), 1.0f));
  double pivX = (piv.z != 0.0f) ? piv.x / piv.z : piv.x;
  double pivY = (piv.z != 0.0f) ? piv.y / piv.z : piv.y;
  self.gizmoPivotCanvas = [self _rawCanvasFromObjX:pivX y:pivY];
}

// The canvas-pixel lengths of the object-space unit axes: maps OBJECT (0,0),
// (1,0), (0,1) to CANVAS and returns the X-axis and Y-axis spans. Object space
// is normalised [0,1] but the canvas is W:H pixels, so these give both the
// gizmo's reference size and the pixel aspect. NO when the OSC API is absent.
- (BOOL)_objectBasisWidth:(double *)outW height:(double *)outH {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;
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
  *outW = hypot(cx.x - c0.x, cx.y - c0.y);
  *outH = hypot(cy.x - c0.x, cy.y - c0.y);
  return YES;
}

// Min dimension of the canvas frame - the reference length the scale gizmo sizes
// against, so the box tracks the clip with viewer zoom rather than being a fixed
// screen size.
- (double)_onScreenFrameMin {
  double w = 0, h = 0;
  if (![self _objectBasisWidth:&w height:&h])
    return 1000.0;
  double m = MIN(w, h);
  return (m > 1.0) ? m : 1000.0;
}

// Canvas pixel aspect (outputWidth/outputHeight), from the object-space basis.
- (double)_canvasAspect {
  double w = 0, h = 0;
  if (![self _objectBasisWidth:&w height:&h] || h <= 0.0)
    return 1.0;
  return w / h;
}

// Feed the scale control this tick's box centre (= the layer's Position handle)
// + gizmo size + reveal/drag state. Shared by draw / hit-test / mouse.
- (void)_syncScaleControlAtTime:(CMTime)time {
  // Concentric with the anchor pivot (where the layer scales from), not the bare
  // Position handle - the gizmo cluster (box + rings + anchor) shares one centre.
  self.scale.center = self.gizmoPivotCanvas;
  self.scale.frameMin = [self _onScreenFrameMin];
  self.scale.optRevealActive = self.optRevealActive;
  self.scale.dragging = self.isDragging;
}

// Feed the rotation control this tick's centre (= the layer's Position handle)
// + reveal/drag state. Shared by draw / hit-test / mouse.
- (void)_syncRotationControlAtTime:(CMTime)time {
  // Centre on the anchor pivot (where the layer rotates around), not the bare
  // Position handle.
  self.rotation.center = self.gizmoPivotCanvas;
  self.rotation.optRevealActive = self.optRevealActive;
  self.rotation.dragging = self.isDragging;
}

@end
