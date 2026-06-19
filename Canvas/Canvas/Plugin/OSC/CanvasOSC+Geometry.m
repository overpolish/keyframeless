/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import <FxPlug/FxPlugSDK.h>

@implementation CanvasOSC (Geometry)

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
  self.scale.center = [self.position positionCanvasAtTime:time];
  self.scale.frameMin = [self _onScreenFrameMin];
  self.scale.optRevealActive = self.optRevealActive;
  self.scale.dragging = self.isDragging;
}

// Feed the rotation control this tick's centre (= the layer's Position handle)
// + reveal/drag state. Shared by draw / hit-test / mouse.
- (void)_syncRotationControlAtTime:(CMTime)time {
  self.rotation.center = [self.position positionCanvasAtTime:time];
  self.rotation.optRevealActive = self.optRevealActive;
  self.rotation.dragging = self.isDragging;
}

@end
