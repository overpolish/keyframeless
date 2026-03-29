/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "MagicMovePath.h"

static const NSUInteger kArcLengthSamples = 64;

static simd_float2 evalCubicBezier(simd_float2 p0, simd_float2 c0,
                                   simd_float2 c1, simd_float2 p1, float t) {
  float u = 1.0f - t;
  return u * u * u * p0 + 3.0f * u * u * t * c0 + 3.0f * u * t * t * c1 +
         t * t * t * p1;
}

@implementation MagicMovePath {
  MagicMovePathPoint *_points;
  NSUInteger _count;
  NSUInteger _capacity;
}

+ (instancetype)pathWithData:(NSData *)data {
  MagicMovePath *path = [[MagicMovePath alloc] init];
  if (data.length >= 4) {
    const uint8_t *bytes = data.bytes;
    uint32_t count;
    memcpy(&count, bytes, 4);
    size_t pointSize = sizeof(MagicMovePathPoint);
    size_t expected = 4 + count * pointSize;
    if (data.length >= expected && count > 0) {
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
  size_t pointSize = sizeof(MagicMovePathPoint);
  NSMutableData *data = [NSMutableData dataWithCapacity:4 + count * pointSize];
  [data appendBytes:&count length:4];
  if (count > 0)
    [data appendBytes:_points length:count * pointSize];
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

- (MagicMovePathPoint)pointAtIndex:(NSUInteger)index {
  return _points[index];
}

- (void)ensureCapacity:(NSUInteger)needed {
  if (_capacity >= needed)
    return;
  NSUInteger newCap = MAX(needed, _capacity * 2);
  if (newCap < 4)
    newCap = 4;
  _points = realloc(_points, newCap * sizeof(MagicMovePathPoint));
  _capacity = newCap;
}

- (void)insertAtIndex:(NSUInteger)index position:(simd_float2)pos {
  [self ensureCapacity:_count + 1];
  if (index < _count)
    memmove(&_points[index + 1], &_points[index],
            (_count - index) * sizeof(MagicMovePathPoint));
  _points[index] = (MagicMovePathPoint){
      .x = pos.x,
      .y = pos.y,
      .type = MagicMovePathPointLinear,
  };
  _count++;
}

- (void)removeAtIndex:(NSUInteger)index {
  if (index < _count - 1)
    memmove(&_points[index], &_points[index + 1],
            (_count - index - 1) * sizeof(MagicMovePathPoint));
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

- (void)toggleTypeAtIndex:(NSUInteger)index
                    start:(simd_float2)start
                      end:(simd_float2)end {
  MagicMovePathPoint *pt = &_points[index];
  if (pt->type == MagicMovePathPointBezier) {
    pt->type = MagicMovePathPointLinear;
    pt->inX = pt->inY = pt->outX = pt->outY = 0;
    return;
  }

  pt->type = MagicMovePathPointBezier;
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
                   type0:(MagicMovePathPointType *)type0
                      p1:(simd_float2 *)p1
                     inH:(simd_float2 *)inH
                   type1:(MagicMovePathPointType *)type1 {
  if (segIndex == 0) {
    *p0 = start;
    *outH = (simd_float2){0, 0};
    *type0 = MagicMovePathPointLinear;
  } else {
    MagicMovePathPoint pt = _points[segIndex - 1];
    *p0 = (simd_float2){pt.x, pt.y};
    *outH = (simd_float2){pt.outX, pt.outY};
    *type0 = (MagicMovePathPointType)pt.type;
  }
  if (segIndex == _count) {
    *p1 = end;
    *inH = (simd_float2){0, 0};
    *type1 = MagicMovePathPointLinear;
  } else {
    MagicMovePathPoint pt = _points[segIndex];
    *p1 = (simd_float2){pt.x, pt.y};
    *inH = (simd_float2){pt.inX, pt.inY};
    *type1 = (MagicMovePathPointType)pt.type;
  }
}

- (simd_float2)evalFrom:(simd_float2)p0
                   outH:(simd_float2)outH
                  type0:(MagicMovePathPointType)type0
                     to:(simd_float2)p1
                    inH:(simd_float2)inH
                  type1:(MagicMovePathPointType)type1
                    atT:(float)t {
  if (type0 == MagicMovePathPointLinear && type1 == MagicMovePathPointLinear)
    return p0 + t * (p1 - p0);
  return evalCubicBezier(p0, p0 + outH, p1 + inH, p1, t);
}

- (simd_float2)evaluateSegment:(NSUInteger)segIndex
                           atT:(float)t
                         start:(simd_float2)start
                           end:(simd_float2)end {
  simd_float2 p0, p1, outH, inH;
  MagicMovePathPointType type0, type1;
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
    MagicMovePathPointType type0, type1;
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
