/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderOSCBlockRuntime.h"

#import "ShaderDirectives.h" // ShaderParseScalarProps + ShaderScalarProp
#import "ShaderOSCBlock.h"   // // @osc custom-handling blocks
#import <KeyframelessKit/KKResizeCursor.h>
#import <KeyframelessKit/KeyframelessKit.h> // KKLane

NSSet<NSString *> *ShaderOSCBaseVars(void) {
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

NSCursor *ShaderOSCCursorForName(NSString *name) {
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

@implementation ShaderOSCBlockRuntime {
  KKLinkExpr *_forward;
  KKLinkExpr *_inverse; // nil = numerically invert the forward
  NSArray<NSString *> *_localNames;
  NSArray<KKLinkExpr *> *_localExprs;
}

+ (NSArray<ShaderOSCBlockRuntime *> *)runtimesForSource:(NSString *)src
                                                  lanes:(NSArray<KKLane *> *)
                                                            lanes {
  if (src.length == 0)
    return @[];
  ShaderOSCBlock blocks[KK_SHADER_MAX_OSC_BLOCKS];
  int n = ShaderParseOSCBlocks(src, blocks, KK_SHADER_MAX_OSC_BLOCKS);
  if (n <= 0)
    return @[];
  ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int np =
      ShaderParseScalarProps(src, props, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);

  NSMutableArray<ShaderOSCBlockRuntime *> *out = [NSMutableArray array];
  for (int i = 0; i < n; i++) {
    ShaderOSCBlockRuntime *r = [self _runtimeForBlock:&blocks[i]
                                                props:props
                                                count:np
                                                lanes:lanes];
    if (r)
      [out addObject:r];
  }
  return out;
}

// Build one runtime from a parsed block: normalize the bound value from its
// directive, compile the locals in order (each sees the OSC builtins + the
// bound name + earlier locals), then the forward (required) + optional inverse.
// Drops the block (returns nil) on an unwired primitive or a compile failure.
+ (nullable ShaderOSCBlockRuntime *)
    _runtimeForBlock:(const ShaderOSCBlock *)blk
               props:(const ShaderScalarProp *)props
               count:(int)np
               lanes:(NSArray<KKLane *> *)lanes {
  NSString *name = @(blk->name);
  NSString *binds = @(blk->binds);
  if (name.length == 0 || binds.length == 0)
    return nil;
  if (strcmp(blk->primitive, "point") != 0) // only `point` wired so far
    return nil;

  ShaderOSCBlockRuntime *r = [ShaderOSCBlockRuntime new];
  r->_name = [name copy];
  r->_primitive = @(blk->primitive);
  r->_binds = [binds copy];
  r->_styleName = @(blk->style);
  r->_cursorName = @(blk->cursor);
  r->_fieldCount = 1;
  r->_divisor = 1.0;
  r->_laneMin = -1e9;
  r->_laneMax = 1e9;
  for (int k = 0; k < np; k++)
    if (strcmp(props[k].name, blk->binds) == 0) {
      r->_divisor = props[k].isPercent ? 100.0 : 1.0;
      r->_fieldCount = props[k].isMulti ? MAX(1, props[k].fieldCount) : 1;
      if (props[k].hasMin)
        r->_laneMin = props[k].fmin;
      if (props[k].hasMax)
        r->_laneMax = props[k].fmax;
      break;
    }
  for (KKLane *l in lanes)
    if ([l.label isEqualToString:binds]) {
      r->_templateLane = l;
      break;
    }
  double div = r->_divisor > 0 ? r->_divisor : 1.0;
  r->_exprMin = r->_laneMin / div;
  r->_exprMax = r->_laneMax / div;

  // Locals compile in order: each may use the OSC builtins, the bound name, and
  // EARLIER locals (so `allowed` grows). forward/inverse then see all locals.
  NSMutableSet<NSString *> *allowed =
      [[ShaderOSCBaseVars() setByAddingObject:binds] mutableCopy];
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
  r->_forward = [KKLinkExpr compile:@(blk->forward)
                        allowedVars:allowed
                              error:&err];
  if (!r->_forward)
    return nil;
  // Inverse is optional: empty means "numerically invert the forward".
  if (strlen(blk->inverse) > 0)
    r->_inverse = [KKLinkExpr compile:@(blk->inverse)
                          allowedVars:allowed
                                error:&err];
  return r;
}

- (BOOL)hasInverse {
  return _inverse != nil;
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
// drag) + the precomputed locals. Object space is 0..1, Y-up.
- (KKExprVal (^)(NSString *))_varsForBound:(KKExprVal)bound
                                    aspect:(double)aspect
                                     mouse:(simd_float2)mouse
                                 haveMouse:(BOOL)haveMouse {
  NSString *binds = _binds;
  double ax = aspect;
  simd_float2 m = mouse;
  BOOL hm = haveMouse;
  NSArray<NSString *> *lnames = _localNames;
  NSArray<KKLinkExpr *> *lexprs = _localExprs;
  NSMutableDictionary<NSString *, NSValue *> *localVals =
      [NSMutableDictionary dictionary];
  KKExprVal (^base)(NSString *) = ^KKExprVal(NSString *nm) {
    if ([nm isEqualToString:binds])
      return bound;
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
    if ([nm isEqualToString:@"pos"] || [nm isEqualToString:@"mouse"])
      return (KKExprVal){{hm ? m.x : 0, hm ? m.y : 0, 0, 0}, 2};
    NSValue *lv = localVals[nm];
    if (lv) {
      KKExprVal v;
      [lv getValue:&v size:sizeof(v)];
      return v;
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
  KKExprVal p = [_forward evalWithValue:bound
                                   vars:[self _varsForBound:bound
                                                     aspect:aspect
                                                      mouse:mouse
                                                  haveMouse:haveMouse]];
  return (simd_float2){(float)p.v[0], (float)p.v[1]};
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
  return [_inverse evalWithValue:boundNow
                            vars:[self _varsForBound:boundNow
                                              aspect:aspect
                                               mouse:mouse
                                           haveMouse:YES]];
}

- (NSArray<NSNumber *> *)laneValuesFromBound:(KKExprVal)bound {
  double div = _divisor > 0 ? _divisor : 1.0;
  NSMutableArray<NSNumber *> *values = [NSMutableArray array];
  for (int i = 0; i < MAX(1, _fieldCount); i++) {
    double lane = (i < bound.n ? bound.v[i] : 0.0) * div;
    lane = MAX(_laneMin, MIN(_laneMax, lane));
    [values addObject:@(lane)];
  }
  return values;
}

@end
