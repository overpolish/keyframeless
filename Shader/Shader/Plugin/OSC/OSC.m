/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "OSC_Internal.h"
#import "Plugin_Private.h"    // +availableLanesForShaderSource:
#import "ShaderColorSpace.h"  // ShaderParseScalarProps (osc directives)
#import "ShaderOSCSnapshot.h" // KKProcessTimelineSnapshot via the kit
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Base for the dynamic OSC activePart numbers. Each `#point osc` lane claims
// two consecutive parts: handle/anchor (even) and motion-path tangent (odd).
static const NSInteger kShaderOSCPartBase = 1000;

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

@implementation ShaderOSC {
  // Position handles built from the shader's `#point osc` lanes, keyed on lane
  // label; rebuilt when the set of osc lanes changes. `_posOrder` fixes the
  // label -> activePart-index mapping.
  NSMutableDictionary<NSString *, KKPositionOSC *> *_posControllers;
  NSArray<NSString *> *_posOrder;
  NSString *_oscSig; // signature of the current osc-lane set (rebuild trigger)
  // Active position drag (preserved across mouseDown -> mouseDragged so the
  // grabbed anchor-dot vs playhead-handle hit stays consistent).
  KKPositionOSC *_dragController;
  KKPositionHit _dragHit;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _posControllers = [NSMutableDictionary dictionary];
    _posOrder = @[];
  }
  return self;
}

// The live shader source from the process timeline snapshot (blob reads are
// flaky in the OSC tick; the snapshot is canonical).
- (nullable NSString *)_currentShaderSource {
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:@"Shader"] && l.codeString.length)
      return l.codeString;
  return nil;
}

// Rebuild the position controllers to match the shader's `#point osc` lanes.
// Cheap no-op when the lane set is unchanged (signature compare).
- (void)_syncOSCControllers {
  NSString *src = [self _currentShaderSource];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  if (src.length) {
    ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
    int used = 0;
    int n = ShaderParseScalarProps(src, props, KK_SHADER_MAX_SCALAR_PROPS, 0,
                                   &used);
    for (int i = 0; i < n; i++)
      if (props[i].isPoint && strcmp(props[i].oscKind, "point") == 0)
        [labels addObject:@(props[i].name)]; // uniform name = lane identity
  }
  NSString *sig = [labels componentsJoinedByString:@"\n"];
  if ([sig isEqualToString:_oscSig])
    return;
  _oscSig = sig;
  _posOrder = [labels copy];
  NSArray<KKLane *> *avail =
      src.length ? [ShaderPlugin availableLanesForShaderSource:src] : @[];
  NSMutableDictionary<NSString *, KKPositionOSC *> *next =
      [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < labels.count; i++) {
    NSString *label = labels[i];
    KKPositionOSC *ctl =
        _posControllers[label]
            ?: [[KKPositionOSC alloc]
                   initWithAPIManager:self.apiManager
                            laneLabel:label
                            pathLabel:[label stringByAppendingString:@" Path"]];
    ctl.positionActivePart = kShaderOSCPartBase + (NSInteger)i * 2;
    ctl.tangentActivePart = kShaderOSCPartBase + (NSInteger)i * 2 + 1;
    for (KKLane *l in avail)
      if ([l.label isEqualToString:label]) {
        ctl.templateLane = l;
        break;
      }
    next[label] = ctl;
  }
  _posControllers = next;
}

// activePart -> its position controller (and whether it's the path/tangent
// half). Used by the mouse handlers to route a drag.
- (nullable KKPositionOSC *)controllerForActivePart:(NSInteger)part
                                             isPath:(BOOL *)outPath {
  if (part < kShaderOSCPartBase)
    return nil;
  NSInteger idx = (part - kShaderOSCPartBase) / 2;
  if (idx < 0 || idx >= (NSInteger)_posOrder.count)
    return nil;
  if (outPath)
    *outPath = ((part - kShaderOSCPartBase) & 1) != 0;
  return _posControllers[_posOrder[idx]];
}

// --- Mouse routing (called from the +MouseHandlers category) ---------------
// A position drag starts here so `_dragHit`/`_dragController` persist for the
// subsequent mouseDragged ticks. Returns YES when a controller claimed it.
- (BOOL)oscMouseDownAtX:(double)x
                      y:(double)y
             activePart:(NSInteger)part
              modifiers:(NSUInteger)modifiers
            forceUpdate:(BOOL *)forceUpdate
                 atTime:(CMTime)time {
  BOOL isPath = NO;
  KKPositionOSC *c = [self controllerForActivePart:part isPath:&isPath];
  if (!c)
    return NO;
  KKPositionHit hit = isPath ? KKPositionHitTangentHandle
                             : (c.hoverTargetIsAnchor ? KKPositionHitAnchorDot
                                                      : KKPositionHitHandle);
  _dragController = c;
  _dragHit = hit;
  [c mouseDownAtX:x
                y:y
              hit:hit
        modifiers:modifiers
      forceUpdate:forceUpdate
           atTime:time];
  return YES;
}

- (BOOL)oscMouseDraggedAtX:(double)x
                         y:(double)y
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  if (!_dragController)
    return NO;
  [_dragController mouseDraggedAtX:x
                                 y:y
                               hit:_dragHit
                         modifiers:modifiers
                       forceUpdate:forceUpdate
                            atTime:time];
  return YES;
}

- (void)oscMouseUp {
  for (NSString *label in _posOrder)
    [_posControllers[label] mouseUp];
  _dragController = nil;
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

// Each `#point osc` lane is TWO hideable OSC elements: its handle (keyed on the
// lane/uniform label) and its motion path ("<label> Path"), toggleable apart -
// matching MagicMove's separate Position + Path. Order must mirror
// oscCompoundsForShaderSource: (handle then path, per lane) so the checklist
// states line up.
- (NSArray<NSString *> *)oscElementKeys {
  [self _syncOSCControllers];
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  for (NSString *label in _posOrder) {
    [keys addObject:label];
    [keys addObject:[label stringByAppendingString:@" Path"]];
  }
  return keys;
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  BOOL isPath = NO;
  KKPositionOSC *c = [self controllerForActivePart:activePart isPath:&isPath];
  if (!c)
    return nil;
  // The hit-test only tags a TANGENT handle with tangentActivePart; a keypose
  // ANCHOR (the common path click) comes back as positionActivePart, so also
  // treat a hover on an anchor as the PATH element - matching MagicMove's
  // `hoverTargetIsAnchor ? Path : Position`. Otherwise opt-clicking the path
  // toggled the handle instead.
  BOOL onPath = isPath || c.hoverTargetIsAnchor;
  return onPath ? c.pathLabel : c.laneLabel;
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

  // Draw each shader-declared position handle: motion path (under) then the
  // playhead arc handle (over). The controllers read the process snapshot for
  // their value and manage their own coordinate conversion.
  [self _syncOSCControllers];
  for (NSString *label in _posOrder) {
    KKPositionOSC *c = _posControllers[label];
    c.dragging = self.isDragging;
    c.optRevealActive = self.optRevealActive;
    [c drawPathInDestination:destinationImage
                      atTime:time
                  activePart:activePart];
    [c drawHandleInDestination:destinationImage
                        atTime:time
                    activePart:activePart];
  }

  // Feed the guide bridge this tick's canvas
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
  *activePart = 0;

  // Reset a cursor a control forced last hover; the hit branch re-sets it, so
  // moving off a handle (incl. after an opt-click) restores the arrow.
  if (self.pointCursorSet) {
    id<FxOnScreenControlAPI_v4> resetAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [resetAPI setCursor:[NSCursor arrowCursor]];
    self.pointCursorSet = NO;
  }

  // Hit-test each position handle (tangent > arc > anchor-dot precedence lives
  // in the controller). First hit wins and sets the cursor.
  [self _syncOSCControllers];
  for (NSString *label in _posOrder) {
    KKPositionOSC *c = _posControllers[label];
    c.optRevealActive = self.optRevealActive;
    KKPositionHit ph = [c hitTestAtX:positionX y:positionY atTime:time];
    if (ph != KKPositionHitNone) {
      *activePart = (ph == KKPositionHitTangentHandle) ? c.tangentActivePart
                                                       : c.positionActivePart;
      self.pointCursorSet = YES;
      break;
    }
  }
  // Motion full-preview fallback: claim a background part over empty canvas so
  // OPTION keeps being reported on hover (no-op in FCP).
  *activePart = [self kkOSCBackgroundPartFallbackForActivePart:*activePart];

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
