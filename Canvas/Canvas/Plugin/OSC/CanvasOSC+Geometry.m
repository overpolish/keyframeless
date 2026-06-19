/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h" // CanvasComposedGroupRotation
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

- (void)_applyGroupComposeOffsetAtTime:(CMTime)time {
  double frac = [self fractionAtTime:time];

  // Position + Anchor OSCs stay 2D (member-local): they sit at the layer's own
  // clip position, NOT where a TRANSFORMED group renders the member. Following
  // a group's full 3D transform isn't drag-invertible in a 2D viewer - the group
  // pivots on its content-bbox centre, which the dragged value itself moves, so
  // any compensating transform feeds back (diverged to 100000s px) and a frozen
  // one makes the OSC jump on release. We accept the limitation: there's no way
  // to move around in 3D space in the viewer anyway. (The kit
  // `parentObjectTransform` hook stays for a future pen-tool path UI.)
  self.position.parentObjectTransform = matrix_identity_float3x3;
  self.anchor.parentObjectTransform = matrix_identity_float3x3;

  // Rotation rings DO tilt with the ancestor groups' rotation so the layer-level
  // gizmo drags along the visually-rotated axes (acts as expected after the group
  // is spun). This is safe where the affine wasn't: baseRotation depends only on
  // the group's rotation, never on the member value being dragged, so no feedback
  // and no jump. The written rotation stays member-local (the group factors out).
  self.rotation.baseRotation = CanvasComposedGroupRotation(
      [self _snapshotPaths], [self _selectedLayer], frac);

  // The gizmo cluster (rings + scale box) still centres on the ANCHOR pivot
  // (AE-standard), computed member-local: Position + Anchor offset.
  double posX, posY, ax, ay;
  [self _snapshotValuesForLabel:@"Position" frac:frac outX:&posX outY:&posY default:0.5];
  [self _snapshotValuesForLabel:@"Anchor" frac:frac outX:&ax outY:&ay default:0.5];
  self.gizmoPivotCanvas =
      [self _rawCanvasFromObjX:(posX + ax - 0.5) y:(posY + ay - 0.5)];
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
