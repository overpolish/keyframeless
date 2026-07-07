/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKShape.h"
#import "KKBezierPath.h"

@implementation KKShape
- (KKShapeKind)kind {
  [NSException raise:NSInternalInconsistencyException
              format:@"KKShape is abstract"];
  return 0;
}
- (id)copyWithZone:(NSZone *)zone {
  return [[self.class allocWithZone:zone] init];
}
- (NSData *)serializedPayload {
  return nil;
}

+ (size_t)payloadByteCountForKind:(KKShapeKind)kind {
  switch (kind) {
  case KKShapeKindRect:
    return 32; // min:8 + max:8 + radii:16
  case KKShapeKindEllipse:
    return 16; // min:8 + max:8
  case KKShapeKindLine:
    return 16; // start:8 + end:8
  default:
    return 0;
  }
}

+ (instancetype)shapeWithKind:(KKShapeKind)kind
                        bytes:(const void *)bytes
                    available:(size_t)available {
  size_t need = [KKShape payloadByteCountForKind:kind];
  if (need == 0 || available < need)
    return nil;
  const uint8_t *b = bytes;
  switch (kind) {
  case KKShapeKindRect: {
    KKRectShape *r = [[KKRectShape alloc] init];
    simd_float2 mn, mx;
    float radii[4];
    memcpy(&mn, b + 0, sizeof(simd_float2));
    memcpy(&mx, b + 8, sizeof(simd_float2));
    memcpy(radii, b + 16, sizeof(radii));
    r.min = mn;
    r.max = mx;
    r.radiusTL = radii[0];
    r.radiusTR = radii[1];
    r.radiusBR = radii[2];
    r.radiusBL = radii[3];
    return (id)r;
  }
  case KKShapeKindEllipse: {
    KKEllipseShape *e = [[KKEllipseShape alloc] init];
    simd_float2 mn, mx;
    memcpy(&mn, b + 0, sizeof(simd_float2));
    memcpy(&mx, b + 8, sizeof(simd_float2));
    e.min = mn;
    e.max = mx;
    return (id)e;
  }
  case KKShapeKindLine: {
    KKLineShape *l = [[KKLineShape alloc] init];
    simd_float2 s, e;
    memcpy(&s, b + 0, sizeof(simd_float2));
    memcpy(&e, b + 8, sizeof(simd_float2));
    l.start = s;
    l.end = e;
    return (id)l;
  }
  default:
    return nil;
  }
}

+ (KKShape *)lerpFrom:(KKShape *)a to:(KKShape *)b t:(float)t {
  if (!a || !b || a.kind != b.kind)
    return nil;
  switch (a.kind) {
  case KKShapeKindRect: {
    KKRectShape *ar = (KKRectShape *)a, *br = (KKRectShape *)b;
    KKRectShape *out = [[KKRectShape alloc] init];
    out.min = ar.min + (br.min - ar.min) * t;
    out.max = ar.max + (br.max - ar.max) * t;
    out.radii = ar.radii + (br.radii - ar.radii) * t;
    return out;
  }
  case KKShapeKindEllipse: {
    KKEllipseShape *ae = (KKEllipseShape *)a, *be = (KKEllipseShape *)b;
    KKEllipseShape *out = [[KKEllipseShape alloc] init];
    out.min = ae.min + (be.min - ae.min) * t;
    out.max = ae.max + (be.max - ae.max) * t;
    return out;
  }
  case KKShapeKindLine: {
    KKLineShape *al = (KKLineShape *)a, *bl = (KKLineShape *)b;
    KKLineShape *out = [[KKLineShape alloc] init];
    out.start = al.start + (bl.start - al.start) * t;
    out.end = al.end + (bl.end - al.end) * t;
    return out;
  }
  default:
    return nil;
  }
}
@end

@implementation KKRectShape
- (KKShapeKind)kind {
  return KKShapeKindRect;
}
- (simd_float4)radii {
  return simd_make_float4(_radiusTL, _radiusTR, _radiusBR, _radiusBL);
}
- (void)setRadii:(simd_float4)v {
  _radiusTL = fmaxf(0.0f, fminf(v.x, 1.0f));
  _radiusTR = fmaxf(0.0f, fminf(v.y, 1.0f));
  _radiusBR = fmaxf(0.0f, fminf(v.z, 1.0f));
  _radiusBL = fmaxf(0.0f, fminf(v.w, 1.0f));
}
- (void)applyToPath:(KKBezierPath *)path
        canvasWidth:(float)canvasW
       canvasHeight:(float)canvasH {
  [path setRoundedRectWithMin:_min
                          max:_max
                   fractionTL:_radiusTL
                   fractionTR:_radiusTR
                   fractionBR:_radiusBR
                   fractionBL:_radiusBL
                  canvasWidth:canvasW
                 canvasHeight:canvasH];
}
- (id)copyWithZone:(NSZone *)zone {
  KKRectShape *c = [super copyWithZone:zone];
  c.min = self.min;
  c.max = self.max;
  c.radiusTL = self.radiusTL;
  c.radiusTR = self.radiusTR;
  c.radiusBR = self.radiusBR;
  c.radiusBL = self.radiusBL;
  return c;
}
- (NSData *)serializedPayload {
  NSMutableData *d = [NSMutableData dataWithCapacity:32];
  simd_float2 mn = _min, mx = _max;
  float radii[4] = {_radiusTL, _radiusTR, _radiusBR, _radiusBL};
  [d appendBytes:&mn length:sizeof(simd_float2)];
  [d appendBytes:&mx length:sizeof(simd_float2)];
  [d appendBytes:radii length:sizeof(radii)];
  return d;
}
@end

@implementation KKEllipseShape
- (KKShapeKind)kind {
  return KKShapeKindEllipse;
}
- (id)copyWithZone:(NSZone *)zone {
  KKEllipseShape *c = [super copyWithZone:zone];
  c.min = self.min;
  c.max = self.max;
  return c;
}
- (void)applyToPath:(KKBezierPath *)path
        canvasWidth:(float)canvasW
       canvasHeight:(float)canvasH {
  (void)canvasW;
  (void)canvasH;
  float cx = (_min.x + _max.x) * 0.5f, cy = (_min.y + _max.y) * 0.5f;
  float rx = (_max.x - _min.x) * 0.5f, ry = (_max.y - _min.y) * 0.5f;
  float kx = rx * 0.5522847498f, ky = ry * 0.5522847498f;
  KKBezierPoint pts[4] = {
      {.x = cx,
       .y = cy + ry,
       .inX = -kx,
       .inY = 0,
       .outX = kx,
       .outY = 0,
       .type = KKBezierPointBezier},
      {.x = cx + rx,
       .y = cy,
       .inX = 0,
       .inY = ky,
       .outX = 0,
       .outY = -ky,
       .type = KKBezierPointBezier},
      {.x = cx,
       .y = cy - ry,
       .inX = kx,
       .inY = 0,
       .outX = -kx,
       .outY = 0,
       .type = KKBezierPointBezier},
      {.x = cx - rx,
       .y = cy,
       .inX = 0,
       .inY = -ky,
       .outX = 0,
       .outY = ky,
       .type = KKBezierPointBezier},
  };
  [path setBezierPoints:pts count:4 closed:YES];
}
- (NSData *)serializedPayload {
  NSMutableData *d = [NSMutableData dataWithCapacity:16];
  simd_float2 mn = _min, mx = _max;
  [d appendBytes:&mn length:sizeof(simd_float2)];
  [d appendBytes:&mx length:sizeof(simd_float2)];
  return d;
}
@end

@implementation KKLineShape
- (KKShapeKind)kind {
  return KKShapeKindLine;
}
- (id)copyWithZone:(NSZone *)zone {
  KKLineShape *c = [super copyWithZone:zone];
  c.start = self.start;
  c.end = self.end;
  return c;
}
- (void)applyToPath:(KKBezierPath *)path
        canvasWidth:(float)canvasW
       canvasHeight:(float)canvasH {
  (void)canvasW;
  (void)canvasH;
  simd_float2 pts[2] = {_start, _end};
  [path setLinearPositions:pts count:2 closed:NO];
}
- (NSData *)serializedPayload {
  NSMutableData *d = [NSMutableData dataWithCapacity:16];
  simd_float2 s = _start, e = _end;
  [d appendBytes:&s length:sizeof(simd_float2)];
  [d appendBytes:&e length:sizeof(simd_float2)];
  return d;
}
@end

@implementation KKPolygonShape
- (KKShapeKind)kind {
  return KKShapeKindPolygon;
}
- (id)copyWithZone:(NSZone *)zone {
  KKPolygonShape *c = [super copyWithZone:zone];
  c.pointsData = self.pointsData;
  c.closed = self.closed;
  return c;
}
@end

@implementation KKBezierShape
- (KKShapeKind)kind {
  return KKShapeKindBezier;
}
- (id)copyWithZone:(NSZone *)zone {
  KKBezierShape *c = [super copyWithZone:zone];
  c.pointsData = self.pointsData;
  c.closed = self.closed;
  return c;
}
@end
