/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "OSC_Internal.h"
#import "RoundedOSCRadiusMath.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Mirrors KKOSCGuideBridge's position-notification name (the bridge posts it);
// the plugin returns this as its help-guide refresh notification.
NSNotificationName const kRoundedOSCPositionNotification =
    @"com.overpolish.kk.oscGuidePosition";

static RoundedOSC *sCurrentOSC = nil;

// All OSC-guide affine / staleness / velocity-gate state now lives in the
// generic KKOSCGuideBridge (KeyframelessKit). One process-lifetime instance
// per XPC process — the inspector custom view and the OSC render run in the
// same process (pid confirmed identical). MRR: retained forever, no
// dispatch_once (autoreleased ObjC statics dangle under MRR).
static KKOSCGuideBridge *RoundedGuideBridge(void) {
  static KKOSCGuideBridge *sBridge = nil;
  if (!sBridge)
    sBridge = [[KKOSCGuideBridge alloc] init];
  return sBridge;
}

// Same instance, exported so the inspector guide (same XPC process) can hand
// it to a KKJoyrideOSCSegment.
KKOSCGuideBridge *RoundedSharedOSCGuideBridge(void) {
  return RoundedGuideBridge();
}

// Re-anchor the bridge's screen↔canvas map by pairing a screen point with the
// OSC handle's current canvas position (the bridge supplies the live scale).
static BOOL RoundedReanchor(RoundedOSC *osc, NSPoint screenPt) {
  if (!osc)
    return NO;
  CGPoint handle = [osc oscPositionAtTime:kCMTimeZero];
  return [RoundedGuideBridge() reanchorAtScreen:screenPt
                                handleCanvasPos:handle];
}

void RoundedSetOSCGuideStep(NSInteger step) {
  RoundedGuideBridge().guideStep = step;
}

BOOL RoundedHasCanvasReference(void) {
  return [RoundedGuideBridge() hasCanvasReference];
}

void RoundedOSCCaptureGuideAnchorAtScreen(NSPoint screenPt) {
  RoundedOSC *osc = sCurrentOSC;
  if (!osc) {
    KKLogWarn(@"[OSCGuide] capture anchor skipped: no current OSC");
    return;
  }
  if (!RoundedReanchor(osc, screenPt))
    KKLogWarn(@"[OSCGuide] capture anchor skipped: no live scale yet "
              @"(drawOSC has not run)");
}

// Guide-scoped radius. The OSC cannot read the KKDataBlob from the drawOSC
// tick (FxParameterRetrievalAPI is nil there — see oscAPI2=nil in every
// drawOSC log). During the guide the blob-drag handler pushes the live radius
// here (same XPC process — pid confirmed identical) so the OSC handle tracks
// without the unreadable blob. Real (non-guide) OSC↔blob reads are Phase 10.
static double sGuideRadius = 20.0;

void RoundedSetGuideRadius(double radius) { sGuideRadius = radius; }

// Point-OSC value mapping: invert the bridge's proportional viewer-rect map
// (screen → canvas), then the OSC's own radius math, so the drag tracks the
// cursor 1:1 like a native OSC drag. Falls back to the last guide radius
// until the bridge has cached usable geometry. This is the only OSC-shape-
// specific piece left in this file; a different OSC supplies its own.
double RoundedGuideRadiusForScreenPoint(NSPoint screenPt) {
  KKOSCGuideBridge *b = RoundedGuideBridge();
  NSRect vr = b.estimatedViewerScreenRect;
  CGPoint tr = b.currentCanvasTopRight, bl = b.currentCanvasBottomLeft;
  if (!b.geometryValid || NSIsEmptyRect(vr) || fabs(tr.x - bl.x) < 1e-3 ||
      fabs(tr.y - bl.y) < 1e-3)
    return sGuideRadius;
  double oscSize = sCurrentOSC ? sCurrentOSC.oscSize : 0.0;
  double minDim = fmin(fabs(tr.x - bl.x), fabs(tr.y - bl.y));
  // Inverse of the bridge's proportional viewer-rect map: screen → canvas.
  double cx = bl.x + (screenPt.x - NSMinX(vr)) / NSWidth(vr) * (tr.x - bl.x);
  double cy = bl.y + (screenPt.y - NSMinY(vr)) / NSHeight(vr) * (tr.y - bl.y);
  // Same as mouseDraggedAtPositionX:.
  double signX = (tr.x - bl.x) < 0 ? -1.0 : 1.0;
  double signY = (tr.y - bl.y) < 0 ? -1.0 : 1.0;
  double dx = cx - tr.x, dy = cy - tr.y;
  double mouseDist = (-dx * signX + -dy * signY) * 0.5 - oscSize;
  float lo = 0.0f, hi = 100.0f;
  for (int i = 0; i < 32; i++) {
    float mid = (lo + hi) * 0.5f;
    if (paddingForRadius(mid, (float)minDim) < mouseDist)
      lo = mid;
    else
      hi = mid;
  }
  return MAX(0.0, MIN(100.0, (lo + hi) * 0.5));
}

@implementation RoundedOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _dragCurrentRadius = 20.0;
    sCurrentOSC = self;
  }
  return self;
}

- (void)dealloc {
  if (sCurrentOSC == self)
    sCurrentOSC = nil;
  [super dealloc];
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

- (CGPoint)oscPositionAtTime:(CMTime)time {
  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (![self getCanvasTopRight:&topRight bottomLeft:&bottomLeft])
    return CGPointZero;

  float canvasImageWidth = topRight.x - bottomLeft.x;
  float canvasImageHeight = topRight.y - bottomLeft.y;
  BOOL isFlippedX = canvasImageWidth < 0;
  BOOL isFlippedY = canvasImageHeight < 0;
  float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));

  double radius =
      (RoundedGuideBridge().guideStep > 0)
          ? sGuideRadius
          : (self.isDragging
                 ? _dragCurrentRadius
                 : radiusFromBlobAtFraction(self.apiManager,
                                            [self fractionAtTime:time]));
  float padding = paddingForRadius(radius, minDim);

  float offsetX =
      isFlippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
  float offsetY =
      isFlippedY ? -(self.oscSize + padding) : (self.oscSize + padding);

  return CGPointMake(topRight.x - offsetX, topRight.y - offsetY);
}

- (CGPoint)_guideTargetCanvasPosition {
  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (![self getCanvasTopRight:&topRight bottomLeft:&bottomLeft])
    return CGPointZero;
  float canvasImageWidth = topRight.x - bottomLeft.x;
  float canvasImageHeight = topRight.y - bottomLeft.y;
  BOOL isFlippedX = canvasImageWidth < 0;
  BOOL isFlippedY = canvasImageHeight < 0;
  float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));
  float padding = paddingForRadius(kOSCGuideTargetRadius, minDim);
  float offsetX =
      isFlippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
  float offsetY =
      isFlippedY ? -(self.oscSize + padding) : (self.oscSize + padding);
  return CGPointMake(topRight.x - offsetX, topRight.y - offsetY);
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

  CGPoint radiusPos = [self oscPositionAtTime:time];

  // Pull the live geometry FCP only exposes from this tick and feed it to the
  // generic bridge — it owns the zoom-invariant CANVAS→screen affine, the
  // viewer-rect recompute (never stale vs corners), and the position
  // notifications. spC=0 means "no scale this tick" (bridge keeps the last).
  CGPoint trC = {0, 0}, blC = {0, 0};
  [self getCanvasTopRight:&trC bottomLeft:&blC];
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 0.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC =
      (rawZoom > 0.0 && displayScale > 0.0) ? rawZoom / displayScale : 0.0;

  [RoundedGuideBridge()
      ingestDrawTickWithCanvasTopRight:trC
                            bottomLeft:blC
                           canvasScale:spC
                       handleCanvasPos:radiusPos
                       targetCanvasPos:[self _guideTargetCanvasPosition]
                             hasTarget:YES];

  [self drawAtCanvasPosition:radiusPos
                   isHovered:(activePart == kOSCRadiusPart)
                    isActive:self.isDragging && (activePart == kOSCRadiusPart)
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  if ([self hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    *activePart = kOSCRadiusPart;
  }
  // The only place screen + canvas coords arrive together. Hand it to the
  // bridge: it velocity-gates the sample, re-anchors the screen↔canvas map,
  // recomputes the viewer rect, and posts the position notification. The
  // handle position is only needed while a guide step is active.
  CGPoint tr = {0, 0}, bl = {0, 0};
  if (![self getCanvasTopRight:&tr bottomLeft:&bl])
    return;
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 1.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC = rawZoom / displayScale;
  CGPoint handle = CGPointZero;
  if (RoundedGuideBridge().guideStep > 0)
    handle = [self oscPositionAtTime:time];
  [RoundedGuideBridge() ingestHitTestAtScreen:NSEvent.mouseLocation
                                    canvasPos:CGPointMake(positionX, positionY)
                                  canvasScale:spC
                                     topRight:tr
                                   bottomLeft:bl
                                     onHandle:(*activePart == kOSCRadiusPart)
                              handleCanvasPos:handle];
}

@end
