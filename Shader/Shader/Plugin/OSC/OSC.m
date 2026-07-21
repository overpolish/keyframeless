/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "OSC_Internal.h"
#import "Plugin_Private.h"        // +availableLanesForShaderSource:
#import "ShaderDirectives.h"      // ShaderParseScalarProps (osc directives)
#import "ShaderOSCBlock.h"        // // @osc custom-handling blocks
#import "ShaderOSCBlockRuntime.h" // compiled block: eval / invert (shared w/ mini)
#import "ShaderOSCSnapshot.h"     // KKProcessTimelineSnapshot via the kit
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKLinkExpr.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KeyframelessKit.h>

// The three glyph handles (KKArcOSC / KKPointOSC / KKSquarePointOSC) are
// unrelated classes sharing this draw selector; a custom OSC picks one by
// `style=` and draws it at the forward-expression's canvas position.
@protocol _ShaderGlyphOSC <NSObject>
@property(nonatomic) float ghostAlpha; // dim while an Opt-reveal peek shows it
- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time;
@end

// The compiled-block spec (bound lane, forward/inverse, normalization) lives in
// the shared ShaderOSCBlockRuntime so the viewer here and the mini evaluate the
// handle identically. The viewer keeps only the glyph object per block (in
// `_exprControllers`); grab radius + hover cursor derive from the runtime's
// style / cursor name.
static double ShaderExprGrabRadius(NSString *styleName) {
  return [styleName isEqualToString:@"hollow"] ? 12.0 : 10.0;
}

// Base for `// @osc` custom-handling activePart numbers, clear of the rotate
// range (rotate order stays well under 1000, so 5000+idx never overlaps).
static const NSInteger kShaderExprPartBase = 5000;

// Base for the dynamic OSC activePart numbers. Each `#point osc` lane claims
// two consecutive parts: handle/anchor (even) and motion-path tangent (odd).
static const NSInteger kShaderOSCPartBase = 1000;

// Base for the `#float/#percent/#int osc=ring` activePart numbers. Each ring
// claims ONE part (no motion path). Kept clear of the point range above.
static const NSInteger kShaderRingPartBase = 2000;

// Base for the `osc=box` activePart numbers. A box is the ring's twin - it
// sizes through the same normalized-extent curve, but is a real KKBoxOSC (8
// handles + border + value readout) edited by dragging a handle. Each box
// claims ONE part; the grabbed handle is tracked separately. Kept clear of the
// ring range (box order stays well under 1000, so 3000+idx never overlaps).
static const NSInteger kShaderBoxPartBase = 3000;

// Cmd during a box drag = fine mode (cursor movement scaled down for precision
// at high extent), matching KKScaleOSC.
static const double kShaderBoxFineFactor = 0.2;

// Base for the `osc={..}` rotation activePart numbers. Each rotate lane claims
// ONE part (the grabbed axis is tracked inside KKRotationOSC.activeAxis); kept
// clear of the box range (box order stays well under 1000, so 4000+idx never
// overlaps). The gizmo is the shared kit KKRotationOSC (3-ring sphere), so the
// drag math / compose / persist all live in the control.
static const NSInteger kShaderRotPartBase = 4000;

// The KKRotationAxes bitmask a rotate prop drives (union of its listed x/y/z
// axes), defaulting an empty set to Z. The lane stores those components in
// canonical X<Y<Z order, matching the gizmo's contract; the braced order is a
// shader-side swizzle, not a lane order.
static KKRotationAxes ShaderRotationAxesForProp(const ShaderScalarProp *p) {
  return (KKRotationAxes)(ShaderScalarRotationAxisMask(p) ?: KKRotationAxisZ);
}

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
  // Boxes built from `osc=box` lanes, keyed on lane label; `_boxOrder` fixes
  // the label -> activePart mapping. Boxes SHARE the radial meta/template/link
  // dicts above (identical value model to a ring), differing only in control +
  // interaction. A vec2 #multi box is a rectangle; a scalar box is a square.
  NSMutableDictionary<NSString *, KKBoxOSC *> *_boxControllers;
  NSArray<NSString *> *_boxOrder;
  NSString *_boxDragLabel; // lane being dragged (nil = no box drag)
  NSInteger _boxHitHandle; // handle under the cursor at last hit-test (-1 none)
  NSInteger _boxDragHandle; // grabbed handle for the active drag
  CGPoint _boxDragCenter;   // box centre (canvas) captured at press
  CGPoint _boxDragEff;      // effective cursor (advances by raw delta * fine)
  CGPoint _boxDragLast;     // last raw cursor, for the per-tick delta
  NSArray<NSNumber *>
      *_boxDragPressNorms; // per-axis normalized values at press
  // Rotation gizmos built from `osc={..}` lanes, keyed on lane label;
  // `_rotOrder` fixes the label -> activePart mapping. Each is a self-contained
  // KKRotationOSC (reads the snapshot lane by label, owns its drag + persist
  // via kKKParamTimelineData - the same param Shader writes); Shader only sets
  // the enabled axes + canvas centre + forwards draw/hit/mouse. `_rotDragLabel`
  // is the lane being dragged (nil = no rotate drag).
  NSMutableDictionary<NSString *, KKRotationOSC *> *_rotControllers;
  NSArray<NSString *> *_rotOrder;
  NSString *_rotDragLabel;
  // Custom `// @osc` controls: a glyph handle drawn at the block's forward
  // expression, keyed by block name; `_exprOrder` fixes the block ->
  // activePart-index mapping. `_exprDragName` is the block being dragged.
  NSMutableDictionary<NSString *, id<_ShaderGlyphOSC>> *_exprControllers;
  NSMutableDictionary<NSString *, ShaderOSCBlockRuntime *> *_exprBlocks;
  NSArray<NSString *> *_exprOrder;
  NSString *_exprDragName;
  NSString *_oscBlockSig;
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
    _boxControllers = [NSMutableDictionary dictionary];
    _boxOrder = @[];
    _boxHitHandle = -1;
    _boxDragHandle = -1;
    _rotControllers = [NSMutableDictionary dictionary];
    _rotOrder = @[];
    _exprControllers = [NSMutableDictionary dictionary];
    _exprBlocks = [NSMutableDictionary dictionary];
    _exprOrder = @[];
  }
  return self;
}

// Rebuild the custom-OSC controllers to match the shader's `// @osc` blocks.
// Cheap no-op when the block set is unchanged (raw-block-text signature).
- (void)_syncOSCBlocks:(NSString *)src {
  ShaderOSCBlock blocks[KK_SHADER_MAX_OSC_BLOCKS];
  int n = src.length
              ? ShaderParseOSCBlocks(src, blocks, KK_SHADER_MAX_OSC_BLOCKS)
              : 0;
  NSMutableString *sig = [NSMutableString string];
  for (int i = 0; i < n; i++)
    [sig appendFormat:@"%s|%s|%s|%s|%s|%s\x1f", blocks[i].name,
                      blocks[i].primitive, blocks[i].binds, blocks[i].style,
                      blocks[i].forward, blocks[i].inverse];
  if ([sig isEqualToString:_oscBlockSig])
    return;
  _oscBlockSig = sig;

  // Parse + compile + normalize via the shared runtime (the mini uses the
  // same), then attach the viewer-only glyph object per block.
  NSArray<KKLane *> *avail =
      src.length ? [ShaderPlugin availableLanesForShaderSource:src] : @[];
  NSArray<ShaderOSCBlockRuntime *> *runtimes =
      [ShaderOSCBlockRuntime runtimesForSource:src lanes:avail];

  NSMutableDictionary<NSString *, id<_ShaderGlyphOSC>> *nextCtl =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, ShaderOSCBlockRuntime *> *nextBlk =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *order = [NSMutableArray array];

  for (ShaderOSCBlockRuntime *b in runtimes) {
    // Glyph by style: hollow -> the small radius-widget ring (matching
    // Rounded/Canvas), square -> square, else dot.
    id<_ShaderGlyphOSC> glyph;
    if ([b.styleName isEqualToString:@"hollow"]) {
      KKRingOSC *g = [[KKRingOSC alloc] initWithAPIManager:self.apiManager];
      [g applyRadiusWidgetStyle];
      // Solid white always: parity with the mini (which has no hover), and the
      // dim idle grey reads unclear for a small radius handle.
      g.solidStyle = YES;
      glyph = (id<_ShaderGlyphOSC>)g;
    } else if ([b.styleName isEqualToString:@"square"]) {
      glyph = (id<_ShaderGlyphOSC>)[[KKSquarePointOSC alloc]
          initWithAPIManager:self.apiManager];
    } else {
      glyph = (id<_ShaderGlyphOSC>)[[KKPointOSC alloc]
          initWithAPIManager:self.apiManager];
    }
    nextCtl[b.name] = glyph;
    nextBlk[b.name] = b;
    [order addObject:b.name];
  }
  _exprControllers = nextCtl;
  _exprBlocks = nextBlk;
  _exprOrder = [order copy];
}

// KKPositionGuideProvider: the point controllers read the guide state through
// these, so they stay plugin-agnostic while Shader keeps its singleton bridge +
// the guide-pushed position.
- (KKOSCGuideBridge *)positionGuideBridge {
  return ShaderGuideBridge();
}

- (CGPoint)positionGuideObjectValue {
  return sGuidePosition;
}

// The live shader source from the process timeline snapshot (blob reads are
// flaky in the OSC tick; the snapshot is canonical).
- (nullable NSString *)_currentShaderSource {
  BOOL hasShaderLane = NO;
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:@"Shader"]) {
      hasShaderLane = YES;
      if (l.codeString.length)
        return l.codeString;
    }
  // An ABSENT Shader lane is a fresh instance whose timeline blob hasn't been
  // persisted yet: the render seeds the default (Plasma) source, so the OSC has
  // to as well, or a fresh Plasma draws NO handles (its `#point`/`osc=ring`
  // controls never build) - which is exactly what starves the timing guide's
  // OSC step. A PRESENT-but-empty lane means the user cleared the code
  // (passthrough), so it correctly has no controls. Mirrors ShaderStateBlob's
  // absent-vs-empty rule on the render side.
  return hasShaderLane ? nil : ShaderCustomDefaultShaderSource();
}

// Rebuild the position controllers to match the shader's `#point osc` lanes.
// Cheap no-op when the lane set is unchanged (signature compare).
- (void)_syncOSCControllers {
  NSString *src = [self _currentShaderSource];
  [self _syncOSCBlocks:src]; // custom `// @osc` controls (own signature)
  NSMutableArray<NSString *> *pointLabels = [NSMutableArray array];
  NSMutableArray<NSString *> *ringLabels = [NSMutableArray array];
  NSMutableArray<NSString *> *boxLabels = [NSMutableArray array];
  NSMutableArray<NSString *> *rotLabels = [NSMutableArray array];
  // The rotate signature carries each lane's axis SET, so editing `osc={z}` ->
  // `osc={y}` (same uniform, different axis) changes the signature and forces a
  // rebuild - the label alone is unchanged and would look stale.
  NSMutableArray<NSString *> *rotSig = [NSMutableArray array];
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
      else if (ShaderScalarOSCIsRotate(&props[i])) {
        [rotLabels addObject:@(props[i].name)];
        // Axis set + centre + link all feed the gizmo, so an edit to any of
        // them must change the signature and force a rebuild.
        [rotSig addObject:[NSString stringWithFormat:@"%s=%s|%.4f,%.4f|%s",
                                                     props[i].name,
                                                     props[i].oscAxes,
                                                     props[i].rcenterx,
                                                     props[i].rcentery,
                                                     props[i].linkName]];
      } else if (!ShaderScalarRingEligible(&props[i]))
        continue;
      else if (strcmp(props[i].oscKind, "ring") == 0)
        [ringLabels addObject:@(props[i].name)];
      else if (ShaderScalarOSCIsBox(&props[i]))
        [boxLabels addObject:@(props[i].name)];
    }
  }
  NSString *sig = [@[
    [pointLabels componentsJoinedByString:@"\n"],
    [ringLabels componentsJoinedByString:@"\n"],
    [boxLabels componentsJoinedByString:@"\n"],
    [rotSig componentsJoinedByString:@"\n"]
  ] componentsJoinedByString:@"\x1f"];
  if ([sig isEqualToString:_oscSig])
    return;
  _oscSig = sig;
  _posOrder = [pointLabels copy];
  _ringOrder = [ringLabels copy];
  _boxOrder = [boxLabels copy];
  _rotOrder = [rotLabels copy];
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
    // So a running timing guide draws this handle at the guide-pushed position
    // (see -positionGuideObjectValue). Set on every point controller: the guide
    // teaches one primary point, and the bridge's guideStep gates it, so the
    // rest read their real lane value normally.
    ctl.guideProvider = self;
    for (KKLane *l in avail)
      if ([l.label isEqualToString:label]) {
        ctl.templateLane = l;
        break;
      }
    nextPos[label] = ctl;
  }
  _posControllers = nextPos;

  // Rings and boxes share the SAME radial meta (identical value model); only
  // the control + interaction differ. Build both in one pass over the radial
  // props, routing each to its controller dict.
  NSMutableDictionary<NSString *, KKRingOSC *> *nextRing =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, KKBoxOSC *> *nextBox =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *nextMeta =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, KKLane *> *nextTpl =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSString *> *nextLink =
      [NSMutableDictionary dictionary];
  for (int i = 0; i < nProps; i++) {
    if (!ShaderScalarRingEligible(&props[i]))
      continue;
    BOOL isRing = strcmp(props[i].oscKind, "ring") == 0;
    BOOL isBox = ShaderScalarOSCIsBox(&props[i]);
    if (!isRing && !isBox)
      continue;
    NSString *label = @(props[i].name);
    BOOL isInt = props[i].isInt || props[i].isPercent;
    int fields = props[i].isMulti
                     ? (props[i].fieldCount > 0 ? props[i].fieldCount : 2)
                     : 1;
    nextMeta[label] = @{
      @"min" : @(props[i].fmin),
      @"max" : @(props[i].fmax),
      @"isInt" : @(isInt),
      @"isPercent" : @(props[i].isPercent != 0),
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
    if (isRing) {
      KKRingOSC *ring =
          _ringControllers[label]
              ?: [[KKRingOSC alloc] initWithAPIManager:self.apiManager];
      ring.clearsOnDraw = NO; // draw over the points, don't wipe the tile
      nextRing[label] = ring;
    } else {
      KKBoxOSC *box =
          _boxControllers[label]
              ?: [[KKBoxOSC alloc] initWithAPIManager:self.apiManager];
      box.hitPadding = 6.0; // forgiving handle grab, like the scale box
      nextBox[label] = box;
    }
  }
  _ringControllers = nextRing;
  _boxControllers = nextBox;
  _ringTemplates = nextTpl;

  // Rotation gizmos: one self-contained KKRotationOSC per `osc={..}` lane, with
  // its enabled axes from the braced set and its template from availableLanes.
  // It reads/writes the snapshot lane (canonical X/Y/Z components) itself, so
  // Shader only sets enabledAxes/templateLane/activePart and forwards events.
  // The rotate gizmo's centre reuses the radial `center=`/`link=` machinery, so
  // its cx/cy + link go into the shared `_ringMeta`/`_ringLink` dicts (its
  // label never overlaps a ring/box label).
  NSMutableDictionary<NSString *, KKRotationOSC *> *nextRot =
      [NSMutableDictionary dictionary];
  for (int i = 0; i < nProps; i++) {
    if (!ShaderScalarOSCIsRotate(&props[i]))
      continue;
    NSString *label = @(props[i].name);
    KKRotationOSC *rot =
        _rotControllers[label]
            ?: [[KKRotationOSC alloc] initWithAPIManager:self.apiManager
                                               laneLabel:label];
    rot.clearsOnDraw = NO; // draw over the other controls, don't wipe the tile
    rot.enabledAxes = ShaderRotationAxesForProp(&props[i]);
    for (KKLane *l in avail)
      if ([l.label isEqualToString:label]) {
        rot.templateLane = l;
        break;
      }
    nextMeta[label] =
        @{@"cx" : @(props[i].rcenterx), @"cy" : @(props[i].rcentery)};
    nextLink[label] = @(props[i].linkName);
    nextRot[label] = rot;
  }
  _rotControllers = nextRot;
  _ringMeta = nextMeta;
  _ringLink = nextLink;
}

// activePart -> rotation lane label, or nil when the part isn't a rotate gizmo.
- (nullable NSString *)rotLabelForActivePart:(NSInteger)part {
  if (part < kShaderRotPartBase)
    return nil;
  NSInteger idx = part - kShaderRotPartBase;
  if (idx < 0 || idx >= (NSInteger)_rotOrder.count)
    return nil;
  return _rotOrder[idx];
}

// The rotation gizmo's canvas centre for a label: its `center=` object point
// (or the `link=`ed #point's live value), via the shared radial-centre helper,
// so several rotation gizmos can sit at distinct points instead of stacking.
- (CGPoint)_rotationCenterForLabel:(NSString *)label atFraction:(double)frac {
  CGPoint oc = [self _ringObjectCenterForLabel:label atFraction:frac];
  return
      [self canvasPointFromObjectPoint:(simd_float2){(float)oc.x, (float)oc.y}];
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

// activePart -> box lane label, or nil when the part isn't a box.
- (nullable NSString *)boxLabelForActivePart:(NSInteger)part {
  if (part < kShaderBoxPartBase)
    return nil;
  NSInteger idx = part - kShaderBoxPartBase;
  if (idx < 0 || idx >= (NSInteger)_boxOrder.count)
    return nil;
  return _boxOrder[idx];
}

// The box's canvas centre + two opposite corners for the current value. A box
// is centred (symmetric, no anchor) on the same object point a ring would use,
// with half-extents from the SAME normalized-extent curve - so a box and a ring
// for the same field are the same size. A vec2 #multi box is a rectangle
// (halfW=field0, halfH=field1); a scalar box is a square.
- (CGPoint)_boxGeometryForLabel:(NSString *)label
                     atFraction:(double)frac
                       topRight:(CGPoint *)outTR
                     bottomLeft:(CGPoint *)outBL {
  CGPoint oc = [self _ringObjectCenterForLabel:label atFraction:frac];
  CGPoint c =
      [self canvasPointFromObjectPoint:(simd_float2){(float)oc.x, (float)oc.y}];
  NSArray<NSNumber *> *norms = [self ringNormsForLabel:label atFraction:frac];
  double minDim = [self canvasMinDimension];
  double nx = norms.count >= 1 ? norms[0].doubleValue : 0.0;
  double ny = norms.count >= 2 ? norms[1].doubleValue : nx;
  double hw = KKRingOSCExtentForNorm(nx, minDim);
  double hh = KKRingOSCExtentForNorm(ny, minDim);
  if (outTR)
    *outTR = CGPointMake(c.x + hw, c.y + hh);
  if (outBL)
    *outBL = CGPointMake(c.x - hw, c.y - hh);
  return c;
}

// "X" / "X x Y" readout of the box's raw value(s), formatted by field type: a
// percent shows "%", an integer a whole number, a float a trimmed decimal.
- (NSString *)_boxReadoutForLabel:(NSString *)label atFraction:(double)frac {
  NSDictionary<NSString *, id> *meta = _ringMeta[label];
  return KKBoxOSCReadoutString([self _ringValuesForLabel:label atFraction:frac],
                               [meta[@"isPercent"] boolValue],
                               [meta[@"isInt"] boolValue]);
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

// --- Custom `// @osc` controls --------------------------------------------

// The bound lane for a block: the snapshot lane, else its template (default
// keypose) so the handle is drawable / grabbable before the lane materializes.
- (nullable KKLane *)_exprLaneForBlock:(ShaderOSCBlockRuntime *)b {
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:b.binds])
      return l;
  return b.templateLane;
}

// The bound value in EXPR units (the shader's, post-directive-normalization: a
// percent lane's 0..100 -> 0..1). One vector, `fieldCount` components.
- (KKExprVal)_exprValueForBlock:(ShaderOSCBlockRuntime *)b
                     atFraction:(double)frac {
  return [b boundValueFromLaneValues:KKTimelineLaneValueAtFraction(
                                         [self _exprLaneForBlock:b], frac)];
}

// The viewer's aspect (canvas width / height), fed to the runtime so its
// object-space geometry is aspect-corrected the same way the mini's is.
- (double)_exprAspect {
  CGPoint tr = CGPointZero, bl = CGPointZero;
  if ([self getCanvasTopRight:&tr bottomLeft:&bl]) {
    double w = fabs(tr.x - bl.x), h = fabs(tr.y - bl.y);
    if (h > 0.0)
      return w / h;
  }
  return 1.0;
}

// Canvas position of the block's handle for a given bound value (forward expr
// -> object -> canvas).
- (CGPoint)_exprCanvasForBlock:(ShaderOSCBlockRuntime *)b value:(KKExprVal)v {
  simd_float2 p = [b objectPointForBound:v
                                  aspect:[self _exprAspect]
                                   mouse:(simd_float2){0, 0}
                               haveMouse:NO];
  return [self canvasPointFromObjectPoint:p];
}

// The handle position at the current (lane) value.
- (CGPoint)_exprHandleCanvasForBlock:(ShaderOSCBlockRuntime *)b
                          atFraction:(double)frac {
  return [self _exprCanvasForBlock:b
                             value:[self _exprValueForBlock:b atFraction:frac]];
}

// Custom `// @osc` handle visibility (mirrors _ringVisible:): shown when the
// bound lane is a constant or the playhead is on a keypose, always mid-drag; an
// Opt-hidden handle surfaces as a dim ghost while Opt-reveal is active. The
// block's `name` is its OSC-checklist element key (see oscElementKeys).
- (BOOL)_exprVisible:(ShaderOSCBlockRuntime *)b
          atFraction:(double)frac
              reveal:(BOOL *)outReveal {
  BOOL dragging = [_exprDragName isEqualToString:b.name];
  BOOL shownHere =
      dragging || KKLaneVisibleAtFraction([self _exprLaneForBlock:b], frac,
                                          KKProcessFrameDurationSeconds());
  BOOL enabled = [self kkOSCElementVisible:b.name];
  BOOL visible = shownHere && enabled;
  BOOL reveal = !visible && self.optRevealActive && shownHere &&
                [self kkOSCRevealEligible:b.name];
  if (outReveal)
    *outReveal = reveal;
  return visible;
}

// The new bound value for a drag to `mouseCanvas`: the explicit inverse if one
// was authored, else a numeric inversion of the forward (searches the value
// whose forward-position is nearest the cursor, like Rounded's binary search).
// Both run in the runtime's object space, so the mouse converts to object
// first.
- (KKExprVal)_exprBoundForBlock:(ShaderOSCBlockRuntime *)b
                    mouseCanvas:(CGPoint)m
                     atFraction:(double)frac {
  simd_float2 om = [self objectPointFromCanvasPoint:m];
  double aspect = [self _exprAspect];
  if (b.hasInverse) {
    KKExprVal boundNow = [self _exprValueForBlock:b atFraction:frac];
    return [b inverseBoundForObjectMouse:om boundNow:boundNow aspect:aspect];
  }
  return [b invertBoundForObjectPoint:om aspect:aspect];
}

// Write a block's new bound value (EXPR units) back to its lane: denormalize to
// lane units, clamp, set the keypose nearest the playhead in an action scope
// (seed from the template when the lane isn't materialized). Mirrors
// _writeRingValues without the ring meta.
- (void)_writeExprValue:(KKExprVal)val
               forBlock:(ShaderOSCBlockRuntime *)b
                 atTime:(CMTime)time
            forceUpdate:(BOOL *)forceUpdate {
  NSArray<NSNumber *> *values = [b laneValuesFromBound:val];
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
      snap ? KKTimelineSettingValuesNearestFraction(snap, b.binds, frac, values)
           : nil;
  if (!tl) {
    tl = snap ? [snap copy] : [KKTimeline timeline];
    KKLane *seed = [b.templateLane copy] ?: [KKLane laneWithLabel:b.binds];
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
  NSString *boxLabel = [self boxLabelForActivePart:part];
  if (boxLabel) {
    _boxDragLabel = boxLabel;
    _boxDragHandle = _boxHitHandle;
    double frac = [self fractionAtTime:time];
    CGPoint tr = CGPointZero, bl = CGPointZero;
    _boxDragCenter = [self _boxGeometryForLabel:boxLabel
                                     atFraction:frac
                                       topRight:&tr
                                     bottomLeft:&bl];
    _boxDragPressNorms = [self ringNormsForLabel:boxLabel atFraction:frac];
    // Effective cursor starts at the grabbed handle so the value begins exactly
    // where it is (no press snap); the drag advances it by the raw delta.
    _boxDragEff = (_boxDragHandle >= 0 && _boxDragHandle < KKBoxHandleCount)
                      ? [KKBoxOSC handlePositionForIndex:_boxDragHandle
                                                topRight:tr
                                              bottomLeft:bl]
                      : CGPointMake(x, y);
    _boxDragLast = CGPointMake(x, y);
    if (forceUpdate)
      *forceUpdate = YES;
    return YES;
  }
  NSString *rotLabel = [self rotLabelForActivePart:part];
  if (rotLabel) {
    _rotDragLabel = rotLabel;
    KKRotationOSC *rot = _rotControllers[rotLabel];
    rot.center = [self _rotationCenterForLabel:rotLabel
                                    atFraction:[self fractionAtTime:time]];
    // mouseDown reads the axis captured by the preceding hitTest + the press
    // pose; the control owns the compose + persist.
    [rot mouseDownAtX:x
                    y:y
            modifiers:modifiers
          forceUpdate:forceUpdate
               atTime:time];
    return YES;
  }
  if (part >= kShaderExprPartBase) {
    NSInteger idx = part - kShaderExprPartBase;
    if (idx >= 0 && idx < (NSInteger)_exprOrder.count) {
      _exprDragName = _exprOrder[idx];
      if (forceUpdate)
        *forceUpdate = YES;
      return YES;
    }
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
  if (_boxDragLabel) {
    NSDictionary<NSString *, id> *meta = _ringMeta[_boxDragLabel];
    // Advance the effective cursor by the raw movement (scaled down for
    // Cmd-fine); the candidate per-axis norm is its distance to the box centre
    // through the shared curve, so the grabbed handle tracks the cursor 1:1.
    double rawDx = x - _boxDragLast.x, rawDy = y - _boxDragLast.y;
    _boxDragLast = CGPointMake(x, y);
    double fine =
        (modifiers & kFxModifierKey_COMMAND) ? kShaderBoxFineFactor : 1.0;
    _boxDragEff.x += rawDx * fine;
    _boxDragEff.y += rawDy * fine;
    double minDim = [self canvasMinDimension];
    double candNX =
        KKRingOSCNormForExtent(fabs(_boxDragEff.x - _boxDragCenter.x), minDim);
    double candNY =
        KKRingOSCNormForExtent(fabs(_boxDragEff.y - _boxDragCenter.y), minDim);
    double pNX =
        _boxDragPressNorms.count >= 1 ? _boxDragPressNorms[0].doubleValue : 0;
    double pNY =
        _boxDragPressNorms.count >= 2 ? _boxDragPressNorms[1].doubleValue : pNX;
    BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
    BOOL laneLinked = [meta[@"linked"] boolValue] &&
                      [self _ringLaneForLabel:_boxDragLabel].aspectLinked;
    BOOL effLinked = [meta[@"linked"] boolValue] ? (laneLinked ^ shift) : NO;
    NSArray<NSNumber *> *newValues = KKBoxOSCDragValues(
        _boxDragHandle, [meta[@"fields"] intValue], effLinked, pNX, pNY, candNX,
        candNY, [meta[@"min"] doubleValue], [meta[@"max"] doubleValue],
        [meta[@"bounded"] boolValue], [meta[@"isInt"] boolValue]);
    [self _writeRingValues:newValues
                  forLabel:_boxDragLabel
                    atTime:time
               forceUpdate:forceUpdate];
    return YES;
  }
  if (_rotDragLabel) {
    KKRotationOSC *rot = _rotControllers[_rotDragLabel];
    rot.center = [self _rotationCenterForLabel:_rotDragLabel
                                    atFraction:[self fractionAtTime:time]];
    [rot mouseDraggedAtX:x
                       y:y
               modifiers:modifiers
             forceUpdate:forceUpdate
                  atTime:time];
    return YES;
  }
  if (_exprDragName) {
    ShaderOSCBlockRuntime *b = _exprBlocks[_exprDragName];
    double frac = [self fractionAtTime:time];
    KKExprVal nv = [self _exprBoundForBlock:b
                                mouseCanvas:CGPointMake(x, y)
                                 atFraction:frac];
    NSCursor *cur = ShaderOSCCursorForName(b.cursorName);
    if (cur) {
      id<FxOnScreenControlAPI_v4> curAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      [curAPI setCursor:cur];
    }
    [self _writeExprValue:nv forBlock:b atTime:time forceUpdate:forceUpdate];
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
  if (_boxDragLabel) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor arrowCursor]];
    _boxControllers[_boxDragLabel].hoveredIndex = -1;
    _boxDragLabel = nil;
    _boxDragHandle = -1;
  }
  if (_rotDragLabel) {
    [_rotControllers[_rotDragLabel] mouseUp];
    _rotDragLabel = nil;
  }
  if (_exprDragName) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor arrowCursor]];
    _exprDragName = nil;
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
    } else if (ShaderScalarOSCIsRotate(&props[i])) {
      // A rotation gizmo: a master element + one per-axis ring, each hideable
      // apart (matching Canvas/MagicMove's Rotation + Rotation.X/Y/Z).
      [keys addObject:label];
      KKRotationAxes axes = ShaderRotationAxesForProp(&props[i]);
      if (axes & KKRotationAxisX)
        [keys addObject:[label stringByAppendingString:@".X"]];
      if (axes & KKRotationAxisY)
        [keys addObject:[label stringByAppendingString:@".Y"]];
      if (axes & KKRotationAxisZ)
        [keys addObject:[label stringByAppendingString:@".Z"]];
    } else if (ShaderScalarRingEligible(&props[i]) &&
               (strcmp(props[i].oscKind, "ring") == 0 ||
                ShaderScalarOSCIsBox(&props[i]))) {
      [keys addObject:label];
    }
  }
  // Custom `// @osc` handles are single hideable elements, keyed by block name.
  for (NSString *name in _exprOrder)
    [keys addObject:name];
  return keys;
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart >= kShaderExprPartBase) {
    NSInteger idx = activePart - kShaderExprPartBase;
    if (idx >= 0 && idx < (NSInteger)_exprOrder.count)
      return _exprOrder[idx];
  }
  NSString *ringLabel = [self ringLabelForActivePart:activePart];
  if (ringLabel)
    return ringLabel;
  NSString *boxLabel = [self boxLabelForActivePart:activePart];
  if (boxLabel)
    return boxLabel;
  NSString *rotLabel = [self rotLabelForActivePart:activePart];
  if (rotLabel) {
    // Opt-click the ring under the cursor: the controller's last-hit-test axis
    // (0=X/1=Y/2=Z) picks the per-axis element so a single ring hides; fall
    // back to the master when no ring is active.
    NSInteger axis = _rotControllers[rotLabel].activeAxis;
    NSString *suffix = axis == 0   ? @".X"
                       : axis == 1 ? @".Y"
                       : axis == 2 ? @".Z"
                                   : nil;
    return suffix ? [rotLabel stringByAppendingString:suffix] : rotLabel;
  }
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

  [self _syncOSCControllers];
  double ringFrac = [self fractionAtTime:time];

  // Draw each `osc={..}` rotation gizmo (KKRotationOSC 3-ring sphere) FIRST, so
  // the small position handle + rings/boxes stay on top (and grabbable) -
  // matching the mini-viewer's layering. It reads its own pose + ring colours
  // from the snapshot lane and gates per-axis visibility (master + .X/.Y/.Z +
  // opt-reveal) internally; Shader just sets the canvas centre + drag/reveal.
  for (NSUInteger i = 0; i < _rotOrder.count; i++) {
    NSString *label = _rotOrder[i];
    KKRotationOSC *rot = _rotControllers[label];
    rot.center = [self _rotationCenterForLabel:label atFraction:ringFrac];
    rot.rotationActivePart = kShaderRotPartBase + (NSInteger)i;
    rot.dragging = self.isDragging;
    rot.optRevealActive = self.optRevealActive;
    [rot drawInDestination:destinationImage atTime:time activePart:activePart];
  }

  // Draw each shader-declared position handle: motion path (under) then the
  // playhead arc handle (over). The controllers read the process snapshot for
  // their value and manage their own coordinate conversion.
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
    ring.ghostAlpha = reveal ? MAX(0.6f, [self kkRevealGhostAlpha]) : 1.0f;
    BOOL hovered = (activePart == kShaderRingPartBase + (NSInteger)i);
    [ring drawAtCanvasPosition:ring.center
                     isHovered:hovered
                      isActive:[_ringDragLabel isEqualToString:label]
              destinationImage:destinationImage
                        atTime:time];
  }

  // Draw each `osc=box` gizmo (real KKBoxOSC: border + 8 handles + a value
  // readout), sized through the same normalized-extent curve as the rings, with
  // the same visibility gating (Opt-hidden -> dim ghost while Opt-reveal held).
  for (NSUInteger i = 0; i < _boxOrder.count; i++) {
    NSString *label = _boxOrder[i];
    KKBoxOSC *box = _boxControllers[label];
    BOOL reveal = NO;
    BOOL visible = [self _ringVisible:label atFraction:ringFrac reveal:&reveal];
    if (!visible && !reveal)
      continue;
    CGPoint tr = CGPointZero, bl = CGPointZero;
    [self _boxGeometryForLabel:label
                    atFraction:ringFrac
                      topRight:&tr
                    bottomLeft:&bl];
    box.ghostAlpha = reveal ? MAX(0.6f, [self kkRevealGhostAlpha]) : 1.0f;
    NSInteger activeHandle =
        [_boxDragLabel isEqualToString:label] ? _boxDragHandle : -1;
    [box drawWithTopRight:tr
               bottomLeft:bl
                  readout:[self _boxReadoutForLabel:label atFraction:ringFrac]
             activeHandle:activeHandle
         destinationImage:destinationImage
                   atTime:time];
  }

  // Draw each custom `// @osc` handle at its forward-expression position,
  // under the same visibility gating (Opt-hidden -> dim ghost while Opt-reveal
  // is held) as the rings/boxes.
  for (NSUInteger i = 0; i < _exprOrder.count; i++) {
    NSString *name = _exprOrder[i];
    ShaderOSCBlockRuntime *b = _exprBlocks[name];
    BOOL reveal = NO;
    if (![self _exprVisible:b atFraction:ringFrac reveal:&reveal] && !reveal)
      continue;
    id<_ShaderGlyphOSC> glyph = _exprControllers[name];
    glyph.ghostAlpha = reveal ? MAX(0.6f, [self kkRevealGhostAlpha]) : 1.0f;
    CGPoint c = [self _exprHandleCanvasForBlock:b atFraction:ringFrac];
    [glyph
        drawAtCanvasPosition:c
                   isHovered:(activePart == kShaderExprPartBase + (NSInteger)i)
                    isActive:[_exprDragName isEqualToString:name]
            destinationImage:destinationImage
                      atTime:time];
  }

  // Feed the guide bridge this tick's canvas geometry (zoom-invariant
  // CANVAS->screen affine + viewer-rect recompute) so ShaderHasCanvasReference
  // and the timing guide's screen<->object map keep working. During a guide,
  // the "handle" is the guide-pushed Center (object->canvas) and the "target"
  // its drag destination, so the spotlight tracks the taught handle and its
  // glowing goal - not the frame centre. Outside a guide the handle is just the
  // frame centre (the bridge only needs the viewer geometry then).
  CGPoint trC = {0, 0}, blC = {0, 0};
  if (![self getCanvasTopRight:&trC bottomLeft:&blC])
    return;
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 0.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC =
      (rawZoom > 0.0 && displayScale > 0.0) ? rawZoom / displayScale : 0.0;

  BOOL inGuide = ShaderGuideBridge().guideStep > 0;
  // The primary point handle's canvas position, fed ALWAYS (not only during the
  // guide) so the spotlight sits on the handle from the moment the OSC step
  // opens - not just once the drag starts. The controller is guide-aware: with
  // our guideProvider set, it returns the guide-pushed value while guideStep>0
  // and its real lane value otherwise, so the spotlight and the drawn handle
  // always coincide. Frame centre only when the shader declares no point.
  CGPoint handleCanvas =
      CGPointMake((trC.x + blC.x) * 0.5, (trC.y + blC.y) * 0.5);
  KKPositionOSC *primaryPoint =
      _posOrder.count ? _posControllers[_posOrder.firstObject] : nil;
  if (primaryPoint)
    handleCanvas = [primaryPoint positionCanvasAtTime:time];
  // The drag destination the guide nudges toward, shown as the glowing target.
  CGPoint targetCanvas = CGPointZero;
  if (inGuide) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    CGPoint tgt = kShaderGuideTargetObject;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:tgt.x
                            fromY:tgt.y
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&targetCanvas.x
                              toY:&targetCanvas.y];
  }
  [ShaderGuideBridge() ingestDrawTickWithCanvasTopRight:trC
                                             bottomLeft:blC
                                            canvasScale:spC
                                        handleCanvasPos:handleCanvas
                                        targetCanvasPos:targetCanvas
                                              hasTarget:inGuide];

  // Diagnostic for the OSC-guide spotlight: fires only while a guide runs.
  // handleScreen empty / off means the bridge couldn't map the handle to the
  // viewer (geometry), so the spotlight can't land on it. Remove once
  // confirmed.
  if (inGuide) {
    NSRect hs = ShaderGuideBridge().estimatedHandleScreenRect;
    KKLogDebug(
        @"[GuideOSC] step=%ld pts=%lu handleCanvas=(%.1f,%.1f) "
        @"tr=(%.1f,%.1f) bl=(%.1f,%.1f) handleScreen=(%.0f,%.0f %.0fx%.0f)",
        (long)ShaderGuideBridge().guideStep, (unsigned long)_posOrder.count,
        handleCanvas.x, handleCanvas.y, trC.x, trC.y, blC.x, blC.y, NSMinX(hs),
        NSMinY(hs), NSWidth(hs), NSHeight(hs));
  }
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
  // Boxes hit-test after the rings (same precedence). Only a handle hit claims
  // (interior clicks pass through); KKBoxOSC sets its own resize / eye cursor.
  if (*activePart == 0) {
    double frac = [self fractionAtTime:time];
    for (NSUInteger i = 0; i < _boxOrder.count; i++) {
      NSString *label = _boxOrder[i];
      KKBoxOSC *box = _boxControllers[label];
      BOOL reveal = NO;
      BOOL visible = [self _ringVisible:label atFraction:frac reveal:&reveal];
      if (!visible && !reveal) {
        box.visibilityHint = 0;
        continue;
      }
      BOOL optToggle = self.optRevealActive && ![self kkOSCMasterOff];
      box.visibilityHint = optToggle ? (visible ? 1 : 2) : 0;
      CGPoint tr = CGPointZero, bl = CGPointZero;
      [self _boxGeometryForLabel:label
                      atFraction:frac
                        topRight:&tr
                      bottomLeft:&bl];
      NSInteger part = [box hitTestAtX:positionX
                                     y:positionY
                              topRight:tr
                            bottomLeft:bl];
      if (part >= KKBoxPartHandleBase) {
        _boxHitHandle = part - KKBoxPartHandleBase;
        *activePart = kShaderBoxPartBase + (NSInteger)i;
        self.pointCursorSet = YES;
        break;
      }
    }
  }
  // Rotation rings hit-test last (points/rings/boxes win where they overlap).
  // KKRotationOSC returns the active axis (0/1/2) or -1 and sets its own rotate
  // / visibility cursor; the gizmo owns per-axis visibility gating.
  if (*activePart == 0) {
    double rotFrac = [self fractionAtTime:time];
    for (NSUInteger i = 0; i < _rotOrder.count; i++) {
      NSString *label = _rotOrder[i];
      KKRotationOSC *rot = _rotControllers[label];
      rot.center = [self _rotationCenterForLabel:label atFraction:rotFrac];
      rot.rotationActivePart = kShaderRotPartBase + (NSInteger)i;
      rot.optRevealActive = self.optRevealActive;
      if ([rot hitTestRingAtX:positionX y:positionY atTime:time] >= 0) {
        *activePart = kShaderRotPartBase + (NSInteger)i;
        self.pointCursorSet = YES;
        break;
      }
    }
  }
  // Custom `// @osc` handles hit-test last: distance from the cursor to the
  // handle's forward-expression position, within the glyph's grab radius.
  if (*activePart == 0) {
    double frac = [self fractionAtTime:time];
    for (NSUInteger i = 0; i < _exprOrder.count; i++) {
      NSString *name = _exprOrder[i];
      ShaderOSCBlockRuntime *b = _exprBlocks[name];
      BOOL reveal = NO;
      if (![self _exprVisible:b atFraction:frac reveal:&reveal] && !reveal)
        continue;
      CGPoint c = [self _exprHandleCanvasForBlock:b atFraction:frac];
      if (hypot(positionX - c.x, positionY - c.y) <=
          ShaderExprGrabRadius(b.styleName)) {
        *activePart = kShaderExprPartBase + (NSInteger)i;
        // Opt-hover shows the eye (hide) / eye-slash cursor over a toggleable
        // handle; otherwise the block's own drag cursor.
        NSCursor *cur = [self kkVisibilityCursorForLabel:name]
                            ?: ShaderOSCCursorForName(b.cursorName);
        if (cur) {
          id<FxOnScreenControlAPI_v4> curAPI = [self.apiManager
              apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
          [curAPI setCursor:cur];
        }
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
