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

// Base for the `#float/#percent/#int osc=ring` activePart numbers. Each ring
// claims ONE part (no motion path). Kept clear of the point range above.
static const NSInteger kShaderRingPartBase = 2000;

// The ring's radius encodes the scalar's value NORMALIZED to 0..1 across its
// [min,max], via the shared KKRingOSCExtentForNorm curve - so the in-viewer
// ring here and the mini-viewer's KKRingOSCSet draw at the identical size, and
// the drag inverts the same curve so the ring edge tracks the cursor 1:1.

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
  // Radius rings built from `#float/#percent/#int osc=ring` lanes, keyed on
  // lane label; `_ringOrder` fixes the label -> activePart mapping.
  // `_ringMeta`[label] = @[min, max, isInt, centerX, centerY] (center in object
  // 0..1); the ring is not lane-bound, so the drag write goes through the
  // scalar lane directly (its
  // `_ringTemplates` entry seeds the lane if the timeline lacks it yet).
  NSMutableDictionary<NSString *, KKRingOSC *> *_ringControllers;
  NSArray<NSString *> *_ringOrder;
  // Ring label -> spec dict: min/max/isInt/cx/cy/bounded (NSNumber), fields
  // (component count), linked (aspect-linkable bool).
  NSDictionary<NSString *, NSDictionary<NSString *, id> *> *_ringMeta;
  NSDictionary<NSString *, KKLane *> *_ringTemplates;
  // Ring label -> linked #point uniform name (empty = fixed `center=`). When
  // set, the ring centres on that point's live value.
  NSDictionary<NSString *, NSString *> *_ringLink;
  NSString *_ringDragLabel; // lane being dragged (nil = no ring drag)
  // Ring drag press-anchor: cursor offset from centre + component values at
  // press, so an unlinked ellipse drag holds a cardinal-grabbed axis (Glow
  // feel).
  double _ringDragStartDx, _ringDragStartDy, _ringDragStartDist;
  NSArray<NSNumber *> *_ringDragStartVals;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _posControllers = [NSMutableDictionary dictionary];
    _posOrder = @[];
    _ringControllers = [NSMutableDictionary dictionary];
    _ringOrder = @[];
    _ringMeta = @{};
    _ringTemplates = @{};
    _ringLink = @{};
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
  NSMutableArray<NSString *> *pointLabels = [NSMutableArray array];
  NSMutableArray<NSString *> *ringLabels = [NSMutableArray array];
  ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
  int nProps = 0;
  if (src.length) {
    int used = 0;
    nProps = ShaderParseScalarProps(src, props, KK_SHADER_MAX_SCALAR_PROPS, 0,
                                    &used);
    for (int i = 0; i < nProps; i++) {
      if (props[i].isPoint && strcmp(props[i].oscKind, "point") == 0)
        [pointLabels
            addObject:@(props[i].name)]; // uniform name = lane identity
      else if (strcmp(props[i].oscKind, "ring") == 0 &&
               ShaderScalarRingEligible(&props[i]))
        [ringLabels addObject:@(props[i].name)];
    }
  }
  NSString *sig = [@[
    [pointLabels componentsJoinedByString:@"\n"],
    [ringLabels componentsJoinedByString:@"\n"]
  ] componentsJoinedByString:@"\x1f"];
  if ([sig isEqualToString:_oscSig])
    return;
  _oscSig = sig;
  _posOrder = [pointLabels copy];
  _ringOrder = [ringLabels copy];
  NSArray<KKLane *> *avail =
      src.length ? [ShaderPlugin availableLanesForShaderSource:src] : @[];

  NSMutableDictionary<NSString *, KKPositionOSC *> *nextPos =
      [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < pointLabels.count; i++) {
    NSString *label = pointLabels[i];
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
    nextPos[label] = ctl;
  }
  _posControllers = nextPos;

  NSMutableDictionary<NSString *, KKRingOSC *> *nextRing =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *nextMeta =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, KKLane *> *nextTpl =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSString *> *nextLink =
      [NSMutableDictionary dictionary];
  for (int i = 0; i < nProps; i++) {
    if (!(strcmp(props[i].oscKind, "ring") == 0 &&
          ShaderScalarRingEligible(&props[i])))
      continue;
    NSString *label = @(props[i].name);
    KKRingOSC *ring =
        _ringControllers[label]
            ?: [[KKRingOSC alloc] initWithAPIManager:self.apiManager];
    ring.clearsOnDraw = NO; // draw over the points, don't wipe the tile
    nextRing[label] = ring;
    BOOL isInt = props[i].isInt || props[i].isPercent;
    int fields = props[i].isMulti
                     ? (props[i].fieldCount > 0 ? props[i].fieldCount : 2)
                     : 1;
    nextMeta[label] = @{
      @"min" : @(props[i].fmin),
      @"max" : @(props[i].fmax),
      @"isInt" : @(isInt),
      @"cx" : @(props[i].rcenterx),
      @"cy" : @(props[i].rcentery),
      @"bounded" : @(props[i].hasMax != 0),
      @"fields" : @(fields),
      @"linked" : @(props[i].aspectLinked != 0),
    };
    nextLink[label] = @(props[i].linkName);
    for (KKLane *l in avail)
      if ([l.label isEqualToString:label]) {
        nextTpl[label] = l;
        break;
      }
  }
  _ringControllers = nextRing;
  _ringMeta = nextMeta;
  _ringTemplates = nextTpl;
  _ringLink = nextLink;
}

// The ring centre in object space 0..1: the linked #point's live value when
// `link=` is set (and that point lane exists in the snapshot), else the fixed
// `center=` default.
- (CGPoint)_ringObjectCenterForLabel:(NSString *)label atFraction:(double)frac {
  NSString *link = _ringLink[label];
  if (link.length) {
    for (KKLane *l in KKProcessTimelineSnapshot().lanes)
      if ([l.label isEqualToString:link]) {
        NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(l, frac);
        if (v.count >= 2)
          return CGPointMake(v[0].doubleValue, v[1].doubleValue);
        break;
      }
  }
  NSDictionary<NSString *, id> *meta = _ringMeta[label];
  double cx = meta[@"cx"] ? [meta[@"cx"] doubleValue] : 0.5;
  double cy = meta[@"cy"] ? [meta[@"cy"] doubleValue] : 0.5;
  return CGPointMake(cx, cy);
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

// activePart -> ring lane label, or nil when the part isn't a ring.
- (nullable NSString *)ringLabelForActivePart:(NSInteger)part {
  if (part < kShaderRingPartBase)
    return nil;
  NSInteger idx = part - kShaderRingPartBase;
  if (idx < 0 || idx >= (NSInteger)_ringOrder.count)
    return nil;
  return _ringOrder[idx];
}

// The snapshot lane for a ring label, or its template (constant t=0 default)
// when the timeline hasn't materialized it yet - so the ring is grabbable and
// visible from the first frame.
- (nullable KKLane *)_ringLaneForLabel:(NSString *)label {
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:label])
      return l;
  return _ringTemplates[label];
}

// The ring lane's raw component values at `frac` (per-component defaults when
// the lane isn't materialized yet).
- (NSArray<NSNumber *> *)_ringValuesForLabel:(NSString *)label
                                  atFraction:(double)frac {
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtFraction([self _ringLaneForLabel:label], frac);
  if (v.count)
    return v;
  NSDictionary<NSString *, id> *meta = _ringMeta[label];
  double mn = meta[@"min"] ? [meta[@"min"] doubleValue] : 0.0;
  int fields = meta[@"fields"] ? [meta[@"fields"] intValue] : 1;
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (int k = 0; k < MAX(1, fields); k++)
    [out addObject:@(mn)];
  return out;
}

// Per-component normalized values ((value-min)/(refMax-min), no upper clamp so
// an unbounded field grows the ring past its nominal range).
- (NSArray<NSNumber *> *)ringNormsForLabel:(NSString *)label
                                atFraction:(double)frac {
  NSDictionary<NSString *, id> *meta = _ringMeta[label];
  double mn = [meta[@"min"] doubleValue], mx = [meta[@"max"] doubleValue];
  double span = mx - mn;
  NSArray<NSNumber *> *v = [self _ringValuesForLabel:label atFraction:frac];
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSNumber *n in v)
    [out addObject:@(span > 0.0 ? MAX(0.0, (n.doubleValue - mn) / span) : 0.0)];
  return out;
}

// Set the ring's canvas center + per-axis radii for the current value. A vec2
// #multi ring is an ellipse (rx=field0, ry=field1); a scalar ring is a circle.
- (void)_updateRing:(KKRingOSC *)ring
           forLabel:(NSString *)label
         atFraction:(double)frac {
  CGPoint oc = [self _ringObjectCenterForLabel:label atFraction:frac];
  NSArray<NSNumber *> *norms = [self ringNormsForLabel:label atFraction:frac];
  double minDim = [self canvasMinDimension];
  double nx = norms.count >= 1 ? norms[0].doubleValue : 0.0;
  double ny = norms.count >= 2 ? norms[1].doubleValue : nx;
  ring.center =
      [self canvasPointFromObjectPoint:(simd_float2){(float)oc.x, (float)oc.y}];
  ring.ringRadius = (float)KKRingOSCExtentForNorm(nx, minDim);
  ring.ringRadiusY = (float)KKRingOSCExtentForNorm(ny, minDim);
}

// Ring visibility (matches the point controllers / Glow): shown when the lane
// is a constant or the playhead is on a keypose, always mid-drag; an Opt-hidden
// ring surfaces as a dim ghost while Opt-reveal is active. `outReveal` reports
// the ghost case so the caller dims it.
- (BOOL)_ringVisible:(NSString *)label
          atFraction:(double)frac
              reveal:(BOOL *)outReveal {
  BOOL dragging = [_ringDragLabel isEqualToString:label];
  BOOL shownHere =
      dragging || KKLaneVisibleAtFraction([self _ringLaneForLabel:label], frac,
                                          KKProcessFrameDurationSeconds());
  BOOL enabled = [self kkOSCElementVisible:label];
  BOOL visible = shownHere && enabled;
  BOOL reveal = !visible && self.optRevealActive && shownHere &&
                [self kkOSCRevealEligible:label];
  if (outReveal)
    *outReveal = reveal;
  return visible;
}

// Write the ring lane's N component values into the keypose nearest the
// playhead, preserving In/Hold/Out structure. Mirrors Glow's
// _writeRadiusValues: the blob is unreadable inside the action scope, so the
// snapshot is canonical and the template seeds a first keypose if needed.
- (void)_writeRingValues:(NSArray<NSNumber *> *)values
                forLabel:(NSString *)label
                  atTime:(CMTime)time
             forceUpdate:(BOOL *)forceUpdate {
  if (!_ringMeta[label] || !values.count)
    return;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    [actionAPI endAction:self];
    return;
  }
  double frac = [self fractionAtTime:time];
  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl =
      snap ? KKTimelineSettingValuesNearestFraction(snap, label, frac, values)
           : nil;
  if (!tl) {
    // No snapshot, or the lane isn't materialized yet: seed from the template
    // (identical schema to ShaderAppendScalarLanes) with one keypose.
    tl = snap ? [snap copy] : [KKTimeline timeline];
    KKLane *seed = [_ringTemplates[label] copy] ?: [KKLane laneWithLabel:label];
    seed.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
    NSMutableArray<KKLane *> *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    [lanes addObject:seed];
    tl.lanes = lanes;
  }
  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
    *forceUpdate = YES;
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
  NSString *ringLabel = [self ringLabelForActivePart:part];
  if (ringLabel) {
    _ringDragLabel = ringLabel;
    double frac = [self fractionAtTime:time];
    CGPoint oc = [self _ringObjectCenterForLabel:ringLabel atFraction:frac];
    CGPoint center = [self
        canvasPointFromObjectPoint:(simd_float2){(float)oc.x, (float)oc.y}];
    _ringDragStartDx = x - center.x;
    _ringDragStartDy = y - center.y;
    _ringDragStartDist = hypot(_ringDragStartDx, _ringDragStartDy);
    _ringDragStartVals = [self _ringValuesForLabel:ringLabel atFraction:frac];
    [_ringControllers[ringLabel] updateCursorForMouseX:x positionY:y];
    if (forceUpdate)
      *forceUpdate = YES;
    return YES;
  }
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
  if (_ringDragLabel) {
    KKRingOSC *ring = _ringControllers[_ringDragLabel];
    NSDictionary<NSString *, id> *meta = _ringMeta[_ringDragLabel];
    CGPoint oc = [self _ringObjectCenterForLabel:_ringDragLabel
                                      atFraction:[self fractionAtTime:time]];
    CGPoint center = [self
        canvasPointFromObjectPoint:(simd_float2){(float)oc.x, (float)oc.y}];
    double dx = x - center.x, dy = y - center.y;
    double minDim = [self canvasMinDimension];
    // Effective aspect lock: the snapshot lane's persisted lock when present (a
    // user-materialized lane reflects a toggle), else the template default via
    // _ringLaneForLabel (the OSC snapshot omits un-materialized lanes, so a
    // fresh #multi falls back to the directive default). Shift inverts it for
    // the drag.
    BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
    BOOL laneLinked = [meta[@"linked"] boolValue] &&
                      [self _ringLaneForLabel:_ringDragLabel].aspectLinked;
    BOOL effLinked = [meta[@"linked"] boolValue] ? (laneLinked ^ shift) : NO;
    NSArray<NSNumber *> *newValues = KKRingOSCDragValues(
        [meta[@"fields"] intValue], effLinked,
        _ringDragStartVals.count >= 1 ? _ringDragStartVals[0].doubleValue : 0,
        _ringDragStartVals.count >= 2 ? _ringDragStartVals[1].doubleValue : 0,
        _ringDragStartDx, _ringDragStartDy, _ringDragStartDist, dx, dy, minDim,
        [meta[@"min"] doubleValue], [meta[@"max"] doubleValue],
        [meta[@"bounded"] boolValue], [meta[@"isInt"] boolValue]);
    [ring updateCursorForMouseX:x positionY:y];
    [self _writeRingValues:newValues
                  forLabel:_ringDragLabel
                    atTime:time
               forceUpdate:forceUpdate];
    return YES;
  }
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
  if (_ringDragLabel) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor arrowCursor]];
    _ringDragLabel = nil;
  }
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
  NSString *src = [self _currentShaderSource];
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  if (!src.length)
    return keys;
  // Walk the props in SOURCE order, mirroring oscCompoundsForShaderSource: so
  // the checklist states line up: a point is a handle + its "<label> Path", a
  // ring is a single hideable element.
  ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int n =
      ShaderParseScalarProps(src, props, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);
  for (int i = 0; i < n; i++) {
    NSString *label = @(props[i].name);
    if (props[i].isPoint && strcmp(props[i].oscKind, "point") == 0) {
      [keys addObject:label];
      [keys addObject:[label stringByAppendingString:@" Path"]];
    } else if (strcmp(props[i].oscKind, "ring") == 0 &&
               ShaderScalarRingEligible(&props[i])) {
      [keys addObject:label];
    }
  }
  return keys;
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  NSString *ringLabel = [self ringLabelForActivePart:activePart];
  if (ringLabel)
    return ringLabel;
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

  // Draw each `osc=ring` radius over the points. The ring is not lane-bound, so
  // set its center + radius from the scalar value each tick, then draw with the
  // shared visibility gating (Opt-hidden -> dim ghost while Opt-reveal is
  // held).
  double ringFrac = [self fractionAtTime:time];
  for (NSUInteger i = 0; i < _ringOrder.count; i++) {
    NSString *label = _ringOrder[i];
    KKRingOSC *ring = _ringControllers[label];
    BOOL reveal = NO;
    BOOL visible = [self _ringVisible:label atFraction:ringFrac reveal:&reveal];
    if (!visible && !reveal) {
      [ring clearCursorIfSet];
      continue;
    }
    [self _updateRing:ring forLabel:label atFraction:ringFrac];
    ring.ghostAlpha = reveal ? 0.6f : 1.0f;
    BOOL hovered = (activePart == kShaderRingPartBase + (NSInteger)i);
    [ring drawAtCanvasPosition:ring.center
                     isHovered:hovered
                      isActive:[_ringDragLabel isEqualToString:label]
              destinationImage:destinationImage
                        atTime:time];
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
  // Rings hit-test after the points (points win where they overlap). A ring
  // only claims when visible (or an Opt-reveal ghost); the ring sets its own
  // resize cursor on a hit.
  if (*activePart == 0) {
    double frac = [self fractionAtTime:time];
    for (NSUInteger i = 0; i < _ringOrder.count; i++) {
      NSString *label = _ringOrder[i];
      KKRingOSC *ring = _ringControllers[label];
      BOOL reveal = NO;
      BOOL visible = [self _ringVisible:label atFraction:frac reveal:&reveal];
      if (!visible && !reveal) {
        ring.visibilityHint = 0;
        [ring clearCursorIfSet];
        continue;
      }
      [self _updateRing:ring forLabel:label atFraction:frac];
      // Opt-hover hide/show affordance, only when an Opt-click would actually
      // toggle (master on, not the peek-and-use reveal): eye.slash over a
      // visible ring, eye over a revealed ghost. Mirrors GlowOSC.
      BOOL optToggle = self.optRevealActive && ![self kkOSCMasterOff];
      ring.visibilityHint = optToggle ? (visible ? 1 : 2) : 0;
      if ([ring hitTestAtMousePositionX:positionX
                              positionY:positionY
                                 atTime:time]) {
        *activePart = kShaderRingPartBase + (NSInteger)i;
        self.pointCursorSet = YES;
        break;
      }
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
