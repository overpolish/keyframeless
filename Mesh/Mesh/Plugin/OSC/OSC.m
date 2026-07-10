/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "MeshOSCRadiusMath.h"
#import "OSC_Internal.h"
#import "Plugin_Private.h" // +[MeshPlugin availableLanes] (Origin template lane)
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Mirrors KKOSCGuideBridge's position-notification name (the bridge posts it);
// the plugin returns this as its help-guide refresh notification.
NSNotificationName const kMeshOSCPositionNotification =
    @"co.overpolish.kk.oscGuidePosition";

static MeshOSC *sCurrentOSC = nil;

// All OSC-guide affine / staleness / velocity-gate state now lives in the
// generic KKOSCGuideBridge (KeyframelessKit). One process-lifetime instance
// per XPC process - the inspector custom view and the OSC render run in the
// same process (pid confirmed identical). MRR: retained forever, no
// dispatch_once (autoreleased ObjC statics dangle under MRR).
static KKOSCGuideBridge *MeshGuideBridge(void) {
  static KKOSCGuideBridge *sBridge = nil;
  if (!sBridge)
    sBridge = [[KKOSCGuideBridge alloc] init];
  return sBridge;
}

// Same instance, exported so the inspector guide (same XPC process) can hand
// it to a KKJoyrideOSCSegment.
KKOSCGuideBridge *MeshSharedOSCGuideBridge(void) { return MeshGuideBridge(); }

// Re-anchor the bridge's screen↔canvas map by pairing a screen point with the
// OSC handle's current canvas position (the bridge supplies the live scale).
static BOOL MeshReanchor(MeshOSC *osc, NSPoint screenPt) {
  if (!osc)
    return NO;
  CGPoint handle = [osc oscPositionAtTime:kCMTimeZero];
  return [MeshGuideBridge() reanchorAtScreen:screenPt handleCanvasPos:handle];
}

void MeshSetOSCGuideStep(NSInteger step) { MeshGuideBridge().guideStep = step; }

BOOL MeshHasCanvasReference(void) {
  return [MeshGuideBridge() hasCanvasReference];
}

void MeshOSCCaptureGuideAnchorAtScreen(NSPoint screenPt) {
  MeshOSC *osc = sCurrentOSC;
  if (!osc) {
    KKLogWarn(@"[OSCGuide] capture anchor skipped: no current OSC");
    return;
  }
  if (!MeshReanchor(osc, screenPt))
    KKLogWarn(@"[OSCGuide] capture anchor skipped: no live scale yet "
              @"(drawOSC has not run)");
}

// Guide-scoped value push (legacy radius-guide plumbing; kept so the inspector
// timing guide keeps compiling until it is reworked onto the Origin handle).
static double sGuideRadius = 20.0;

void MeshSetGuideRadius(double radius) { sGuideRadius = radius; }

double MeshGuideRadiusForScreenPoint(NSPoint screenPt) {
  KKOSCGuideBridge *b = MeshGuideBridge();
  NSRect vr = b.estimatedViewerScreenRect;
  CGPoint tr = b.currentCanvasTopRight, bl = b.currentCanvasBottomLeft;
  if (!b.geometryValid || NSIsEmptyRect(vr) || fabs(tr.x - bl.x) < 1e-3 ||
      fabs(tr.y - bl.y) < 1e-3)
    return sGuideRadius;
  double oscSize = sCurrentOSC ? sCurrentOSC.oscSize : 0.0;
  double minDim = fmin(fabs(tr.x - bl.x), fabs(tr.y - bl.y));
  double cx = bl.x + (screenPt.x - NSMinX(vr)) / NSWidth(vr) * (tr.x - bl.x);
  double cy = bl.y + (screenPt.y - NSMinY(vr)) / NSHeight(vr) * (tr.y - bl.y);
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

@implementation MeshOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    // The Origin handle + motion path are the reusable Position control, keyed
    // on the "Origin" lane. MeshOSC stays the single FxPlug control and
    // forwards draw / hit-test / mouse to it.
    _originController = [[KKPositionOSC alloc] initWithAPIManager:apiManager
                                                        laneLabel:@"Origin"
                                                        pathLabel:@"Path"];
    _originController.positionActivePart = kOSCPositionPart;
    _originController.tangentActivePart = kOSCPathHandlePart;
    // The Scale transform box is the reusable KKScaleOSC, keyed on the "Scale"
    // lane. It centres on the Origin pivot and scales symmetrically (no anchor
    // lane), matching the shader's about-the-Origin zoom.
    _scaleControl = [[KKScaleOSC alloc] initWithAPIManager:apiManager
                                                 laneLabel:@"Scale"];
    _scaleControl.scaleActivePart = kOSCScalePart;
    _scaleControl.anchorLaneLabel = nil;
    // Rotation ring gizmo, Z axis only (2D pattern), keyed on the 1-component
    // "Rotation" lane.
    _rotationControl = [[KKRotationOSC alloc] initWithAPIManager:apiManager
                                                       laneLabel:@"Rotation"];
    _rotationControl.rotationActivePart = kOSCRotationPart;
    _rotationControl.enabledAxes = KKRotationAxisZ;
    for (KKLane *l in [MeshPlugin availableLanes]) {
      if ([l.label isEqualToString:@"Origin"])
        _originController.templateLane = l;
      if ([l.label isEqualToString:@"Scale"])
        _scaleControl.templateLane = l;
      if ([l.label isEqualToString:@"Rotation"])
        _rotationControl.templateLane = l;
    }
    sCurrentOSC = self;
  }
  return self;
}

- (void)dealloc {
  if (sCurrentOSC == self)
    sCurrentOSC = nil;
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

// The Origin handle's canvas position, owned by the Position controller. The
// guide bridge (and any centring control) reads this.
- (CGPoint)oscPositionAtTime:(CMTime)time {
  return [self.originController positionCanvasAtTime:time];
}

// The on-screen frame's min side in canvas units, sizing the Scale gizmo. The
// object rect [0,1]x[0,1] maps to canvas at bottom-left / top-right.
- (double)onScreenFrameMin {
  CGPoint tr = {0, 0}, bl = {0, 0};
  if (![self getCanvasTopRight:&tr bottomLeft:&bl])
    return 0.0;
  return fmin(fabs(tr.x - bl.x), fabs(tr.y - bl.y));
}

- (NSArray<NSString *> *)oscElementKeys {
  return @[ @"Origin", @"Path", @"Scale", @"Rotation" ];
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart == kOSCPositionPart)
    return @"Origin";
  if (activePart == kOSCPathHandlePart)
    return @"Path";
  if (activePart == kOSCScalePart)
    return @"Scale";
  if (activePart == kOSCRotationPart)
    return @"Rotation";
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

  // Feed the guide bridge this tick's live geometry (zoom-invariant CANVAS->
  // screen affine, viewer-rect recompute, position notifications). spC=0 means
  // "no scale this tick" (bridge keeps the last).
  CGPoint handlePos = [self oscPositionAtTime:time];
  CGPoint trC = {0, 0}, blC = {0, 0};
  [self getCanvasTopRight:&trC bottomLeft:&blC];
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 0.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC =
      (rawZoom > 0.0 && displayScale > 0.0) ? rawZoom / displayScale : 0.0;
  [MeshGuideBridge() ingestDrawTickWithCanvasTopRight:trC
                                           bottomLeft:blC
                                          canvasScale:spC
                                      handleCanvasPos:handlePos
                                      targetCanvasPos:handlePos
                                            hasTarget:YES];

  // The Origin handle + motion path are owned by the Position controller.
  // Mirror our FxPlug drag / opt-reveal state, then draw the path FIRST (under)
  // and the arc handle LAST (over). The controller owns its own visibility
  // gating (constant -> handle only; animated -> keypose anchor dots + path).
  self.originController.dragging = self.isDragging;
  self.originController.optRevealActive = self.optRevealActive;
  [self.originController drawPathInDestination:destinationImage
                                        atTime:time
                                    activePart:activePart];
  // The Scale box centres on the Origin pivot; draw it under the arc handle so
  // the arc stays easy to grab.
  self.scaleControl.center = handlePos;
  self.scaleControl.frameMin = [self onScreenFrameMin];
  self.scaleControl.dragging = self.isDragging;
  self.scaleControl.optRevealActive = self.optRevealActive;
  [self.scaleControl drawInDestination:destinationImage
                                atTime:time
                            activePart:activePart];
  // The Rotation ring gizmo, also centred on the Origin pivot.
  self.rotationControl.center = handlePos;
  self.rotationControl.dragging = self.isDragging;
  self.rotationControl.optRevealActive = self.optRevealActive;
  [self.rotationControl drawInDestination:destinationImage
                                   atTime:time
                               activePart:activePart];
  [self.originController drawHandleInDestination:destinationImage
                                          atTime:time
                                      activePart:activePart];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  // The Position controller owns the tangent > arc > anchor-dot precedence and
  // sets the move/eye cursor on a hit; map its result to our activePart.
  self.originController.optRevealActive = self.optRevealActive;
  KKPositionHit ph = [self.originController hitTestAtX:positionX
                                                     y:positionY
                                                atTime:time];
  if (ph != KKPositionHitNone)
    *activePart = (ph == KKPositionHitTangentHandle) ? kOSCPathHandlePart
                                                     : kOSCPositionPart;

  // The Origin handle wins over the gizmos; only hit them when the Origin
  // controller didn't claim the point. Scale box before the rotation ring.
  if (*activePart == 0) {
    self.scaleControl.center = [self oscPositionAtTime:time];
    self.scaleControl.frameMin = [self onScreenFrameMin];
    self.scaleControl.optRevealActive = self.optRevealActive;
    if ([self.scaleControl hitTestHandleAtX:positionX
                                          y:positionY
                                     atTime:time] >= 0)
      *activePart = kOSCScalePart;
  }
  if (*activePart == 0) {
    self.rotationControl.center = [self oscPositionAtTime:time];
    self.rotationControl.optRevealActive = self.optRevealActive;
    if ([self.rotationControl hitTestRingAtX:positionX
                                           y:positionY
                                      atTime:time] >= 0)
      *activePart = kOSCRotationPart;
  }

  // Motion-only full-preview Opt-reveal fallback (shared kit machinery): claims
  // a background part when nothing real was hit so the OPTION modifier keeps
  // being reported on hover over empty canvas, and clears any stale eye cursor.
  *activePart = [self kkOSCBackgroundPartFallbackForActivePart:*activePart];

  // The only place screen + canvas coords arrive together: feed the guide
  // bridge (velocity-gated re-anchor + viewer-rect recompute + position
  // notification).
  CGPoint tr = {0, 0}, bl = {0, 0};
  if (![self getCanvasTopRight:&tr bottomLeft:&bl])
    return;
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 1.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC = rawZoom / displayScale;
  CGPoint handle = CGPointZero;
  if (MeshGuideBridge().guideStep > 0)
    handle = [self oscPositionAtTime:time];
  [MeshGuideBridge() ingestHitTestAtScreen:NSEvent.mouseLocation
                                 canvasPos:CGPointMake(positionX, positionY)
                               canvasScale:spC
                                  topRight:tr
                                bottomLeft:bl
                                  onHandle:(*activePart == kOSCPositionPart)
                           handleCanvasPos:handle];
}

@end
