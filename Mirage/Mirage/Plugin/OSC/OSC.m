/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "OSC_Internal.h"
#import "Plugin_Private.h"        // +availableLanesForShaderSource:
#import "MirageDirectives.h"      // MirageParseScalarProps (osc directives)
#import "MirageOSCBlock.h"        // // @osc custom-handling blocks
#import "MirageOSCBlockRuntime.h" // compiled block: eval / invert (shared w/ mini)
#import "MirageOSCSnapshot.h"     // KKProcessTimelineSnapshot via the kit
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKLinkExpr.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSnapEngine.h>
#import <KeyframelessKit/KeyframelessKit.h>

// The three glyph handles (KKArcOSC / KKPointOSC / KKSquarePointOSC) are
// unrelated classes sharing this draw selector; a custom OSC picks one by
// `style=` and draws it at the forward-expression's canvas position.
@protocol _MirageGlyphOSC <NSObject>
@property(nonatomic) float ghostAlpha; // dim while an Opt-reveal peek shows it
- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time;
@end

// The compiled-block spec (bound lane, forward/inverse, normalization) lives in
// the shared MirageOSCBlockRuntime so the viewer here and the mini evaluate the
// handle identically. The viewer keeps only the glyph object per block (in
// `_exprControllers`); grab radius + hover cursor derive from the runtime's
// style / cursor name.
static double MirageExprGrabRadius(NSString *styleName) {
  return [styleName isEqualToString:@"hollow"] ? 12.0 : 10.0;
}

// Base for `// @osc` custom-handling activePart numbers, clear of the rotate
// range (rotate order stays well under 1000, so 5000+idx never overlaps).
static const NSInteger kMirageExprPartBase = 5000;

// Base for the dynamic OSC activePart numbers. Each `#point osc` lane claims
// two consecutive parts: handle/anchor (even) and motion-path tangent (odd).
static const NSInteger kMirageOSCPartBase = 1000;

// The axis mask for a rotate block's `axes = x y z` subset (default Z).
static KKRotationAxes MirageExprRotationAxes(NSString *axes) {
  KKRotationAxes m = 0;
  NSString *lower = axes.lowercaseString;
  if ([lower containsString:@"x"])
    m |= KKRotationAxisX;
  if ([lower containsString:@"y"])
    m |= KKRotationAxisY;
  if ([lower containsString:@"z"])
    m |= KKRotationAxisZ;
  return m ?: KKRotationAxisZ;
}

// A rotate block's OSC element keys: the gizmo gates on its LANE label (master
// + per-axis suffixes), so the keys come from binds, in canonical X<Y<Z order.
static NSArray<NSString *> *MirageExprRotateElementKeys(NSString *binds,
                                                        NSString *axes) {
  NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObject:binds];
  KKRotationAxes m = MirageExprRotationAxes(axes);
  if (m & KKRotationAxisX)
    [keys addObject:[binds stringByAppendingString:@".X"]];
  if (m & KKRotationAxisY)
    [keys addObject:[binds stringByAppendingString:@".Y"]];
  if (m & KKRotationAxisZ)
    [keys addObject:[binds stringByAppendingString:@".Z"]];
  return keys;
}

// The ring's radius encodes the scalar's value NORMALIZED to 0..1 across its
// [min,max], via the shared KKRingOSCExtentForNorm curve - so the in-viewer
// ring here and the mini-viewer's KKRingOSCSet draw at the identical size, and
// the drag inverts the same curve so the ring edge tracks the cursor 1:1.

// Mirrors KKOSCGuideBridge's position-notification name (the bridge posts it);
// the plugin returns this as its help-guide refresh notification.
NSNotificationName const kMirageOSCPositionNotification =
    @"co.overpolish.kk.oscGuidePosition";

// All OSC-guide affine / staleness / velocity-gate state now lives in the
// generic KKOSCGuideBridge (KeyframelessKit). One process-lifetime instance
// per XPC process - the inspector custom view and the OSC render run in the
// same process (pid confirmed identical). MRR: retained forever, no
// dispatch_once (autoreleased ObjC statics dangle under MRR).
static KKOSCGuideBridge *MirageGuideBridge(void) {
  static KKOSCGuideBridge *sBridge = nil;
  if (!sBridge)
    sBridge = [[KKOSCGuideBridge alloc] init];
  return sBridge;
}

// Same instance, exported so the inspector guide (same XPC process) can hand
// it to a KKJoyrideOSCSegment.
KKOSCGuideBridge *MirageSharedOSCGuideBridge(void) {
  return MirageGuideBridge();
}

void MirageSetOSCGuideStep(NSInteger step) {
  MirageGuideBridge().guideStep = step;
}

BOOL MirageHasCanvasReference(void) {
  return [MirageGuideBridge() hasCanvasReference];
}

// Guide-scoped Origin position (object [0,1] space). The OSC can't read the
// timeline blob from the drawOSC tick (FxParameterRetrievalAPI is nil there),
// so during the OSC guide the inspector drag pushes the live position here and
// the handle tracks it - mirrors MagicMove's sGuidePosition.
static CGPoint sGuidePosition = {0.5, 0.5};

// Object-space target the interactive drag nudges the Origin handle toward
// (offset from the 0.5,0.5 seed so the move is clearly visible).
static const CGPoint kMirageGuideTargetObject = {0.7, 0.35};

void MirageSetGuidePosition(double objX, double objY) {
  sGuidePosition = CGPointMake(objX, objY);
}

CGPoint MirageGuideTargetObjectPosition(void) {
  return kMirageGuideTargetObject;
}

// Inverse map: a screen point → object-space Origin position via the bridge's
// cached viewer rect. Object [0,1]^2 maps to the viewer rect corners, so the
// value is the normalized position within that rect - the canvas terms cancel.
BOOL MirageGuidePositionForScreenPoint(NSPoint screenPt, double *outX,
                                       double *outY) {
  KKOSCGuideBridge *b = MirageGuideBridge();
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

@implementation MirageOSC {
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
  // Custom `// @osc` controls: one control per block (a glyph handle for
  // `point`, a KKRingOSC for `ring`), keyed by block name; `_exprOrder` fixes
  // the block -> activePart-index mapping. `_exprDragName` is the block being
  // dragged; the press-state pair drives the ring primitive's default drag.
  NSMutableDictionary<NSString *, id> *_exprControllers;
  NSMutableDictionary<NSString *, MirageOSCBlockRuntime *> *_exprBlocks;
  NSArray<NSString *> *_exprOrder;
  // EVERY runtime (including position-style blocks, which live outside the
  // expr-part namespace), in checklist order, for the element keys.
  NSArray<MirageOSCBlockRuntime *> *_allRuntimes;
  NSString *_exprDragName;
  NSString *_oscBlockSig;
  // Template lanes by label for the runtimes' laneValueProvider (a referenced
  // uniform that hasn't materialized yet reads its directive default), and the
  // fraction of the CURRENT tick (the provider has no fraction argument).
  NSDictionary<NSString *, KKLane *> *_exprAvailLanes;
  double _exprTickFrac;
  KKExprVal _exprDragPressBound; // bound value at mouse-down
  simd_float2 _exprDragPressOff; // cursor - centre at mouse-down (fractions)
  NSInteger _exprBoxHitPart;     // KKCropPart under the cursor at last hit-test
  NSInteger _exprBoxDragPart;    // grabbed KKCropPart for the active box drag
  // Centred-box drag state (`body = none`): the effective cursor starts AT the
  // grabbed handle (no press snap) and advances by the raw delta, scaled down
  // while Cmd is held (fine mode, matching KKScaleOSC).
  CGPoint _exprBoxDragEff, _exprBoxDragLast;
  // Diagnostic for the FCP "FFUIAction beginWithUndoState" abort-on-quit: a
  // nested startAction (a write re-entering while another action is open)
  // would assert in the host. Remove once the crash source is confirmed.
  int _exprActionDepth;
  // Cmd-held snap for point handles (parity with KKPositionOSC): snaps the
  // dragged handle onto the canvas centre / edges / quarters and the other
  // point/position handles, drawing guides. Live only during an active point
  // drag whose block didn't opt out via `skipsnapping`.
  KKSnapEngine *_exprSnap;
  BOOL
      _exprSnapActive; // the current point drag snapped this tick (draw guides)
}

// Cmd during a centred-box drag = fine mode (cursor movement scaled down for
// precision at high extent), matching KKScaleOSC.
static const double kMirageExprBoxFineFactor = 0.2;

// Handle classification for KKBoxOSC's canonical index order (0-3 corners
// BL/BR/TR/TL, 4-7 edges bottom/right/top/left).
static BOOL MirageExprBoxHandleIsCorner(NSInteger idx) { return idx < 4; }
static BOOL MirageExprBoxHandleControlsX(NSInteger idx) {
  return idx < 4 || idx == 5 || idx == 7;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _posControllers = [NSMutableDictionary dictionary];
    _posOrder = @[];
    _exprControllers = [NSMutableDictionary dictionary];
    _exprBlocks = [NSMutableDictionary dictionary];
    _exprOrder = @[];
    _exprSnap = [[KKSnapEngine alloc] init];
    _exprBoxHitPart = KKCropPartNone;
    _exprBoxDragPart = KKCropPartNone;
  }
  return self;
}

// Rebuild the custom-OSC controllers to match the shader's `// @osc` blocks.
// Cheap no-op when the block set is unchanged (raw-block-text signature).
- (void)_syncOSCBlocks:(NSString *)src {
  // The runtimes now include the DIRECTIVE SUGAR (osc=ring/box/{..}/point
  // synthesized as standard blocks), so any source edit can change them; the
  // whole source is the signature (same cheap compare the mini uses).
  NSString *sig = src ?: @"";
  if ([sig isEqualToString:_oscBlockSig])
    return;
  _oscBlockSig = [sig copy];

  // Parse + compile + normalize via the shared runtime (the mini uses the
  // same), then attach the viewer-only control object per block.
  NSArray<KKLane *> *avail =
      src.length ? [MiragePlugin availableLanesForShaderSource:src] : @[];
  NSMutableDictionary<NSString *, KKLane *> *availByLabel =
      [NSMutableDictionary dictionary];
  for (KKLane *l in avail)
    if (l.label.length)
      availByLabel[l.label] = l;
  _exprAvailLanes = [availByLabel copy];
  NSArray<MirageOSCBlockRuntime *> *runtimes =
      [MirageOSCBlockRuntime runtimesForSource:src lanes:avail];

  NSMutableDictionary<NSString *, id> *nextCtl =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, MirageOSCBlockRuntime *> *nextBlk =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *order = [NSMutableArray array];

  _allRuntimes = runtimes;
  __weak MirageOSC *weakSelf = self;

  // Position-style point blocks (the `#point osc` sugar) get the full
  // KKPositionOSC backing - motion path + tangents + playhead handle - in
  // their own two-part namespace, exactly as before the sugar conversion.
  NSMutableDictionary<NSString *, KKPositionOSC *> *nextPos =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *posOrder = [NSMutableArray array];
  for (MirageOSCBlockRuntime *b in runtimes) {
    if (![b.primitive isEqualToString:@"position"])
      continue;
    NSString *label = b.binds;
    KKPositionOSC *ctl =
        _posControllers[label]
            ?: [[KKPositionOSC alloc]
                   initWithAPIManager:self.apiManager
                            laneLabel:label
                            pathLabel:[label stringByAppendingString:@" Path"]];
    ctl.positionActivePart = kMirageOSCPartBase + (NSInteger)posOrder.count * 2;
    ctl.tangentActivePart =
        kMirageOSCPartBase + (NSInteger)posOrder.count * 2 + 1;
    // So a running timing guide draws this handle at the guide-pushed position
    // (see -positionGuideObjectValue). Set on every point controller: the
    // guide teaches one primary point, and the bridge's guideStep gates it, so
    // the rest read their real lane value normally.
    ctl.guideProvider = self;
    ctl.templateLane = b.templateLane;
    ctl.snapDisabled = !b.snaps; // `skipsnapping` on the position sugar/block
    nextPos[label] = ctl;
    [posOrder addObject:label];
  }
  _posControllers = nextPos;
  _posOrder = [posOrder copy];

  for (MirageOSCBlockRuntime *b in runtimes) {
    // A referenced uniform (center = uOrigin, …) reads the snapshot lane at
    // the current tick's fraction, falling back to its directive default.
    b.laneValueProvider = ^NSArray<NSNumber *> *(NSString *label) {
      return [weakSelf _exprRawLaneValuesForLabel:label];
    };
    b.laneValuesAtFractionProvider =
        ^NSArray<NSNumber *> *(NSString *label, double frac) {
      return [weakSelf _exprRawLaneValuesForLabel:label atFraction:frac];
    };
    if ([b.primitive isEqualToString:@"position"])
      continue; // backed by _posControllers above, not an expr part
    id ctl;
    if ([b.primitive isEqualToString:@"ring"]) {
      // A value-sized radius ring, drawn at the block's centre with its `toR`
      // radii - the same control the inline `osc=ring` path uses.
      KKRingOSC *ring =
          [_exprControllers[b.name] isKindOfClass:KKRingOSC.class] &&
                  ![(KKRingOSC *)_exprControllers[b.name] solidStyle]
              ? _exprControllers[b.name]
              : [[KKRingOSC alloc] initWithAPIManager:self.apiManager];
      ring.clearsOnDraw = NO; // draw over the points, don't wipe the tile
      ctl = ring;
    } else if ([b.primitive isEqualToString:@"rotate"]) {
      // Placement-only: the self-contained 3-ring gizmo reads/persists its
      // lane itself; the block supplies binds + axes + the centre expression.
      KKRotationOSC *rot =
          [_exprControllers[b.name] isKindOfClass:KKRotationOSC.class]
              ? _exprControllers[b.name]
              : [[KKRotationOSC alloc] initWithAPIManager:self.apiManager
                                                laneLabel:b.binds];
      rot.laneLabel = b.binds;
      rot.clearsOnDraw = NO; // draw over the other controls
      rot.enabledAxes = MirageExprRotationAxes(b.axes);
      rot.templateLane = b.templateLane;
      ctl = rot;
    } else if ([b.primitive isEqualToString:@"box"]) {
      // The crop scaffold: border + 8 anchored-resize handles + body-move + a
      // px readout (how Rounded drives its crop). The block's toRect/fromRect
      // bijection bridges its bound value to the scaffold's [w,h,x,y] model.
      KKCropOSC *crop =
          [_exprControllers[b.name] isKindOfClass:KKCropOSC.class]
              ? _exprControllers[b.name]
              : [[KKCropOSC alloc] initWithAPIManager:self.apiManager];
      crop.hitPadding = 6.0; // forgiving handle grab, like the scale box
      MirageOSCBlockRuntime *blk = b;
      crop.valuesProvider = ^NSArray<NSNumber *> *(CMTime t) {
        __strong MirageOSC *s = weakSelf;
        if (!s)
          return nil;
        double frac = [s fractionAtTime:t];
        s->_exprTickFrac = frac;
        KKExprVal bound = [s _exprValueForBlock:blk atFraction:frac];
        return [MirageOSCBlockRuntime
            cropModelFromRect:[blk boxRectForBound:bound
                                            aspect:[s _exprAspect]]];
      };
      crop.valuesWriter = ^(NSArray<NSNumber *> *values, CMTime t) {
        __strong MirageOSC *s = weakSelf;
        if (!s)
          return;
        double frac = [s fractionAtTime:t];
        s->_exprTickFrac = frac;
        KKExprVal rect = [MirageOSCBlockRuntime rectFromCropModel:values];
        KKExprVal nv = [blk boxBoundForRect:rect
                                   boundNow:[s _exprValueForBlock:blk
                                                       atFraction:frac]
                                     aspect:[s _exprAspect]];
        [s _writeExprValue:nv forBlock:blk atTime:t forceUpdate:NULL];
      };
      ctl = crop;
    } else if ([b.styleName isEqualToString:@"hollow"]) {
      // Glyph by style: hollow -> the small radius-widget ring (matching
      // Rounded/Canvas), arc -> the position-style arc, square -> square,
      // else dot. EVERY glyph must clear clearsOnDraw (default YES) or its
      // draw wipes the tile and erases every control drawn before it.
      KKRingOSC *g = [[KKRingOSC alloc] initWithAPIManager:self.apiManager];
      [g applyRadiusWidgetStyle]; // also sets clearsOnDraw = NO
      // Solid white always: parity with the mini (which has no hover), and the
      // dim idle grey reads unclear for a small radius handle.
      g.solidStyle = YES;
      ctl = g;
    } else if ([b.styleName isEqualToString:@"arc"]) {
      KKArcOSC *g = [[KKArcOSC alloc] initWithAPIManager:self.apiManager];
      g.clearsOnDraw = NO;
      ctl = g;
    } else if ([b.styleName isEqualToString:@"square"]) {
      KKSquarePointOSC *g =
          [[KKSquarePointOSC alloc] initWithAPIManager:self.apiManager];
      g.clearsOnDraw = NO;
      ctl = g;
    } else {
      KKPointOSC *g = [[KKPointOSC alloc] initWithAPIManager:self.apiManager];
      g.clearsOnDraw = NO;
      ctl = g;
    }
    nextCtl[b.name] = ctl;
    nextBlk[b.name] = b;
    [order addObject:b.name];
  }
  _exprControllers = nextCtl;
  _exprBlocks = nextBlk;
  _exprOrder = [order copy];
}

// Raw lane values (lane units) for any uniform label at the current tick's
// fraction: the snapshot lane when materialized, else the directive-default
// template lane. Backs the runtimes' laneValueProvider.
- (nullable NSArray<NSNumber *> *)_exprRawLaneValuesForLabel:(NSString *)label
                                                  atFraction:(double)frac {
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:label])
      return KKTimelineLaneValueAtFraction(l, frac);
  KKLane *tpl = _exprAvailLanes[label];
  return tpl ? KKTimelineLaneValueAtFraction(tpl, frac) : nil;
}

- (nullable NSArray<NSNumber *> *)_exprRawLaneValuesForLabel:(NSString *)label {
  return [self _exprRawLaneValuesForLabel:label atFraction:_exprTickFrac];
}

// KKPositionGuideProvider: the point controllers read the guide state through
// these, so they stay plugin-agnostic while Mirage keeps its singleton bridge +
// the guide-pushed position.
- (KKOSCGuideBridge *)positionGuideBridge {
  return MirageGuideBridge();
}

- (CGPoint)positionGuideObjectValue {
  return sGuidePosition;
}

// The live shader source from the process timeline snapshot (blob reads are
// flaky in the OSC tick; the snapshot is canonical).
- (nullable NSString *)_currentShaderSource {
  BOOL hasShaderLane = NO;
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:@"Mirage"]) {
      hasShaderLane = YES;
      if (l.codeString.length)
        return l.codeString;
    }
  // An ABSENT Mirage lane is a fresh instance whose timeline blob hasn't been
  // persisted yet: the render seeds the default (Plasma) source, so the OSC has
  // to as well, or a fresh Plasma draws NO handles (its `#point`/`osc=ring`
  // controls never build) - which is exactly what starves the timing guide's
  // OSC step. A PRESENT-but-empty lane means the user cleared the code
  // (passthrough), so it correctly has no controls. Mirrors MirageStateBlob's
  // absent-vs-empty rule on the render side.
  return hasShaderLane ? nil : MirageCustomDefaultShaderSource();
}

// Rebuild every OSC control to match the shader source. The runtimes are the
// single source of truth (directive sugar + authored blocks); the block sync
// owns all controller construction.
- (void)_syncOSCControllers {
  [self _syncOSCBlocks:[self _currentShaderSource]];
}

// activePart -> its position controller (and whether it's the path/tangent
// half). Used by the mouse handlers to route a drag.
- (nullable KKPositionOSC *)controllerForActivePart:(NSInteger)part
                                             isPath:(BOOL *)outPath {
  if (part < kMirageOSCPartBase)
    return nil;
  NSInteger idx = (part - kMirageOSCPartBase) / 2;
  if (idx < 0 || idx >= (NSInteger)_posOrder.count)
    return nil;
  if (outPath)
    *outPath = ((part - kMirageOSCPartBase) & 1) != 0;
  return _posControllers[_posOrder[idx]];
}

// --- Custom `// @osc` controls --------------------------------------------

// The bound lane for a block: the snapshot lane, else its template (default
// keypose) so the handle is drawable / grabbable before the lane materializes.
- (nullable KKLane *)_exprLaneForBlock:(MirageOSCBlockRuntime *)b {
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:b.binds])
      return l;
  return b.templateLane;
}

// The bound value in EXPR units (the shader's, post-directive-normalization: a
// percent lane's 0..100 -> 0..1). One vector, `fieldCount` components.
- (KKExprVal)_exprValueForBlock:(MirageOSCBlockRuntime *)b
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
- (CGPoint)_exprCanvasForBlock:(MirageOSCBlockRuntime *)b value:(KKExprVal)v {
  simd_float2 p = [b objectPointForBound:v
                                  aspect:[self _exprAspect]
                                   mouse:(simd_float2){0, 0}
                               haveMouse:NO];
  return [self canvasPointFromObjectPoint:p];
}

// The handle position at the current (lane) value.
- (CGPoint)_exprHandleCanvasForBlock:(MirageOSCBlockRuntime *)b
                          atFraction:(double)frac {
  return [self _exprCanvasForBlock:b
                             value:[self _exprValueForBlock:b atFraction:frac]];
}

// Every point/position handle's object position at `frac` EXCEPT the one bound
// to `binds` - the shared snap-target set both the point drag path and the
// position OSC (its externalSnapTargets) pull from, so the two snap onto each
// other. The handle geometry lives in MirageOSCBlockRuntime (shared with the
// mini); this supplies the viewer's snapshot lane values.
- (NSArray<NSValue *> *)_exprSnapTargetsExcludingBinds:(NSString *)binds
                                            atFraction:(double)frac {
  return [MirageOSCBlockRuntime
      snapTargetsForRuntimes:_allRuntimes
              excludingBinds:binds
                      aspect:[self _exprAspect]
                  laneValues:^NSArray<NSNumber *> *(NSString *b) {
                    return [self _exprRawLaneValuesForLabel:b atFraction:frac];
                  }];
}

// Snap a point block's dragged CANVAS point to the canvas centre / edges /
// quarters and the other point/position handles (the shared target set), Cmd-
// engaged like KKPositionOSC. Returns the snapped OBJECT point and records
// `_exprSnapActive` for the guide-draw pass. Per-axis thresholds convert the
// pixel radius through each axis's own px-per-object-unit (the object space is
// aspect-distorted).
- (simd_float2)_snapObjectMouseForBlock:(MirageOSCBlockRuntime *)b
                                 canvas:(CGPoint)m
                             atFraction:(double)frac {
  simd_float2 om = [self objectPointFromCanvasPoint:m];
  static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  NSArray<NSValue *> *targets = [self _exprSnapTargetsExcludingBinds:b.binds
                                                          atFraction:frac];
  NSUInteger n = targets.count;
  simd_float2 *objs = n ? malloc(n * sizeof(simd_float2)) : NULL;
  for (NSUInteger i = 0; i < n; i++) {
    NSPoint p = targets[i].pointValue;
    objs[i] = (simd_float2){(float)p.x, (float)p.y};
  }
  CGPoint tr = CGPointZero, bl = CGPointZero;
  float thrX = 0.01f, thrY = 0.01f;
  if ([self getCanvasTopRight:&tr bottomLeft:&bl]) {
    float ppuX = MAX(1.0f, (float)fabs(tr.x - bl.x));
    float ppuY = MAX(1.0f, (float)fabs(tr.y - bl.y));
    thrX = _exprSnap.threshold / ppuX;
    thrY = _exprSnap.threshold / ppuY;
  }
  simd_float2 snapped = [_exprSnap snapPoint:om
                              canvasAnchorsX:anchors
                                      countX:5
                              canvasAnchorsY:anchors
                                      countY:5
                               objectTargets:objs
                                       count:n
                                  thresholdX:thrX
                                  thresholdY:thrY];
  if (objs)
    free(objs);
  _exprSnapActive = _exprSnap.snappedX || _exprSnap.snappedY;
  return snapped;
}

// A ring block's canvas centre + per-axis radii in canvas px (the runtime
// returns min-dimension fractions).
- (CGPoint)_exprRingGeometryForBlock:(MirageOSCBlockRuntime *)b
                          atFraction:(double)frac
                             radiusX:(double *)outRX
                             radiusY:(double *)outRY {
  KKExprVal v = [self _exprValueForBlock:b atFraction:frac];
  double aspect = [self _exprAspect];
  simd_float2 oc = [b centerObjectForBound:v aspect:aspect];
  KKExprVal radii = [b ringRadiiForBound:v aspect:aspect];
  double minDim = [self canvasMinDimension];
  if (outRX)
    *outRX = radii.v[0] * minDim;
  if (outRY)
    *outRY = (radii.n >= 2 ? radii.v[1] : radii.v[0]) * minDim;
  return [self canvasPointFromObjectPoint:oc];
}

// A rotate block's canvas centre (its `center =` expression, default frame
// centre).
- (CGPoint)_exprRotationCenterForBlock:(MirageOSCBlockRuntime *)b
                            atFraction:(double)frac {
  KKExprVal v = [self _exprValueForBlock:b atFraction:frac];
  simd_float2 oc = [b centerObjectForBound:v aspect:[self _exprAspect]];
  return [self canvasPointFromObjectPoint:oc];
}

// Push a ring block's current geometry into its KKRingOSC control.
- (void)_exprUpdateRing:(KKRingOSC *)ring
               forBlock:(MirageOSCBlockRuntime *)b
             atFraction:(double)frac {
  double rx = 0, ry = 0;
  CGPoint c = [self _exprRingGeometryForBlock:b
                                   atFraction:frac
                                      radiusX:&rx
                                      radiusY:&ry];
  ring.center = c;
  ring.ringRadius = (float)rx;
  ring.ringRadiusY = (float)ry;
}

// Custom `// @osc` control visibility: shown when the
// bound lane is a constant or the playhead is on a keypose, always mid-drag; an
// Opt-hidden handle surfaces as a dim ghost while Opt-reveal is active. The
// block's `name` is its OSC-checklist element key (see oscElementKeys).
- (BOOL)_exprVisible:(MirageOSCBlockRuntime *)b
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
- (KKExprVal)_exprBoundForBlock:(MirageOSCBlockRuntime *)b
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
// (seed from the template when the lane isn't materialized). Mirrors Glow's
// _writeRadiusValues.
- (void)_writeExprValue:(KKExprVal)val
               forBlock:(MirageOSCBlockRuntime *)b
                 atTime:(CMTime)time
            forceUpdate:(BOOL *)forceUpdate {
  NSArray<NSNumber *> *values = [b laneValuesFromBound:val];
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  _exprActionDepth++;
  if (_exprActionDepth > 1)
    KKLogError(@"[ExprWrite] NESTED action (depth=%d) writing %@ via %@ - "
               @"this would assert FFUIAction in the host",
               _exprActionDepth, b.binds, b.name);
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    [actionAPI endAction:self];
    _exprActionDepth--;
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
  _exprActionDepth--;
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
  if (part >= kMirageExprPartBase) {
    NSInteger idx = part - kMirageExprPartBase;
    if (idx >= 0 && idx < (NSInteger)_exprOrder.count) {
      _exprDragName = _exprOrder[idx];
      // The ring primitive's drag mechanic anchors on the press state: the
      // bound value and the cursor's offset from the centre (fractions).
      MirageOSCBlockRuntime *b = _exprBlocks[_exprDragName];
      double frac = [self fractionAtTime:time];
      _exprTickFrac = frac;
      _exprDragPressBound = [self _exprValueForBlock:b atFraction:frac];
      if ([b.primitive isEqualToString:@"ring"]) {
        CGPoint c = [self _exprRingGeometryForBlock:b
                                         atFraction:frac
                                            radiusX:NULL
                                            radiusY:NULL];
        double minDim = MAX(1.0, [self canvasMinDimension]);
        _exprDragPressOff = (simd_float2){(float)((x - c.x) / minDim),
                                          (float)((y - c.y) / minDim)};
        [(KKRingOSC *)_exprControllers[_exprDragName] updateCursorForMouseX:x
                                                                  positionY:y];
      } else if ([b.primitive isEqualToString:@"box"]) {
        _exprBoxDragPart = _exprBoxHitPart;
        KKCropOSC *crop = _exprControllers[_exprDragName];
        if (b.bodyMove) {
          // The crop scaffold owns the anchored-resize / body-move mechanic;
          // it reads the press pose itself and writes through valuesWriter.
          [crop mouseDownForPart:_exprBoxDragPart
                       positionX:x
                       positionY:y
                          atTime:time];
        } else {
          // Centred box: the runtime owns the drag. Anchor the effective
          // cursor AT the grabbed handle so the value starts exactly where it
          // is (no press snap).
          NSInteger idx = _exprBoxDragPart - KKCropPartPointBase;
          CGPoint tr = CGPointZero, bl = CGPointZero;
          if (idx >= 0 && idx < KKCropPointCount &&
              [crop getTopRight:&tr
                       bottomLeft:&bl
                  fullImageCanvas:NULL
                           atTime:time])
            _exprBoxDragEff = [KKBoxOSC handlePositionForIndex:idx
                                                      topRight:tr
                                                    bottomLeft:bl];
          else
            _exprBoxDragEff = CGPointMake(x, y);
          _exprBoxDragLast = CGPointMake(x, y);
        }
      } else if ([b.primitive isEqualToString:@"rotate"]) {
        KKRotationOSC *rot = _exprControllers[_exprDragName];
        rot.center = [self _exprRotationCenterForBlock:b atFraction:frac];
        [rot mouseDownAtX:x
                        y:y
                modifiers:modifiers
              forceUpdate:forceUpdate
                   atTime:time];
      }
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
  // Let the position drag snap onto the point OSCs too (symmetric with the
  // point drag snapping onto positions). Static for the drag, so seed once.
  c.externalSnapTargets =
      [self _exprSnapTargetsExcludingBinds:c.laneLabel
                                atFraction:[self fractionAtTime:time]];
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
  if (_exprDragName) {
    MirageOSCBlockRuntime *b = _exprBlocks[_exprDragName];
    double frac = [self fractionAtTime:time];
    _exprTickFrac = frac;
    if ([b.primitive isEqualToString:@"ring"]) {
      // The ring's default drag: offset from the (live) centre in fractions ->
      // runtime mechanic (circle / linked-ellipse / cardinal-hold) -> write.
      CGPoint c = [self _exprRingGeometryForBlock:b
                                       atFraction:frac
                                          radiusX:NULL
                                          radiusY:NULL];
      double minDim = MAX(1.0, [self canvasMinDimension]);
      simd_float2 off = {(float)((x - c.x) / minDim),
                         (float)((y - c.y) / minDim)};
      BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
      BOOL laneLinked = b.linked && [self _exprLaneForBlock:b].aspectLinked;
      BOOL effLinked = b.linked ? (laneLinked ^ shift) : NO;
      KKExprVal nv = [b ringBoundForDragOffset:off
                                   pressOffset:_exprDragPressOff
                                    pressBound:_exprDragPressBound
                               linkedEffective:effLinked
                                        aspect:[self _exprAspect]];
      [(KKRingOSC *)_exprControllers[_exprDragName] updateCursorForMouseX:x
                                                                positionY:y];
      [self _writeExprValue:nv forBlock:b atTime:time forceUpdate:forceUpdate];
      return YES;
    }
    if ([b.primitive isEqualToString:@"box"]) {
      if (b.bodyMove) {
        [(KKCropOSC *)_exprControllers[_exprDragName]
            mouseDraggedForPart:_exprBoxDragPart
                      positionX:x
                      positionY:y
                    forceUpdate:forceUpdate
                         atTime:time];
        return YES;
      }
      // Centred box: advance the effective cursor by the raw delta (scaled
      // down for Cmd-fine), then run the runtime's centred mechanic.
      double fine =
          (modifiers & kFxModifierKey_COMMAND) ? kMirageExprBoxFineFactor : 1.0;
      _exprBoxDragEff.x += (x - _exprBoxDragLast.x) * fine;
      _exprBoxDragEff.y += (y - _exprBoxDragLast.y) * fine;
      _exprBoxDragLast = CGPointMake(x, y);
      NSInteger idx = _exprBoxDragPart - KKCropPartPointBase;
      simd_float2 mObj =
          [self objectPointFromCanvasPoint:CGPointMake(_exprBoxDragEff.x,
                                                       _exprBoxDragEff.y)];
      BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
      BOOL laneLinked = b.linked && [self _exprLaneForBlock:b].aspectLinked;
      BOOL effLinked = b.linked ? (laneLinked ^ shift) : NO;
      KKExprVal nv =
          [b boxCenteredBoundForObjectMouse:mObj
                                     corner:MirageExprBoxHandleIsCorner(idx)
                                  controlsX:MirageExprBoxHandleControlsX(idx)
                                 pressBound:_exprDragPressBound
                            linkedEffective:effLinked
                                     aspect:[self _exprAspect]];
      [self _writeExprValue:nv forBlock:b atTime:time forceUpdate:forceUpdate];
      return YES;
    }
    if ([b.primitive isEqualToString:@"rotate"]) {
      KKRotationOSC *rot = _exprControllers[_exprDragName];
      rot.center = [self _exprRotationCenterForBlock:b atFraction:frac];
      [rot mouseDraggedAtX:x
                         y:y
                 modifiers:modifiers
               forceUpdate:forceUpdate
                    atTime:time];
      return YES;
    }
    // Cmd engages point snapping (parity with osc=position): snap the cursor
    // onto the canvas centre / edges / quarters + the other handles, then
    // invert from the snapped point. `skipsnapping` blocks opt out.
    CGPoint mp = CGPointMake(x, y);
    _exprSnapActive = NO;
    if (b.snaps && (modifiers & kFxModifierKey_COMMAND)) {
      simd_float2 sp = [self _snapObjectMouseForBlock:b
                                               canvas:mp
                                           atFraction:frac];
      mp = [self canvasPointFromObjectPoint:sp];
    } else {
      [_exprSnap reset];
    }
    KKExprVal nv = [self _exprBoundForBlock:b mouseCanvas:mp atFraction:frac];
    NSCursor *cur = MirageOSCCursorForName(b.cursorName);
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
  for (NSString *label in _posOrder) {
    [_posControllers[label] mouseUp];
    _posControllers[label].externalSnapTargets = nil;
  }
  [_exprSnap reset];
  _exprSnapActive = NO;
  _dragController = nil;
  if (_exprDragName) {
    id ctl = _exprControllers[_exprDragName];
    if ([ctl isKindOfClass:KKCropOSC.class])
      [(KKCropOSC *)ctl mouseUp];
    if ([ctl isKindOfClass:KKRotationOSC.class])
      [(KKRotationOSC *)ctl mouseUp];
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor arrowCursor]];
    _exprDragName = nil;
    _exprBoxDragPart = KKCropPartNone;
    _exprBoxHitPart = KKCropPartNone;
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

// The OSC element keys, in RUNTIME order (directive sugar then authored
// blocks), mirroring oscCompoundsForShaderSource: so the checklist states line
// up. A position block is TWO hideable elements (handle + "<label> Path"); a
// rotate block gates on its LANE label (master + per-axis suffixes);
// everything else is a single element keyed by block name.
- (NSArray<NSString *> *)oscElementKeys {
  [self _syncOSCControllers];
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  for (MirageOSCBlockRuntime *b in _allRuntimes) {
    if ([b.primitive isEqualToString:@"position"]) {
      [keys addObject:b.binds];
      [keys addObject:[b.binds stringByAppendingString:@" Path"]];
    } else if ([b.primitive isEqualToString:@"rotate"]) {
      [keys addObjectsFromArray:MirageExprRotateElementKeys(b.binds, b.axes)];
    } else {
      [keys addObject:b.name];
    }
  }
  return keys;
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart >= kMirageExprPartBase) {
    NSInteger idx = activePart - kMirageExprPartBase;
    if (idx >= 0 && idx < (NSInteger)_exprOrder.count) {
      MirageOSCBlockRuntime *b = _exprBlocks[_exprOrder[idx]];
      if ([b.primitive isEqualToString:@"rotate"]) {
        // The last-hit axis picks the per-axis element (a single ring hides);
        // the master only when no ring is active. Mirrors the inline rotates.
        NSInteger axis =
            [(KKRotationOSC *)_exprControllers[_exprOrder[idx]] activeAxis];
        NSString *suffix = axis == 0   ? @".X"
                           : axis == 1 ? @".Y"
                           : axis == 2 ? @".Z"
                                       : nil;
        return suffix ? [b.binds stringByAppendingString:suffix] : b.binds;
      }
      return _exprOrder[idx];
    }
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

  // Rotate blocks draw FIRST, so the small position handles + rings/boxes stay
  // on top (and grabbable) - matching the mini-viewer's layering. The gizmo
  // reads its own pose + ring colours from the snapshot lane and gates
  // per-axis visibility (master + .X/.Y/.Z + opt-reveal) internally.
  _exprTickFrac = ringFrac;
  for (NSUInteger i = 0; i < _exprOrder.count; i++) {
    MirageOSCBlockRuntime *b = _exprBlocks[_exprOrder[i]];
    if (![b.primitive isEqualToString:@"rotate"])
      continue;
    KKRotationOSC *rot = _exprControllers[_exprOrder[i]];
    rot.center = [self _exprRotationCenterForBlock:b atFraction:ringFrac];
    rot.rotationActivePart = kMirageExprPartBase + (NSInteger)i;
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

  // Draw each custom `// @osc` control - a `point` glyph at its
  // forward-expression position, a `ring` at its centre/radii - under the same
  // visibility gating (Opt-hidden -> dim ghost while Opt-reveal is held) as
  // the rings/boxes.
  _exprTickFrac = ringFrac;
  for (NSUInteger i = 0; i < _exprOrder.count; i++) {
    NSString *name = _exprOrder[i];
    MirageOSCBlockRuntime *b = _exprBlocks[name];
    if ([b.primitive isEqualToString:@"rotate"])
      continue; // drew in the early layer above
    BOOL reveal = NO;
    if (![self _exprVisible:b atFraction:ringFrac reveal:&reveal] && !reveal) {
      if ([b.primitive isEqualToString:@"ring"])
        [(KKRingOSC *)_exprControllers[name] clearCursorIfSet];
      continue;
    }
    BOOL hovered = (activePart == kMirageExprPartBase + (NSInteger)i);
    BOOL active = [_exprDragName isEqualToString:name];
    if ([b.primitive isEqualToString:@"ring"]) {
      KKRingOSC *ring = _exprControllers[name];
      [self _exprUpdateRing:ring forBlock:b atFraction:ringFrac];
      ring.ghostAlpha = reveal ? MAX(0.6f, [self kkRevealGhostAlpha]) : 1.0f;
      [ring drawAtCanvasPosition:ring.center
                       isHovered:hovered
                        isActive:active
                destinationImage:destinationImage
                          atTime:time];
      continue;
    }
    if ([b.primitive isEqualToString:@"box"]) {
      KKCropOSC *crop = _exprControllers[name];
      crop.ghostAlpha = reveal ? MAX(0.6f, [self kkRevealGhostAlpha]) : 1.0f;
      CGPoint btr = CGPointZero, bbl = CGPointZero;
      CGSize fullCanvas = CGSizeZero;
      if (![crop getTopRight:&btr
                   bottomLeft:&bbl
              fullImageCanvas:&fullCanvas
                       atTime:time])
        continue;
      // The readout matches the BOUND LANE's display units, not always source
      // px: a crop-style box shows W x H (px per "px" component, else the raw
      // fraction), a centred value box its lane value ("58% x 58%"). Media px
      // = the full-image canvas size de-zoomed (how KKCropOSC derives it).
      NSString *readout;
      if (b.bodyMove) {
        id<FxOnScreenControlAPI_v2> zoomAPI =
            [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
        double zoom = zoomAPI ? [zoomAPI canvasZoom] : 1.0;
        if (zoom < 0.001)
          zoom = 1.0;
        CGSize media = CGSizeMake(fabs(fullCanvas.width) / zoom,
                                  fabs(fullCanvas.height) / zoom);
        readout = [MirageOSCBlockRuntime
            boxReadoutForValues:KKTimelineLaneValueAtFraction(
                                    [self _exprLaneForBlock:b], ringFrac)
                          units:b.boundComponentUnits
                scalesWithMedia:b.boundScalesWithMedia
                      mediaSize:media];
      } else {
        NSArray<NSNumber *> *raw =
            KKTimelineLaneValueAtFraction([self _exprLaneForBlock:b], ringFrac);
        readout = KKBoxOSCReadoutString(raw, b.divisor == 100.0, b.isInt);
      }
      NSInteger activeHandle = active && _exprBoxDragPart >= KKCropPartPointBase
                                   ? _exprBoxDragPart - KKCropPartPointBase
                                   : crop.hoveredIndex;
      [crop drawWithTopRight:btr
                  bottomLeft:bbl
                     readout:readout
                activeHandle:activeHandle
            destinationImage:destinationImage
                      atTime:time];
      continue;
    }
    id<_MirageGlyphOSC> glyph = _exprControllers[name];
    // Guard both protocol members: an unhandled selector here is an uncaught
    // exception that kills the whole XPC (and FCP aborts reporting it).
    if ([glyph respondsToSelector:@selector(setGhostAlpha:)])
      glyph.ghostAlpha = reveal ? MAX(0.6f, [self kkRevealGhostAlpha]) : 1.0f;
    if (![glyph
            respondsToSelector:@selector(drawAtCanvasPosition:isHovered:
                                         isActive:destinationImage:atTime:)])
      continue;
    CGPoint c = [self _exprHandleCanvasForBlock:b atFraction:ringFrac];
    [glyph drawAtCanvasPosition:c
                      isHovered:hovered
                       isActive:active
               destinationImage:destinationImage
                         atTime:time];
    // Snap guides for the point being dragged, drawn through self (the OSC
    // holding the canvas reference) in object space. Two-colour like
    // KKPositionOSC: canvas anchors yellow, other-handle targets the host
    // accent (blue).
    if (active && _exprSnapActive) {
      simd_float4 yellow, accent;
      KKSnapGuideColors(&yellow, &accent);
      [_exprSnap drawSnapGuidesWithOSC:self
                         isObjectSpace:YES
                           canvasColor:yellow
                           objectColor:accent
                      destinationImage:destinationImage];
    }
  }

  // Feed the guide bridge this tick's canvas geometry (zoom-invariant
  // CANVAS->screen affine + viewer-rect recompute) so MirageHasCanvasReference
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

  BOOL inGuide = MirageGuideBridge().guideStep > 0;
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
    CGPoint tgt = kMirageGuideTargetObject;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:tgt.x
                            fromY:tgt.y
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&targetCanvas.x
                              toY:&targetCanvas.y];
  }
  [MirageGuideBridge() ingestDrawTickWithCanvasTopRight:trC
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
    NSRect hs = MirageGuideBridge().estimatedHandleScreenRect;
    KKLogDebug(
        @"[GuideOSC] step=%ld pts=%lu handleCanvas=(%.1f,%.1f) "
        @"tr=(%.1f,%.1f) bl=(%.1f,%.1f) handleScreen=(%.0f,%.0f %.0fx%.0f)",
        (long)MirageGuideBridge().guideStep, (unsigned long)_posOrder.count,
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
  // Custom `// @osc` controls hit-test last: a `point` by distance to its
  // forward-expression position within the glyph's grab radius, a `ring` by
  // its own edge hit-test (which also sets its resize / eye cursor).
  if (*activePart == 0) {
    double frac = [self fractionAtTime:time];
    _exprTickFrac = frac;
    for (NSUInteger i = 0; i < _exprOrder.count; i++) {
      NSString *name = _exprOrder[i];
      MirageOSCBlockRuntime *b = _exprBlocks[name];
      if ([b.primitive isEqualToString:@"rotate"]) {
        // The gizmo gates its own visibility and sets its own rotate / eye
        // cursor, like the inline rotation loop.
        KKRotationOSC *rot = _exprControllers[name];
        rot.center = [self _exprRotationCenterForBlock:b atFraction:frac];
        rot.rotationActivePart = kMirageExprPartBase + (NSInteger)i;
        rot.optRevealActive = self.optRevealActive;
        if ([rot hitTestRingAtX:positionX y:positionY atTime:time] >= 0) {
          *activePart = kMirageExprPartBase + (NSInteger)i;
          self.pointCursorSet = YES;
          break;
        }
        continue;
      }
      BOOL reveal = NO;
      BOOL visible = [self _exprVisible:b atFraction:frac reveal:&reveal];
      if ([b.primitive isEqualToString:@"ring"]) {
        KKRingOSC *ring = _exprControllers[name];
        if (!visible && !reveal) {
          ring.visibilityHint = 0;
          [ring clearCursorIfSet];
          continue;
        }
        [self _exprUpdateRing:ring forBlock:b atFraction:frac];
        BOOL optToggle = self.optRevealActive && ![self kkOSCMasterOff];
        ring.visibilityHint = optToggle ? (visible ? 1 : 2) : 0;
        if ([ring hitTestAtMousePositionX:positionX
                                positionY:positionY
                                   atTime:time]) {
          *activePart = kMirageExprPartBase + (NSInteger)i;
          self.pointCursorSet = YES;
          break;
        }
        continue;
      }
      if ([b.primitive isEqualToString:@"box"]) {
        // Pass 1 accepts only the box's HANDLES. The interior (body-move)
        // hit-tests in a second pass below, so a large box never steals a
        // click from a smaller control sitting inside it.
        KKCropOSC *crop = _exprControllers[name];
        if (!visible && !reveal) {
          crop.visibilityHint = 0;
          continue;
        }
        BOOL optToggle = self.optRevealActive && ![self kkOSCMasterOff];
        crop.visibilityHint = optToggle ? (visible ? 1 : 2) : 0;
        NSInteger part = [crop hitTestAtMousePositionX:positionX
                                             positionY:positionY
                                                atTime:time];
        if (part >= KKCropPartPointBase) {
          _exprBoxHitPart = part;
          *activePart = kMirageExprPartBase + (NSInteger)i;
          self.pointCursorSet = YES;
          break;
        }
        continue;
      }
      if (!visible && !reveal)
        continue;
      CGPoint c = [self _exprHandleCanvasForBlock:b atFraction:frac];
      if (hypot(positionX - c.x, positionY - c.y) <=
          MirageExprGrabRadius(b.styleName)) {
        *activePart = kMirageExprPartBase + (NSInteger)i;
        // Opt-hover shows the eye (hide) / eye-slash cursor over a toggleable
        // handle; otherwise the block's own drag cursor.
        NSCursor *cur = [self kkVisibilityCursorForLabel:name]
                            ?: MirageOSCCursorForName(b.cursorName);
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

  // Pass 2: box INTERIORS (body-move). Lowest-priority target, so a
  // crop-style box's large body only claims when no precise part anywhere
  // (handles, rings, glyphs, gizmo rings) is under the cursor.
  if (*activePart == 0) {
    double frac = [self fractionAtTime:time];
    for (NSUInteger i = 0; i < _exprOrder.count; i++) {
      NSString *name = _exprOrder[i];
      MirageOSCBlockRuntime *b = _exprBlocks[name];
      if (![b.primitive isEqualToString:@"box"] || !b.bodyMove)
        continue;
      BOOL reveal = NO;
      if (![self _exprVisible:b atFraction:frac reveal:&reveal] && !reveal)
        continue;
      KKCropOSC *crop = _exprControllers[name];
      if ([crop hitTestAtMousePositionX:positionX
                              positionY:positionY
                                 atTime:time] == KKCropPartRect) {
        _exprBoxHitPart = KKCropPartRect;
        *activePart = kMirageExprPartBase + (NSInteger)i;
        // The interior moves the whole box: show the open-hand move cursor
        // (the handles set their own resize cursors in pass 1).
        id<FxOnScreenControlAPI_v4> curAPI =
            [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
        [curAPI setCursor:KKPointMoveCursor()];
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
  [MirageGuideBridge() ingestHitTestAtScreen:NSEvent.mouseLocation
                                   canvasPos:CGPointMake(positionX, positionY)
                                 canvasScale:spC
                                    topRight:tr
                                  bottomLeft:bl
                                    onHandle:NO
                             handleCanvasPos:centre];
}

@end
