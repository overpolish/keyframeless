/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "OSC_Internal.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Mirrors KKOSCGuideBridge's position-notification name (the bridge posts it);
// the plugin returns this as its help-guide refresh notification.
NSNotificationName const kShaderOSCPositionNotification =
    @"co.overpolish.kk.oscGuidePosition";

// All OSC-guide affine / staleness / velocity-gate state now lives in the
// generic KKOSCGuideBridge (KeyframelessKit). One process-lifetime instance
// per XPC process - the inspector custom view and the OSC render run in the
// same process (pid confirmed identical). MRR: retained forever, no
// dispatch_once (autoreleased ObjC statics dangle under MRR).
static KKOSCGuideBridge *ShaderGuideBridge(void) {
  static KKOSCGuideBridge *sBridge = nil;
  if (!sBridge)
    sBridge = [[KKOSCGuideBridge alloc] init];
  return sBridge;
}

// Same instance, exported so the inspector guide (same XPC process) can hand
// it to a KKJoyrideOSCSegment.
KKOSCGuideBridge *ShaderSharedOSCGuideBridge(void) {
  return ShaderGuideBridge();
}

void ShaderSetOSCGuideStep(NSInteger step) {
  ShaderGuideBridge().guideStep = step;
}

BOOL ShaderHasCanvasReference(void) {
  return [ShaderGuideBridge() hasCanvasReference];
}

// Guide-scoped Origin position (object [0,1] space). The OSC can't read the
// timeline blob from the drawOSC tick (FxParameterRetrievalAPI is nil there),
// so during the OSC guide the inspector drag pushes the live position here and
// the handle tracks it - mirrors MagicMove's sGuidePosition.
static CGPoint sGuidePosition = {0.5, 0.5};

// Object-space target the interactive drag nudges the Origin handle toward
// (offset from the 0.5,0.5 seed so the move is clearly visible).
static const CGPoint kShaderGuideTargetObject = {0.7, 0.35};

void ShaderSetGuidePosition(double objX, double objY) {
  sGuidePosition = CGPointMake(objX, objY);
}

CGPoint ShaderGuideTargetObjectPosition(void) {
  return kShaderGuideTargetObject;
}

// Inverse map: a screen point → object-space Origin position via the bridge's
// cached viewer rect. Object [0,1]^2 maps to the viewer rect corners, so the
// value is the normalized position within that rect - the canvas terms cancel.
BOOL ShaderGuidePositionForScreenPoint(NSPoint screenPt, double *outX,
                                       double *outY) {
  KKOSCGuideBridge *b = ShaderGuideBridge();
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

@implementation ShaderOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
  }
  return self;
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

// No interactive elements remain (the legacy Origin/Scale/Rotation controls are
// gone). Report an empty element set so the OSC-visibility system has nothing
// to key on until shader-exposed OSCs land.
- (NSArray<NSString *> *)oscElementKeys {
  return @[];
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
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

  // Nothing to draw, but still feed the guide bridge this tick's canvas
  // geometry (zoom-invariant CANVAS->screen affine + viewer-rect recompute) so
  // ShaderHasCanvasReference and the timing guide's screen<->object map keep
  // working once it is re-pointed at future shader-exposed OSCs. The "handle"
  // is just the frame centre now (there is no Origin control to track).
  CGPoint trC = {0, 0}, blC = {0, 0};
  if (![self getCanvasTopRight:&trC bottomLeft:&blC])
    return;
  CGPoint centre = CGPointMake((trC.x + blC.x) * 0.5, (trC.y + blC.y) * 0.5);
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 0.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC =
      (rawZoom > 0.0 && displayScale > 0.0) ? rawZoom / displayScale : 0.0;
  [ShaderGuideBridge() ingestDrawTickWithCanvasTopRight:trC
                                             bottomLeft:blC
                                            canvasScale:spC
                                        handleCanvasPos:centre
                                        targetCanvasPos:CGPointZero
                                              hasTarget:NO];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0; // no interactive parts remain

  // The only place screen + canvas coords arrive together: keep feeding the
  // guide bridge (viewer-rect recompute + velocity-gated re-anchor) so the
  // timing guide's mapping survives for a future OSC.
  CGPoint tr = {0, 0}, bl = {0, 0};
  if (![self getCanvasTopRight:&tr bottomLeft:&bl])
    return;
  CGPoint centre = CGPointMake((tr.x + bl.x) * 0.5, (tr.y + bl.y) * 0.5);
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 1.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC = rawZoom / displayScale;
  [ShaderGuideBridge() ingestHitTestAtScreen:NSEvent.mouseLocation
                                   canvasPos:CGPointMake(positionX, positionY)
                                 canvasScale:spC
                                    topRight:tr
                                  bottomLeft:bl
                                    onHandle:NO
                             handleCanvasPos:centre];
}

@end
