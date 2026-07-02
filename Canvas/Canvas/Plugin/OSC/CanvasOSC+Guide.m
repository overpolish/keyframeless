/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import "CanvasOSCGuide.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Shared per-process OSC guide bridge. ARC-safe static singleton (no
// dispatch_once for the ObjC object - the inspector guide and the OSC live in
// the same XPC process and share this one instance for the process lifetime).
static KKOSCGuideBridge *CanvasGuideBridge(void) {
  static KKOSCGuideBridge *sBridge = nil;
  if (!sBridge)
    sBridge = [[KKOSCGuideBridge alloc] init];
  return sBridge;
}

KKOSCGuideBridge *CanvasSharedOSCGuideBridge(void) {
  return CanvasGuideBridge();
}

// Guide-scoped Position (object [0,1] clip space). The OSC can't read the layer
// blob from the drawOSC tick (FxParameterRetrievalAPI is nil there), so during
// a guide the inspector drag pushes the live position here and the handle
// follows it - mirrors MagicMove's sGuidePosition / Rounded's sGuideRadius.
static CGPoint sCanvasGuidePosition = {0.5, 0.5};

// Object-space target the interactive drag nudges the Position handle toward
// (upper-left of centre, clearly offset from the 0.5,0.5 seed).
static const CGPoint kCanvasGuideTargetObject = {0.3, 0.7};

void CanvasSetGuidePosition(double objX, double objY) {
  sCanvasGuidePosition = CGPointMake(objX, objY);
}

CGPoint CanvasGuideTargetObjectPosition(void) {
  return kCanvasGuideTargetObject;
}

BOOL CanvasGuidePositionForScreenPoint(NSPoint screenPt, double *outX,
                                       double *outY) {
  KKOSCGuideBridge *b = CanvasGuideBridge();
  NSRect vr = b.estimatedViewerScreenRect;
  if (!b.geometryValid || NSIsEmptyRect(vr))
    return NO;
  double x = (screenPt.x - NSMinX(vr)) / NSWidth(vr);
  double y = (screenPt.y - NSMinY(vr)) / NSHeight(vr);
  if (outX)
    *outX = MAX(0.0, MIN(1.0, x));
  if (outY)
    *outY = MAX(0.0, MIN(1.0, y));
  return YES;
}

@implementation CanvasOSC (Guide)

// Generic FxPlug canvas conversion (object [0,1] corners -> canvas), nothing
// Canvas-specific. The whole-frame corners drive the bridge's zoom-invariant
// CANVAS->screen affine, so the viewer rect tracks the clip rather than a fixed
// screen size.
- (BOOL)_guideCanvasTopRight:(CGPoint *)outTR bottomLeft:(CGPoint *)outBL {
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
  if (outTR)
    *outTR = tr;
  if (outBL)
    *outBL = bl;
  return YES;
}

// drawOSC context: canvasZoom is often 0 here (no live canvas), so spC may be
// 0 - the bridge keeps its last good scale (bootstrapped by the hover feed).
// Keeps the viewer rect + canvas-reference fresh on every draw tick.
- (void)_ingestGuideDrawTickWithPosition:(CGPoint)handleCanvasPos {
  CGPoint tr, bl;
  if (![self _guideCanvasTopRight:&tr bottomLeft:&bl])
    return;
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 0.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC =
      (rawZoom > 0.0 && displayScale > 0.0) ? rawZoom / displayScale : 0.0;
  // During a guide drag, feed the object-space target (-> canvas) so the bridge
  // can spotlight the glowing destination; otherwise we only need the viewer
  // rect + canvas reference (the disabled-guides gate).
  BOOL inGuide = CanvasGuideBridge().guideStep > 0;
  CGPoint targetCanvas = CGPointZero;
  if (inGuide) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    CGPoint tgt = CanvasGuideTargetObjectPosition();
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:tgt.x
                            fromY:tgt.y
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&targetCanvas.x
                              toY:&targetCanvas.y];
  }
  [CanvasGuideBridge() ingestDrawTickWithCanvasTopRight:tr
                                             bottomLeft:bl
                                            canvasScale:spC
                                        handleCanvasPos:handleCanvasPos
                                        targetCanvasPos:targetCanvas
                                              hasTarget:inGuide];
}

// hover context: screen + canvas coords arrive together AND canvasZoom is valid
// here, so this bootstraps the bridge's canvas reference - the draw tick can't
// on its own. Mirrors MagicMove's / Rounded's OSC hover feed.
- (void)_ingestGuideHitTestAtCanvasX:(double)cx y:(double)cy {
  CGPoint tr, bl;
  if (![self _guideCanvasTopRight:&tr bottomLeft:&bl])
    return;
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 1.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC = (displayScale > 0.0) ? rawZoom / displayScale : rawZoom;
  [CanvasGuideBridge() ingestHitTestAtScreen:NSEvent.mouseLocation
                                   canvasPos:CGPointMake(cx, cy)
                                 canvasScale:spC
                                    topRight:tr
                                  bottomLeft:bl
                                    onHandle:NO
                             handleCanvasPos:CGPointZero];
}

// KKPositionGuideProvider: the Position controller reads the bridge + the
// guide-pushed value through these, staying plugin-agnostic while Canvas keeps
// its singleton bridge + sCanvasGuidePosition.
- (KKOSCGuideBridge *)positionGuideBridge {
  return CanvasGuideBridge();
}

- (CGPoint)positionGuideObjectValue {
  return sCanvasGuidePosition;
}

@end
