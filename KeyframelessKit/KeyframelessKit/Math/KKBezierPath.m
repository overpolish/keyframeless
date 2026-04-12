/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKBezierPath.h"

static const NSUInteger kArcLengthSamples = 64;

static simd_float2 evalCubicBezier(simd_float2 p0, simd_float2 c0,
                                   simd_float2 c1, simd_float2 p1, float t) {
  float u = 1.0f - t;
  return u * u * u * p0 + 3.0f * u * u * t * c0 + 3.0f * u * t * t * c1 +
         t * t * t * p1;
}

@implementation KKBezierPath {
  KKBezierPoint *_points;
  NSUInteger _count;
  NSUInteger _capacity;
}

+ (instancetype)pathWithData:(NSData *)data {
  KKBezierPath *path = [[KKBezierPath alloc] init];
  if (data.length >= 4) {
    const uint8_t *bytes = data.bytes;
    uint32_t count;
    memcpy(&count, bytes, 4);
    size_t pointSize = sizeof(KKBezierPoint);

    // New format: 4 bytes count + 1 byte flags + points
    size_t newExpected = 5 + count * pointSize;
    // Old format: 4 bytes count + points (no flags)
    size_t oldExpected = 4 + count * pointSize;

    if (data.length >= newExpected && count > 0) {
      uint8_t flags = bytes[4];
      path->_closed = (flags & 1) != 0;
      path->_count = count;
      path->_capacity = count;
      path->_points = malloc(count * pointSize);
      memcpy(path->_points, bytes + 5, count * pointSize);
      // Extended: corner radius after points
      size_t extOffset = 5 + count * pointSize;
      if ((flags & 2) && data.length >= extOffset + sizeof(float)) {
        memcpy(&path->_cornerRadius, bytes + extOffset, sizeof(float));
      }
    } else if (data.length >= oldExpected && count > 0) {
      path->_count = count;
      path->_capacity = count;
      path->_points = malloc(count * pointSize);
      memcpy(path->_points, bytes + 4, count * pointSize);
    }
  }
  return path;
}

- (NSData *)dataRepresentation {
  uint32_t count = (uint32_t)_count;
  uint8_t flags = _closed ? 1 : 0;
  if (_cornerRadius > 0)
    flags |= 2;
  size_t pointSize = sizeof(KKBezierPoint);
  NSMutableData *data = [NSMutableData
      dataWithCapacity:4 + 1 + count * pointSize + sizeof(float)];
  [data appendBytes:&count length:4];
  [data appendBytes:&flags length:1];
  if (count > 0)
    [data appendBytes:_points length:count * pointSize];
  if (flags & 2)
    [data appendBytes:&_cornerRadius length:sizeof(float)];
  return data;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _points = NULL;
    _count = 0;
    _capacity = 0;
  }
  return self;
}

- (void)dealloc {
  free(_points);
}

- (NSUInteger)segmentCount {
  return _count + 1;
}

- (KKBezierPoint)pointAtIndex:(NSUInteger)index {
  return _points[index];
}

- (void)ensureCapacity:(NSUInteger)needed {
  if (_capacity >= needed)
    return;
  NSUInteger newCap = MAX(needed, _capacity * 2);
  if (newCap < 4)
    newCap = 4;
  _points = realloc(_points, newCap * sizeof(KKBezierPoint));
  _capacity = newCap;
}

- (void)insertAtIndex:(NSUInteger)index position:(simd_float2)pos {
  [self ensureCapacity:_count + 1];
  if (index < _count)
    memmove(&_points[index + 1], &_points[index],
            (_count - index) * sizeof(KKBezierPoint));
  _points[index] = (KKBezierPoint){
      .x = pos.x,
      .y = pos.y,
      .type = KKBezierPointLinear,
  };
  _count++;
}

- (void)removeAtIndex:(NSUInteger)index {
  if (index < _count - 1)
    memmove(&_points[index], &_points[index + 1],
            (_count - index - 1) * sizeof(KKBezierPoint));
  _count--;
}

- (void)moveAtIndex:(NSUInteger)index to:(simd_float2)pos {
  _points[index].x = pos.x;
  _points[index].y = pos.y;
}

- (void)setInHandle:(simd_float2)offset atIndex:(NSUInteger)index {
  _points[index].inX = offset.x;
  _points[index].inY = offset.y;
}

- (void)setOutHandle:(simd_float2)offset atIndex:(NSUInteger)index {
  _points[index].outX = offset.x;
  _points[index].outY = offset.y;
}

- (void)setType:(KKBezierPointType)type atIndex:(NSUInteger)index {
  if (index < _count)
    _points[index].type = type;
}

- (void)translateBy:(simd_float2)delta {
  for (NSUInteger i = 0; i < _count; i++) {
    _points[i].x += delta.x;
    _points[i].y += delta.y;
  }
}

- (void)setRoundedRectWithMin:(simd_float2)min
                          max:(simd_float2)max
                      radiusX:(float)rx
                      radiusY:(float)ry {
  float maxRX = (max.x - min.x) * 0.5f;
  float maxRY = (max.y - min.y) * 0.5f;
  rx = fminf(rx, maxRX);
  ry = fminf(ry, maxRY);

  if (rx < 0.0001f || ry < 0.0001f) {
    _cornerRadius = 0;
    [self ensureCapacity:4];
    _count = 4;
    _closed = YES;
    _points[0] = (KKBezierPoint){min.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[1] = (KKBezierPoint){max.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[2] = (KKBezierPoint){max.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[3] = (KKBezierPoint){min.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
    return;
  }

  // Store the pixel-space radius (ry maps more directly to visual size)
  _cornerRadius = ry;

  float kx = rx * 0.5522847498f;
  float ky = ry * 0.5522847498f;
  [self ensureCapacity:8];
  _count = 8;
  _closed = YES;

  // Top-left corner (clockwise from left side)
  _points[0] =
      (KKBezierPoint){min.x, max.y - ry, 0, -ky, 0, ky, KKBezierPointBezier};
  _points[1] =
      (KKBezierPoint){min.x + rx, max.y, -kx, 0, kx, 0, KKBezierPointBezier};
  // Top-right corner
  _points[2] =
      (KKBezierPoint){max.x - rx, max.y, -kx, 0, kx, 0, KKBezierPointBezier};
  _points[3] =
      (KKBezierPoint){max.x, max.y - ry, 0, ky, 0, -ky, KKBezierPointBezier};
  // Bottom-right corner
  _points[4] =
      (KKBezierPoint){max.x, min.y + ry, 0, ky, 0, -ky, KKBezierPointBezier};
  _points[5] =
      (KKBezierPoint){max.x - rx, min.y, kx, 0, -kx, 0, KKBezierPointBezier};
  // Bottom-left corner
  _points[6] =
      (KKBezierPoint){min.x + rx, min.y, kx, 0, -kx, 0, KKBezierPointBezier};
  _points[7] =
      (KKBezierPoint){min.x, min.y + ry, 0, -ky, 0, ky, KKBezierPointBezier};
}

- (void)toggleTypeAtIndex:(NSUInteger)index
                    start:(simd_float2)start
                      end:(simd_float2)end {
  KKBezierPoint *pt = &_points[index];
  if (pt->type == KKBezierPointBezier) {
    pt->type = KKBezierPointLinear;
    pt->inX = pt->inY = pt->outX = pt->outY = 0;
    return;
  }

  pt->type = KKBezierPointBezier;
  simd_float2 pos = {pt->x, pt->y};
  simd_float2 prev =
      (index > 0) ? (simd_float2){_points[index - 1].x, _points[index - 1].y}
                  : start;
  simd_float2 next = (index < _count - 1) ? (simd_float2){_points[index + 1].x,
                                                          _points[index + 1].y}
                                          : end;

  simd_float2 dir = next - prev;
  float len = simd_length(dir);
  if (len < 0.0001f) {
    pt->inX = pt->inY = pt->outX = pt->outY = 0;
    return;
  }
  dir /= len;
  float distPrev = simd_length(pos - prev);
  float distNext = simd_length(pos - next);
  simd_float2 inH = -dir * distPrev / 3.0f;
  simd_float2 outH = dir * distNext / 3.0f;
  pt->inX = inH.x;
  pt->inY = inH.y;
  pt->outX = outH.x;
  pt->outY = outH.y;
}

- (void)segmentEndpoints:(NSUInteger)segIndex
                   start:(simd_float2)start
                     end:(simd_float2)end
                      p0:(simd_float2 *)p0
                    outH:(simd_float2 *)outH
                   type0:(KKBezierPointType *)type0
                      p1:(simd_float2 *)p1
                     inH:(simd_float2 *)inH
                   type1:(KKBezierPointType *)type1 {
  if (segIndex == 0) {
    *p0 = start;
    *outH = (simd_float2){0, 0};
    *type0 = KKBezierPointLinear;
  } else {
    KKBezierPoint pt = _points[segIndex - 1];
    *p0 = (simd_float2){pt.x, pt.y};
    *outH = (simd_float2){pt.outX, pt.outY};
    *type0 = (KKBezierPointType)pt.type;
  }
  if (segIndex == _count) {
    *p1 = end;
    *inH = (simd_float2){0, 0};
    *type1 = KKBezierPointLinear;
  } else {
    KKBezierPoint pt = _points[segIndex];
    *p1 = (simd_float2){pt.x, pt.y};
    *inH = (simd_float2){pt.inX, pt.inY};
    *type1 = (KKBezierPointType)pt.type;
  }
}

- (simd_float2)evalFrom:(simd_float2)p0
                   outH:(simd_float2)outH
                  type0:(KKBezierPointType)type0
                     to:(simd_float2)p1
                    inH:(simd_float2)inH
                  type1:(KKBezierPointType)type1
                    atT:(float)t {
  if (type0 == KKBezierPointLinear && type1 == KKBezierPointLinear)
    return p0 + t * (p1 - p0);
  return evalCubicBezier(p0, p0 + outH, p1 + inH, p1, t);
}

- (simd_float2)evaluateSegment:(NSUInteger)segIndex
                           atT:(float)t
                         start:(simd_float2)start
                           end:(simd_float2)end {
  simd_float2 p0, p1, outH, inH;
  KKBezierPointType type0, type1;
  [self segmentEndpoints:segIndex
                   start:start
                     end:end
                      p0:&p0
                    outH:&outH
                   type0:&type0
                      p1:&p1
                     inH:&inH
                   type1:&type1];
  return [self evalFrom:p0
                   outH:outH
                  type0:type0
                     to:p1
                    inH:inH
                  type1:type1
                    atT:t];
}

- (simd_float2)evaluatePointAtIndex:(NSUInteger)index
                          nextIndex:(NSUInteger)nextIndex
                                atT:(float)t {
  if (index >= _count || nextIndex >= _count)
    return (simd_float2){0, 0};
  KKBezierPoint p0 = _points[index];
  KKBezierPoint p1 = _points[nextIndex];
  simd_float2 a = {p0.x, p0.y};
  simd_float2 cp0 = {p0.x + p0.outX, p0.y + p0.outY};
  simd_float2 cp1 = {p1.x + p1.inX, p1.y + p1.inY};
  simd_float2 b = {p1.x, p1.y};
  if (p0.type == KKBezierPointLinear && p1.type == KKBezierPointLinear)
    return a + t * (b - a);
  return evalCubicBezier(a, cp0, cp1, b, t);
}

- (simd_float2)evaluateTangentAtIndex:(NSUInteger)index
                            nextIndex:(NSUInteger)nextIndex
                                  atT:(float)t {
  if (index >= _count || nextIndex >= _count)
    return (simd_float2){1, 0};
  KKBezierPoint p0 = _points[index];
  KKBezierPoint p1 = _points[nextIndex];
  simd_float2 a = {p0.x, p0.y};
  simd_float2 cp0 = {p0.x + p0.outX, p0.y + p0.outY};
  simd_float2 cp1 = {p1.x + p1.inX, p1.y + p1.inY};
  simd_float2 b = {p1.x, p1.y};
  if (p0.type == KKBezierPointLinear && p1.type == KKBezierPointLinear)
    return b - a;
  float u = 1.0f - t;
  return 3.0f * u * u * (cp0 - a) + 6.0f * u * t * (cp1 - cp0) +
         3.0f * t * t * (b - cp1);
}

- (simd_float2)positionAtT:(float)t
                     start:(simd_float2)start
                       end:(simd_float2)end {
  NSUInteger segCount = _count + 1;

  if (_count == 0)
    return start + t * (end - start);

  // Build arc-length lookup table
  NSUInteger totalSamples = segCount * kArcLengthSamples;
  simd_float2 *samplePos = malloc((totalSamples + 1) * sizeof(simd_float2));
  float *cumulLen = malloc((totalSamples + 1) * sizeof(float));

  samplePos[0] = start;
  cumulLen[0] = 0;

  for (NSUInteger seg = 0; seg < segCount; seg++) {
    simd_float2 p0, p1, outH, inH;
    KKBezierPointType type0, type1;
    [self segmentEndpoints:seg
                     start:start
                       end:end
                        p0:&p0
                      outH:&outH
                     type0:&type0
                        p1:&p1
                       inH:&inH
                     type1:&type1];

    for (NSUInteger s = 1; s <= kArcLengthSamples; s++) {
      float localT = (float)s / (float)kArcLengthSamples;
      NSUInteger idx = seg * kArcLengthSamples + s;
      samplePos[idx] = [self evalFrom:p0
                                 outH:outH
                                type0:type0
                                   to:p1
                                  inH:inH
                                type1:type1
                                  atT:localT];
      cumulLen[idx] =
          cumulLen[idx - 1] + simd_length(samplePos[idx] - samplePos[idx - 1]);
    }
  }

  float totalLength = cumulLen[totalSamples];
  simd_float2 result;

  if (totalLength < 0.0001f) {
    result = start;
  } else {
    float targetLen = t * totalLength;

    // Binary search
    NSUInteger lo = 0, hi = totalSamples;
    while (lo < hi) {
      NSUInteger mid = (lo + hi) / 2;
      if (cumulLen[mid] < targetLen)
        lo = mid + 1;
      else
        hi = mid;
    }

    if (lo == 0) {
      result = samplePos[0];
    } else {
      float frac = (cumulLen[lo] > cumulLen[lo - 1])
                       ? (targetLen - cumulLen[lo - 1]) /
                             (cumulLen[lo] - cumulLen[lo - 1])
                       : 0.0f;
      result = samplePos[lo - 1] + frac * (samplePos[lo] - samplePos[lo - 1]);
    }
  }

  free(samplePos);
  free(cumulLen);
  return result;
}

@end
