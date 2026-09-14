/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageOSCBlockRuntime.h"

#import "MirageDirectives.h" // MirageShaderModel + MirageScalarProp
#import "MirageOSCBlock.h"   // // @osc custom-handling blocks
#import "MirageRack.h"       // lane/element keys scoped to a rack entry
#import <KeyframelessKit/KKResizeCursor.h>
#import <KeyframelessKit/KeyframelessKit.h> // KKLane

NSSet<NSString *> *MirageOSCBaseVars(void) {
  static NSSet<NSString *> *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [NSSet setWithArray:@[
      @"mouse", @"pos", @"size", @"aspect", @"tl", @"tr", @"bl", @"br",
      @"center", @"part"
    ]];
  });
  return s;
}

NSCursor *MirageOSCCursorForName(NSString *name) {
  if ([name isEqualToString:@"crosshair"])
    return [NSCursor crosshairCursor];
  if ([name isEqualToString:@"pointing"])
    return [NSCursor pointingHandCursor];
  if ([name isEqualToString:@"resize-h"])
    return KKResizeCursorOfKind(KKResizeCursorHorizontal);
  if ([name isEqualToString:@"resize-v"])
    return KKResizeCursorOfKind(KKResizeCursorVertical);
  if ([name isEqualToString:@"resize-diag"])
    return KKResizeCursorOfKind(KKResizeCursorDiagonalNESW);
  return KKPointMoveCursor(); // "move" / default
}

@implementation MirageOSCBlockRuntime {
  KKLinkExpr *_forward;
  KKLinkExpr *_inverse;     // nil = numerically invert the forward
  KKLinkExpr *_center;      // nil = frame centre (0.5, 0.5)
  KKLinkExpr *_angleOffset; // rotate: nil = no display offset
  NSArray<NSString *> *_localNames;
  NSArray<KKLinkExpr *> *_localExprs;
  // Per-uniform lane-unit -> expr-unit divisors for every uniform the shader
  // declares, so an expression referencing ANOTHER uniform (center = uOrigin,
  // toR relative to uScale, …) sees it in the same units the shader does.
  NSDictionary<NSString *, NSNumber *> *_uniformDivisors;
}

+ (NSArray<MirageOSCBlockRuntime *> *)runtimesForSource:(NSString *)src
                                                  lanes:(NSArray<KKLane *> *)
                                                            lanes {
  return [self runtimesForSource:src lanes:lanes rackEntryID:nil];
}

+ (NSArray<MirageOSCBlockRuntime *> *)runtimesForSource:(NSString *)src
                                                  lanes:
                                                      (NSArray<KKLane *> *)lanes
                                            rackEntryID:(NSString *)entryID {
  if (src.length == 0)
    return @[];
  MirageShaderModel *model = [MirageShaderModel modelForSource:src];
  const MirageScalarProp *props = model.scalarProps;
  int np = model.scalarCount;
  const MirageOSCBlock *blocks = model.oscBlocks;

  NSMutableArray<MirageOSCBlockRuntime *> *out = [NSMutableArray array];
  for (int i = 0; i < model.oscBlockCount; i++) {
    MirageOSCBlockRuntime *r = [self _runtimeForBlock:&blocks[i]
                                                props:props
                                                count:np
                                                lanes:lanes];
    if (r) {
      r->_laneKey = MirageRackLaneKey(entryID ?: @"", r->_binds);
      r->_elementKey = MirageRackLaneKey(entryID ?: @"", r->_name);
      [out addObject:r];
    }
  }
  return out;
}

// Build one runtime from a parsed block: normalize the bound value from its
// directive, compile the locals in order (each sees the OSC builtins + the
// bound name + earlier locals), then the forward (required) + optional inverse.
// Drops the block (returns nil) on an unwired primitive or a compile failure.
+ (nullable MirageOSCBlockRuntime *)
    _runtimeForBlock:(const MirageOSCBlock *)blk
               props:(const MirageScalarProp *)props
               count:(int)np
               lanes:(NSArray<KKLane *> *)lanes {
  NSString *name = @(blk->name);
  NSString *binds = @(blk->binds);
  if (name.length == 0 || binds.length == 0)
    return nil;
  BOOL isPoint = strcmp(blk->primitive, "point") == 0;
  BOOL isRing = strcmp(blk->primitive, "ring") == 0;
  BOOL isBox = strcmp(blk->primitive, "box") == 0;
  BOOL isRotate = strcmp(blk->primitive, "rotate") == 0;
  BOOL isPosition = strcmp(blk->primitive, "position") == 0;
  if (!isPoint && !isRing && !isBox && !isRotate && !isPosition)
    return nil;

  MirageOSCBlockRuntime *r = [MirageOSCBlockRuntime new];
  r->_name = [name copy];
  r->_primitive = @(blk->primitive);
  r->_binds = [binds copy];
  r->_styleName = @(blk->style);
  r->_cursorName = @(blk->cursor);
  r->_axes = @(blk->axes);
  r->_centerSource = @(blk->center);
  r->_angleOffsetSource = @(blk->angleOffset);
  r->_linked = blk->linked != 0;
  r->_bodyMove = blk->bodyDisabled == 0;
  r->_snaps = blk->skipSnapping == 0;
  r->_fieldCount = 1;
  r->_divisor = 1.0;
  r->_laneMin = -1e9;
  r->_laneMax = 1e9;
  // Every declared uniform is referenceable from an expression; record each
  // one's lane->expr divisor so referenced values normalize like the bound one.
  NSMutableSet<NSString *> *uniformNames = [NSMutableSet set];
  NSMutableDictionary<NSString *, NSNumber *> *divisors =
      [NSMutableDictionary dictionary];
  for (int k = 0; k < np; k++) {
    NSString *un = @(props[k].name);
    if (!un.length)
      continue;
    [uniformNames addObject:un];
    divisors[un] = @(props[k].isPercent ? 100.0 : 1.0);
  }
  r->_uniformDivisors = [divisors copy];
  for (int k = 0; k < np; k++)
    if (strcmp(props[k].name, blk->binds) == 0) {
      r->_divisor = props[k].isPercent ? 100.0 : 1.0;
      // A #point lane is 2-component even though it isn't a #multi.
      r->_fieldCount =
          props[k].isPoint
              ? 2
              : (props[k].isMulti ? MAX(1, props[k].fieldCount) : 1);
      r->_isInt = props[k].isInt || props[k].isPercent;
      if (props[k].hasMin)
        r->_laneMin = props[k].fmin;
      if (props[k].hasMax)
        r->_laneMax = props[k].fmax;
      break;
    }
  for (KKLane *l in lanes)
    if ([l.key isEqualToString:binds]) {
      r->_templateLane = l;
      r->_boundScalesWithMedia = l.componentsScaleWithMedia;
      r->_boundComponentUnits = [l.componentUnits copy];
      break;
    }
  double div = r->_divisor > 0 ? r->_divisor : 1.0;
  r->_exprMin = r->_laneMin / div;
  r->_exprMax = r->_laneMax / div;

  // Locals compile in order: each may use the OSC builtins, the bound name,
  // any declared uniform, and EARLIER locals (so `allowed` grows).
  // forward/inverse then see all locals. A ring's inverse also sees `r`, the
  // dragged radii.
  NSMutableSet<NSString *> *allowed = [[MirageOSCBaseVars()
      setByAddingObjectsFromSet:uniformNames] mutableCopy];
  [allowed addObject:binds];
  if (isRing)
    [allowed addObject:@"r"];
  if (isBox)
    [allowed addObject:@"rect"];
  NSString *err = nil;
  NSMutableArray<NSString *> *lnames = [NSMutableArray array];
  NSMutableArray<KKLinkExpr *> *lexprs = [NSMutableArray array];
  for (int k = 0; k < blk->localCount; k++) {
    KKLinkExpr *le = [KKLinkExpr compile:@(blk->localExprs[k])
                             allowedVars:allowed
                                   error:&err];
    if (!le)
      return nil;
    [lnames addObject:@(blk->localNames[k])];
    [lexprs addObject:le];
    [allowed addObject:@(blk->localNames[k])];
  }
  r->_localNames = [lnames copy];
  r->_localExprs = [lexprs copy];
  // A rotate block is PLACEMENT-ONLY (the gizmo owns its drag math + persist),
  // as is a `position` block (the KKPositionOSC backing owns the editable
  // motion path + drag + persist): no forward/inverse, just the declaration.
  // Position shows the LANE VALUE as its handle, so it needs a 2-component
  // #point lane (validation flags anything else; drop here as a backstop).
  if (isPosition) {
    BOOL bindsIsPoint = NO;
    for (int k = 0; k < np; k++)
      if (strcmp(props[k].name, blk->binds) == 0) {
        bindsIsPoint = props[k].isPoint != 0;
        break;
      }
    if (!bindsIsPoint)
      return nil;
  }
  // A `position` normally has no forward (the control IS the lane), but an
  // AUTHORED toPos/fromPos remaps it - the placement warp KKPositionOSC applies
  // to every drawn point. Compile it only when one was written, so the
  // `osc=position` sugar (which supplies none) still means identity placement
  // rather than failing to compile an empty expression.
  if (!isRotate && (!isPosition || strlen(blk->forward) > 0)) {
    r->_forward = [KKLinkExpr compile:@(blk->forward)
                          allowedVars:allowed
                                error:&err];
    if (!r->_forward)
      return nil;
  }
  // Inverse is optional for a point ("numerically invert the forward");
  // REQUIRED for a ring/box (their geometry has no positional argmin to
  // search).
  if (strlen(blk->inverse) > 0)
    r->_inverse = [KKLinkExpr compile:@(blk->inverse)
                          allowedVars:allowed
                                error:&err];
  if ((isRing || isBox) && !r->_inverse)
    return nil;
  if (strlen(blk->center) > 0) {
    r->_center = [KKLinkExpr compile:@(blk->center)
                         allowedVars:allowed
                               error:&err];
    if (!r->_center)
      return nil;
  }
  // Display-only pose offset (rotate). Compiled like any other block
  // expression, so it may name the bound value, other uniforms, and the locals
  // above - which is how a preset angle derived from a #choice reaches it.
  if (isRotate && strlen(blk->angleOffset) > 0) {
    r->_angleOffset = [KKLinkExpr compile:@(blk->angleOffset)
                              allowedVars:allowed
                                    error:&err];
    if (!r->_angleOffset)
      return nil;
  }
  return r;
}

- (BOOL)hasInverse {
  return _inverse != nil;
}

- (BOOL)hasForward {
  return _forward != nil;
}

- (BOOL)hasAngleOffset {
  return _angleOffset != nil;
}

- (void)angleOffsetDegreesForBound:(KKExprVal)bound
                            aspect:(double)aspect
                               out:(double[3])xyz {
  xyz[0] = xyz[1] = xyz[2] = 0.0;
  if (!_angleOffset)
    return;
  KKExprVal o =
      [_angleOffset evalWithValue:bound
                             vars:[self _varsForBound:bound
                                               aspect:aspect
                                                mouse:(simd_float2){0, 0}
                                            haveMouse:NO
                                                extra:nil
                                                 frac:-1.0]];
  // Component N belongs to the axis listed Nth, exactly like the bound value's
  // components; the gizmos want canonical X/Y/Z.
  MirageOSCBlock blk = {0};
  MirageOSCSetField(blk.axes, sizeof(blk.axes), _axes ?: @"");
  char axes[3];
  int n = MirageOSCBlockAxes(&blk, axes);
  for (int i = 0; i < n; i++) {
    double v = (i < o.n) ? o.v[i] : 0.0;
    xyz[axes[i] == 'x' ? 0 : (axes[i] == 'y' ? 1 : 2)] = v;
  }
}

- (KKExprVal)boundValueFromLaneValues:(NSArray<NSNumber *> *)values {
  KKExprVal r = {{0, 0, 0, 0}, MAX(1, _fieldCount)};
  double div = _divisor > 0 ? _divisor : 1.0;
  for (int i = 0; i < r.n && i < (int)values.count; i++)
    r.v[i] = values[i].doubleValue / div;
  return r;
}

// The variable resolver for this block's expressions: the bound uniform's name
// + the OSC builtins (object-space corners, aspect, and `pos`/`mouse` during a
// drag) + any declared uniform (via laneValueProvider) + `extra` primitive
// state (a ring drag's `r`) + the precomputed locals. Object space is 0..1,
// Y-up.
- (KKExprVal (^)(NSString *))
    _varsForBound:(KKExprVal)bound
           aspect:(double)aspect
            mouse:(simd_float2)mouse
        haveMouse:(BOOL)haveMouse
            extra:(nullable NSDictionary<NSString *, NSValue *> *)extra
             frac:(double)frac {
  NSString *binds = _binds;
  double ax = aspect;
  simd_float2 m = mouse;
  BOOL hm = haveMouse;
  NSArray<NSString *> *lnames = _localNames;
  NSArray<KKLinkExpr *> *lexprs = _localExprs;
  NSDictionary<NSString *, NSNumber *> *divisors = _uniformDivisors;
  NSArray<NSNumber *> *_Nullable (^provider)(NSString *) = _laneValueProvider;
  NSArray<NSNumber *> *_Nullable (^fracProvider)(NSString *, double) =
      _laneValuesAtFractionProvider;
  CGSize (^mediaProvider)(void) = _mediaSizeProvider;
  double evalFrac = frac;
  NSMutableDictionary<NSString *, NSValue *> *localVals =
      [NSMutableDictionary dictionary];
  KKExprVal (^base)(NSString *) = ^KKExprVal(NSString *nm) {
    if ([nm isEqualToString:binds])
      return bound;
    NSValue *xv = extra[nm];
    if (xv) {
      KKExprVal v;
      [xv getValue:&v size:sizeof(v)];
      return v;
    }
    if ([nm isEqualToString:@"tr"])
      return (KKExprVal){{1, 1, 0, 0}, 2};
    if ([nm isEqualToString:@"tl"])
      return (KKExprVal){{0, 1, 0, 0}, 2};
    if ([nm isEqualToString:@"bl"])
      return (KKExprVal){{0, 0, 0, 0}, 2};
    if ([nm isEqualToString:@"br"])
      return (KKExprVal){{1, 0, 0, 0}, 2};
    if ([nm isEqualToString:@"center"])
      return (KKExprVal){{0.5, 0.5, 0, 0}, 2};
    if ([nm isEqualToString:@"aspect"])
      return KKExprScalar(ax);
    if ([nm isEqualToString:@"size"]) {
      CGSize sz = mediaProvider ? mediaProvider() : CGSizeZero;
      return (KKExprVal){{sz.width, sz.height, 0, 0}, 2};
    }
    if ([nm isEqualToString:@"pos"] || [nm isEqualToString:@"mouse"])
      return (KKExprVal){{hm ? m.x : 0, hm ? m.y : 0, 0, 0}, 2};
    NSValue *lv = localVals[nm];
    if (lv) {
      KKExprVal v;
      [lv getValue:&v size:sizeof(v)];
      return v;
    }
    NSNumber *div = divisors[nm];
    if (div && (provider || fracProvider)) {
      // A per-fraction provider (position-warp path sampling) wins when the
      // caller supplied a fraction; else the plain tick provider.
      NSArray<NSNumber *> *raw = (fracProvider && evalFrac >= 0.0)
                                     ? fracProvider(nm, evalFrac)
                                     : (provider ? provider(nm) : nil);
      if (raw.count) {
        KKExprVal v = {{0, 0, 0, 0}, (int)MIN(raw.count, (NSUInteger)4)};
        double d = div.doubleValue > 0 ? div.doubleValue : 1.0;
        for (int i = 0; i < v.n; i++)
          v.v[i] = raw[(NSUInteger)i].doubleValue / d;
        return v;
      }
    }
    return KKExprScalar(0.0);
  };
  for (NSUInteger k = 0; k < lnames.count; k++) {
    KKExprVal v = [lexprs[k] evalWithValue:bound vars:base];
    localVals[lnames[k]] = [NSValue valueWithBytes:&v
                                          objCType:@encode(KKExprVal)];
  }
  return base;
}

- (simd_float2)objectPointForBound:(KKExprVal)bound
                            aspect:(double)aspect
                             mouse:(simd_float2)mouse
                         haveMouse:(BOOL)haveMouse {
  return [self objectPointForBound:bound
                            aspect:aspect
                             mouse:mouse
                         haveMouse:haveMouse
                          fraction:-1.0];
}

- (simd_float2)objectPointForBound:(KKExprVal)bound
                            aspect:(double)aspect
                             mouse:(simd_float2)mouse
                         haveMouse:(BOOL)haveMouse
                          fraction:(double)fraction {
  KKExprVal p = [_forward evalWithValue:bound
                                   vars:[self _varsForBound:bound
                                                     aspect:aspect
                                                      mouse:mouse
                                                  haveMouse:haveMouse
                                                      extra:nil
                                                       frac:fraction]];
  return (simd_float2){(float)p.v[0], (float)p.v[1]};
}

+ (simd_float2)handleObjectPointForRuntime:(MirageOSCBlockRuntime *)runtime
                                laneValues:(NSArray<NSNumber *> *)values
                                    aspect:(double)aspect {
  KKExprVal bound = [runtime boundValueFromLaneValues:values];
  if ([runtime.primitive isEqualToString:@"position"]) {
    // A remapped position (authored toPos/fromPos) sits where its forward puts
    // it, not at its raw value - otherwise an offset-valued lane would offer a
    // snap target at the frame origin while its handle is drawn elsewhere.
    if (runtime.hasForward && runtime.hasInverse)
      return [runtime objectPointForBound:bound
                                   aspect:aspect
                                    mouse:(simd_float2){0, 0}
                                haveMouse:NO];
    return (simd_float2){(float)bound.v[0],
                         (float)(bound.n >= 2 ? bound.v[1] : bound.v[0])};
  }
  return [runtime objectPointForBound:bound
                               aspect:aspect
                                mouse:(simd_float2){0, 0}
                            haveMouse:NO];
}

+ (NSArray<NSValue *> *)
    snapTargetsForRuntimes:(NSArray<MirageOSCBlockRuntime *> *)runtimes
            excludingBinds:(NSString *)excludeBinds
                    aspect:(double)aspect
                laneValues:
                    (NSArray<NSNumber *> * (^)(NSString *binds))laneValues {
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (MirageOSCBlockRuntime *b in runtimes) {
    if (![b.primitive isEqualToString:@"point"] &&
        ![b.primitive isEqualToString:@"position"])
      continue;
    if (excludeBinds && [b.binds isEqualToString:excludeBinds])
      continue;
    simd_float2 o = [self handleObjectPointForRuntime:b
                                           laneValues:laneValues(b.binds)
                                               aspect:aspect];
    [out addObject:[NSValue valueWithPoint:NSMakePoint(o.x, o.y)]];
  }
  return out;
}

- (KKExprVal)invertBoundForObjectPoint:(simd_float2)target
                                aspect:(double)aspect {
  double lo = _exprMin, hi = _exprMax;
  if (!(hi > lo))
    return KKExprScalar(lo);
  double ax = aspect > 0 ? aspect : 1.0;
  double (^dist)(double) = ^double(double v) {
    simd_float2 p = [self objectPointForBound:KKExprScalar(v)
                                       aspect:aspect
                                        mouse:(simd_float2){0, 0}
                                    haveMouse:NO];
    double dx = (p.x - target.x) * ax, dy = p.y - target.y;
    return dx * dx + dy * dy;
  };
  const double gr = 0.6180339887498949;
  double c = hi - (hi - lo) * gr, d = lo + (hi - lo) * gr;
  double fc = dist(c), fd = dist(d);
  for (int i = 0; i < 40 && (hi - lo) > 1e-5; i++) {
    if (fc < fd) {
      hi = d;
      d = c;
      fd = fc;
      c = hi - (hi - lo) * gr;
      fc = dist(c);
    } else {
      lo = c;
      c = d;
      fc = fd;
      d = lo + (hi - lo) * gr;
      fd = dist(d);
    }
  }
  return KKExprScalar((lo + hi) * 0.5);
}

- (KKExprVal)inverseBoundForObjectMouse:(simd_float2)mouse
                               boundNow:(KKExprVal)boundNow
                                 aspect:(double)aspect {
  return [self inverseBoundForObjectMouse:mouse
                                 boundNow:boundNow
                                   aspect:aspect
                                 fraction:-1.0];
}

- (KKExprVal)inverseBoundForObjectMouse:(simd_float2)mouse
                               boundNow:(KKExprVal)boundNow
                                 aspect:(double)aspect
                               fraction:(double)fraction {
  return [_inverse evalWithValue:boundNow
                            vars:[self _varsForBound:boundNow
                                              aspect:aspect
                                               mouse:mouse
                                           haveMouse:YES
                                               extra:nil
                                                frac:fraction]];
}

- (NSArray<NSNumber *> *)laneValuesFromBound:(KKExprVal)bound {
  double div = _divisor > 0 ? _divisor : 1.0;
  NSMutableArray<NSNumber *> *values = [NSMutableArray array];
  for (int i = 0; i < MAX(1, _fieldCount); i++) {
    double lane = (i < bound.n ? bound.v[i] : 0.0) * div;
    lane = MAX(_laneMin, MIN(_laneMax, lane));
    if (_isInt)
      lane = round(lane);
    [values addObject:@(lane)];
  }
  return values;
}

- (simd_float2)centerObjectForBound:(KKExprVal)bound aspect:(double)aspect {
  if (!_center)
    return (simd_float2){0.5f, 0.5f};
  KKExprVal c = [_center evalWithValue:bound
                                  vars:[self _varsForBound:bound
                                                    aspect:aspect
                                                     mouse:(simd_float2){0, 0}
                                                 haveMouse:NO
                                                     extra:nil
                                                      frac:-1.0]];
  return (simd_float2){(float)c.v[0], (float)c.v[1]};
}

- (KKExprVal)ringRadiiForBound:(KKExprVal)bound aspect:(double)aspect {
  KKExprVal radii =
      [_forward evalWithValue:bound
                         vars:[self _varsForBound:bound
                                           aspect:aspect
                                            mouse:(simd_float2){0, 0}
                                        haveMouse:NO
                                            extra:nil
                                             frac:-1.0]];
  for (int i = 0; i < radii.n; i++)
    radii.v[i] = fabs(radii.v[i]);
  return radii;
}

// `fromR` with the dragged radii bound to `r`.
- (KKExprVal)_ringInverseWithR:(KKExprVal)r
                      boundNow:(KKExprVal)boundNow
                        aspect:(double)aspect {
  NSDictionary<NSString *, NSValue *> *extra =
      @{@"r" : [NSValue valueWithBytes:&r objCType:@encode(KKExprVal)]};
  return [_inverse evalWithValue:boundNow
                            vars:[self _varsForBound:boundNow
                                              aspect:aspect
                                               mouse:(simd_float2){0, 0}
                                           haveMouse:NO
                                               extra:extra
                                                frac:-1.0]];
}

- (KKExprVal)boxRectForBound:(KKExprVal)bound aspect:(double)aspect {
  KKExprVal r = [_forward evalWithValue:bound
                                   vars:[self _varsForBound:bound
                                                     aspect:aspect
                                                      mouse:(simd_float2){0, 0}
                                                  haveMouse:NO
                                                      extra:nil
                                                       frac:-1.0]];
  // Normalize to min <= max so a negative-extent authoring mistake still
  // yields a drawable rect.
  KKExprVal out = {{MIN(r.v[0], r.v[2]), MIN(r.v[1], r.v[3]),
                    MAX(r.v[0], r.v[2]), MAX(r.v[1], r.v[3])},
                   4};
  return out;
}

- (KKExprVal)boxBoundForRect:(KKExprVal)rect
                    boundNow:(KKExprVal)boundNow
                      aspect:(double)aspect {
  if (!_inverse)
    return boundNow;
  NSDictionary<NSString *, NSValue *> *extra =
      @{@"rect" : [NSValue valueWithBytes:&rect objCType:@encode(KKExprVal)]};
  return [_inverse evalWithValue:boundNow
                            vars:[self _varsForBound:boundNow
                                              aspect:aspect
                                               mouse:(simd_float2){0, 0}
                                           haveMouse:NO
                                               extra:extra
                                                frac:-1.0]];
}

- (KKExprVal)boxCenteredBoundForObjectMouse:(simd_float2)m
                                     corner:(BOOL)isCorner
                                  controlsX:(BOOL)controlsX
                                 pressBound:(KKExprVal)press
                            linkedEffective:(BOOL)linked
                                     aspect:(double)aspect {
  if (!_inverse)
    return press;
  simd_float2 c = [self centerObjectForBound:press aspect:aspect];
  KKExprVal pr = [self boxRectForBound:press aspect:aspect];
  double peX = (pr.v[2] - pr.v[0]) * 0.5, peY = (pr.v[3] - pr.v[1]) * 0.5;
  double ox = fabs(m.x - c.x), oy = fabs(m.y - c.y);
  BOOL scalarLane = _fieldCount < 2;
  double ex, ey;
  if (scalarLane) {
    // One value: an edge drives its own axis into BOTH slots (so a
    // max()-style inverse tracks it 1:1); a corner leaves both offsets.
    if (isCorner) {
      ex = ox;
      ey = oy;
    } else if (controlsX) {
      ex = ey = ox;
    } else {
      ex = ey = oy;
    }
  } else {
    // Two values: a driven axis takes the cursor's distance from the fixed
    // centre (grow AND shrink), a held axis keeps its press extent.
    ex = (isCorner || controlsX) ? ox : peX;
    ey = (isCorner || !controlsX) ? oy : peY;
  }
  KKExprVal candRect = {{c.x - ex, c.y - ey, c.x + ex, c.y + ey}, 4};
  KKExprVal cand = [self boxBoundForRect:candRect boundNow:press aspect:aspect];
  if (scalarLane)
    return cand;
  // The scale-box coupling on the two candidates (mirrors KKBoxOSCDragValues):
  // a corner drives both axes (ONE factor when linked, else free); an edge
  // drives one (the other follows by ratio when linked, else holds at press).
  double px = press.n >= 1 ? press.v[0] : 0;
  double py = press.n >= 2 ? press.v[1] : 0;
  double cx = cand.v[0];
  double cy = cand.n >= 2 ? cand.v[1] : cand.v[0];
  BOOL haveRatio = fabs(px) > 1e-6 && fabs(py) > 1e-6;
  double nx = px, ny = py;
  if (isCorner) {
    if (linked && haveRatio) {
      double f = sqrt(fabs((cx / px) * (cy / py)));
      nx = px * f;
      ny = py * f;
    } else {
      nx = cx;
      ny = cy;
    }
  } else if (controlsX) {
    nx = cx;
    ny = linked ? (haveRatio ? py * (cx / px) : cx) : py;
  } else {
    ny = cy;
    nx = linked ? (haveRatio ? px * (cy / py) : cy) : px;
  }
  return (KKExprVal){{nx, ny, 0, 0}, 2};
}

+ (NSString *)boxReadoutForValues:(NSArray<NSNumber *> *)values
                            units:(NSArray<NSString *> *)units
                  scalesWithMedia:(BOOL)scalesWithMedia
                        mediaSize:(CGSize)media {
  if (values.count < 2)
    return @"";
  BOOL mediaValid = media.width > 0 && media.height > 0;
  NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:2];
  for (int i = 0; i < 2; i++) {
    double v = values[i].doubleValue;
    NSString *u = (i < (int)units.count) ? units[i] : nil; // px / % / "" / nil
    // Same rule as the lane fields' componentScale: "%" is a literal percent,
    // an EXPLICIT empty-string component is a raw fraction, and "px" (or an
    // absent units entry, the legacy scale-all default) media-scales.
    if ([u isEqualToString:@"%"]) {
      [parts addObject:[NSString stringWithFormat:@"%.0f%%", v]];
    } else if (u != nil && u.length == 0) {
      [parts addObject:[NSString
                           stringWithFormat:@"%g", round(v * 100.0) / 100.0]];
    } else if (scalesWithMedia && mediaValid) {
      double px = v * (i == 0 ? media.width : media.height);
      [parts addObject:[NSString stringWithFormat:@"%.0f", px]];
    } else {
      [parts addObject:[NSString
                           stringWithFormat:@"%g", round(v * 100.0) / 100.0]];
    }
  }
  return [parts componentsJoinedByString:@" x "];
}

+ (NSArray<NSNumber *> *)cropModelFromRect:(KKExprVal)rect {
  double w = rect.v[2] - rect.v[0], h = rect.v[3] - rect.v[1];
  double cx = (rect.v[0] + rect.v[2]) * 0.5, cy = (rect.v[1] + rect.v[3]) * 0.5;
  return @[ @(w), @(h), @(cx - 0.5), @(0.5 - cy) ];
}

+ (KKExprVal)rectFromCropModel:(NSArray<NSNumber *> *)values {
  double w = values.count > 0 ? values[0].doubleValue : 1.0;
  double h = values.count > 1 ? values[1].doubleValue : 1.0;
  double x = values.count > 2 ? values[2].doubleValue : 0.0;
  double y = values.count > 3 ? values[3].doubleValue : 0.0;
  double cx = 0.5 + x, cy = 0.5 - y;
  return (KKExprVal){{cx - w * 0.5, cy - h * 0.5, cx + w * 0.5, cy + h * 0.5},
                     4};
}

- (KKExprVal)ringBoundForDragOffset:(simd_float2)off
                        pressOffset:(simd_float2)pressOff
                         pressBound:(KKExprVal)pressBound
                    linkedEffective:(BOOL)linkedEffective
                             aspect:(double)aspect {
  if (!_inverse)
    return pressBound;
  if (_fieldCount < 2) {
    // Circle: the edge tracks the cursor's radial distance.
    return [self _ringInverseWithR:KKExprScalar(hypot(off.x, off.y))
                          boundNow:pressBound
                            aspect:aspect];
  }
  if (linkedEffective) {
    // Locked ellipse: scale BOTH components by ONE factor (how far the cursor
    // is relative to the press ellipse's edge in the drag direction), so the
    // ratio at press is preserved and every grab angle is well-defined.
    KKExprVal rs = [self ringRadiiForBound:pressBound aspect:aspect];
    double rsx = rs.v[0], rsy = rs.n >= 2 ? rs.v[1] : rs.v[0];
    double ex = rsx > 1e-6 ? off.x / rsx : 0;
    double ey = rsy > 1e-6 ? off.y / rsy : 0;
    double s = hypot(ex, ey);
    KKExprVal out = pressBound;
    out.n = _fieldCount;
    for (int i = 0; i < out.n; i++)
      out.v[i] = (i < pressBound.n ? pressBound.v[i] : 0.0) * s;
    return out;
  }
  // Unlinked: per-axis via `fromR`; an axis grabbed near its cardinal (press
  // offset small vs the grab distance) is held at its press value.
  KKExprVal cand =
      [self _ringInverseWithR:(KKExprVal){{fabs(off.x), fabs(off.y), 0, 0}, 2}
                     boundNow:pressBound
                       aspect:aspect];
  static const double kCardinalFrac = 0.25;
  double minComp = kCardinalFrac * hypot(pressOff.x, pressOff.y);
  KKExprVal out = cand;
  out.n = _fieldCount;
  if (fabs(pressOff.x) <= minComp)
    out.v[0] = pressBound.n >= 1 ? pressBound.v[0] : 0.0;
  if (out.n >= 2 && fabs(pressOff.y) <= minComp)
    out.v[1] = pressBound.n >= 2 ? pressBound.v[1] : 0.0;
  return out;
}

@end
