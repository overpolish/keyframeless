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

    BOOL maybeGroup = (data.length >= 5 && (bytes[4] & 128) != 0);
    if (data.length >= newExpected && (count > 0 || maybeGroup)) {
      uint8_t flags = bytes[4];
      path->_closed = (flags & 1) != 0;
      path->_isRect = (flags & 8) != 0;
      path->_hidden = (flags & 16) != 0;
      path->_locked = (flags & 32) != 0;
      path->_isGroup = (flags & 128) != 0;
      size_t headerSize = 5;
      if (path->_isGroup && data.length >= 7) {
        uint16_t gidLen;
        memcpy(&gidLen, bytes + 5, 2);
        headerSize = 7;
        if (gidLen > 0 && data.length >= headerSize + gidLen) {
          path->_groupID =
              [[NSString alloc] initWithBytes:bytes + headerSize
                                       length:gidLen
                                     encoding:NSUTF8StringEncoding];
          headerSize += gidLen;
        }
      } else if (path->_isGroup && data.length >= 9) {
        // Backwards compat: old format had uint32 childCount
        headerSize = 9;
      }
      path->_count = count;
      path->_capacity = count;
      if (count > 0) {
        path->_points = malloc(count * pointSize);
        memcpy(path->_points, bytes + headerSize, count * pointSize);
      }
      // Extended: corner radii after points
      size_t extOffset = headerSize + count * pointSize;
      if ((flags & 4) && data.length >= extOffset + 4 * sizeof(float)) {
        // New: 4 per-corner radii
        float cr[4];
        memcpy(cr, bytes + extOffset, 4 * sizeof(float));
        path->_cornerRadiusTL = cr[0];
        path->_cornerRadiusTR = cr[1];
        path->_cornerRadiusBR = cr[2];
        path->_cornerRadiusBL = cr[3];
        extOffset += 4 * sizeof(float);
      } else if ((flags & 2) && data.length >= extOffset + sizeof(float)) {
        // Backwards compat: single radius applied to all corners
        float r;
        memcpy(&r, bytes + extOffset, sizeof(float));
        path->_cornerRadiusTL = r;
        path->_cornerRadiusTR = r;
        path->_cornerRadiusBR = r;
        path->_cornerRadiusBL = r;
        extOffset += sizeof(float);
      }
      if ((flags & 64) && data.length >= extOffset + 2) {
        uint16_t nameLen;
        memcpy(&nameLen, bytes + extOffset, 2);
        extOffset += 2;
        if (nameLen > 0 && data.length >= extOffset + nameLen) {
          path->_name = [[NSString alloc] initWithBytes:bytes + extOffset
                                                 length:nameLen
                                               encoding:NSUTF8StringEncoding];
          extOffset += nameLen;
        }
      }
      if (data.length >= extOffset + 2) {
        uint16_t pgidLen;
        memcpy(&pgidLen, bytes + extOffset, 2);
        extOffset += 2;
        if (pgidLen > 0 && data.length >= extOffset + pgidLen) {
          path->_parentGroupID =
              [[NSString alloc] initWithBytes:bytes + extOffset
                                       length:pgidLen
                                     encoding:NSUTF8StringEncoding];
        }
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
  if (_isRect)
    flags |= 8;
  if (_hidden)
    flags |= 16;
  if (_locked)
    flags |= 32;
  if (_isGroup)
    flags |= 128;
  BOOL hasRadius = (_cornerRadiusTL > 0 || _cornerRadiusTR > 0 ||
                    _cornerRadiusBR > 0 || _cornerRadiusBL > 0);
  if (hasRadius)
    flags |= 4;
  NSData *nameData = [_name dataUsingEncoding:NSUTF8StringEncoding];
  if (nameData.length > 0)
    flags |= 64;
  NSData *groupIDData = [_groupID dataUsingEncoding:NSUTF8StringEncoding];
  NSData *parentGroupIDData =
      [_parentGroupID dataUsingEncoding:NSUTF8StringEncoding];
  size_t pointSize = sizeof(KKBezierPoint);
  NSMutableData *data = [NSMutableData dataWithCapacity:128];
  [data appendBytes:&count length:4];
  [data appendBytes:&flags length:1];
  if (_isGroup) {
    // Write groupID length-prefixed (replaces old childCount)
    uint16_t gidLen = (uint16_t)groupIDData.length;
    [data appendBytes:&gidLen length:2];
    if (gidLen > 0)
      [data appendData:groupIDData];
  }
  if (count > 0)
    [data appendBytes:_points length:count * pointSize];
  if (hasRadius) {
    float cr[4] = {_cornerRadiusTL, _cornerRadiusTR, _cornerRadiusBR,
                   _cornerRadiusBL};
    [data appendBytes:cr length:4 * sizeof(float)];
  }
  if (nameData.length > 0) {
    uint16_t nameLen = (uint16_t)nameData.length;
    [data appendBytes:&nameLen length:2];
    [data appendData:nameData];
  }
  // Always write parentGroupID (0 length = no parent)
  uint16_t pgidLen = (uint16_t)parentGroupIDData.length;
  [data appendBytes:&pgidLen length:2];
  if (pgidLen > 0)
    [data appendData:parentGroupIDData];
  return data;
}

+ (NSMutableArray<KKBezierPath *> *)pathsFromBlob:(NSData *)blob {
  if (!blob || blob.length < 4)
    return [NSMutableArray array];

  const uint8_t *bytes = blob.bytes;
  NSUInteger offset = 0;
  uint32_t pathCount;
  memcpy(&pathCount, bytes + offset, 4);
  offset += 4;

  if (pathCount > 10000 || offset + pathCount * 4 > blob.length) {
    KKBezierPath *single = [KKBezierPath pathWithData:blob];
    if (single && single.count > 0)
      return [NSMutableArray arrayWithObject:single];
    return [NSMutableArray array];
  }

  NSMutableArray *result = [NSMutableArray arrayWithCapacity:pathCount];
  for (uint32_t i = 0; i < pathCount; i++) {
    if (offset + 4 > blob.length)
      break;
    uint32_t len;
    memcpy(&len, bytes + offset, 4);
    offset += 4;
    if (offset + len > blob.length)
      break;
    NSData *pathData = [blob subdataWithRange:NSMakeRange(offset, len)];
    KKBezierPath *path = [KKBezierPath pathWithData:pathData];
    if (path)
      [result addObject:path];
    offset += len;
  }
  return result;
}

+ (NSData *)blobFromPaths:(NSArray<KKBezierPath *> *)paths {
  NSMutableData *blob = [NSMutableData data];
  uint32_t pathCount = (uint32_t)paths.count;
  [blob appendBytes:&pathCount length:4];
  for (KKBezierPath *path in paths) {
    NSData *pathData = [path dataRepresentation];
    uint32_t len = (uint32_t)pathData.length;
    [blob appendBytes:&len length:4];
    [blob appendData:pathData];
  }
  return blob;
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

static void cornerRadii(float fraction, float maxRX, float maxRY, float objW,
                        float objH, float canvasW, float canvasH, float *outRX,
                        float *outRY) {
  float f = fmaxf(0.0f, fminf(fraction, 1.0f));
  if (f < 0.0001f) {
    *outRX = 0;
    *outRY = 0;
    return;
  }
  float maxPxX = (objW > 0.0001f) ? (maxRX / objW) * canvasW : 0;
  float maxPxY = (objH > 0.0001f) ? (maxRY / objH) * canvasH : 0;
  float maxPx = fmaxf(maxPxX, maxPxY);
  float pixelR = f * maxPx;
  *outRX = (canvasW > 0.0001f)
               ? fminf((fminf(pixelR, maxPxX) / canvasW) * objW, maxRX)
               : 0;
  *outRY = (canvasH > 0.0001f)
               ? fminf((fminf(pixelR, maxPxY) / canvasH) * objH, maxRY)
               : 0;
}

- (void)setRoundedRectWithMin:(simd_float2)min
                          max:(simd_float2)max
                   fractionTL:(float)ftl
                   fractionTR:(float)ftr
                   fractionBR:(float)fbr
                   fractionBL:(float)fbl
                  canvasWidth:(float)canvasW
                 canvasHeight:(float)canvasH {
  _cornerRadiusTL = fmaxf(0.0f, fminf(ftl, 1.0f));
  _cornerRadiusTR = fmaxf(0.0f, fminf(ftr, 1.0f));
  _cornerRadiusBR = fmaxf(0.0f, fminf(fbr, 1.0f));
  _cornerRadiusBL = fmaxf(0.0f, fminf(fbl, 1.0f));

  float maxRX = (max.x - min.x) * 0.5f;
  float maxRY = (max.y - min.y) * 0.5f;
  float objW = max.x - min.x;
  float objH = max.y - min.y;

  BOOL allZero = (_cornerRadiusTL < 0.0001f && _cornerRadiusTR < 0.0001f &&
                  _cornerRadiusBR < 0.0001f && _cornerRadiusBL < 0.0001f);
  if (allZero) {
    [self ensureCapacity:4];
    _count = 4;
    _closed = YES;
    _points[0] = (KKBezierPoint){min.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[1] = (KKBezierPoint){max.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[2] = (KKBezierPoint){max.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
    _points[3] = (KKBezierPoint){min.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
    return;
  }

  // Compute per-corner rx/ry
  float rx[4], ry[4];
  float fracs[4] = {_cornerRadiusTL, _cornerRadiusTR, _cornerRadiusBR,
                    _cornerRadiusBL};
  for (int i = 0; i < 4; i++)
    cornerRadii(fracs[i], maxRX, maxRY, objW, objH, canvasW, canvasH, &rx[i],
                &ry[i]);

  // Build points: 2 per rounded corner, 1 per sharp corner
  KKBezierPoint tmp[12]; // max 8 rounded + potential
  NSUInteger n = 0;

  // TL corner (left side, then top side)
  if (rx[0] > 0.0001f && ry[0] > 0.0001f) {
    float kx = rx[0] * 0.5522847498f, ky = ry[0] * 0.5522847498f;
    tmp[n++] = (KKBezierPoint){min.x, max.y - ry[0],      0, -ky, 0,
                               ky,    KKBezierPointBezier};
    tmp[n++] = (KKBezierPoint){min.x + rx[0],      max.y, -kx, 0, kx, 0,
                               KKBezierPointBezier};
  } else {
    tmp[n++] = (KKBezierPoint){min.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
  }

  // TR corner (top side, then right side)
  if (rx[1] > 0.0001f && ry[1] > 0.0001f) {
    float kx = rx[1] * 0.5522847498f, ky = ry[1] * 0.5522847498f;
    tmp[n++] = (KKBezierPoint){max.x - rx[1],      max.y, -kx, 0, kx, 0,
                               KKBezierPointBezier};
    tmp[n++] = (KKBezierPoint){max.x, max.y - ry[1],      0, ky, 0,
                               -ky,   KKBezierPointBezier};
  } else {
    tmp[n++] = (KKBezierPoint){max.x, max.y, 0, 0, 0, 0, KKBezierPointLinear};
  }

  // BR corner (right side, then bottom side)
  if (rx[2] > 0.0001f && ry[2] > 0.0001f) {
    float kx = rx[2] * 0.5522847498f, ky = ry[2] * 0.5522847498f;
    tmp[n++] = (KKBezierPoint){max.x, min.y + ry[2],      0, ky, 0,
                               -ky,   KKBezierPointBezier};
    tmp[n++] = (KKBezierPoint){max.x - rx[2],      min.y, kx, 0, -kx, 0,
                               KKBezierPointBezier};
  } else {
    tmp[n++] = (KKBezierPoint){max.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
  }

  // BL corner (bottom side, then left side)
  if (rx[3] > 0.0001f && ry[3] > 0.0001f) {
    float kx = rx[3] * 0.5522847498f, ky = ry[3] * 0.5522847498f;
    tmp[n++] = (KKBezierPoint){min.x + rx[3],      min.y, kx, 0, -kx, 0,
                               KKBezierPointBezier};
    tmp[n++] = (KKBezierPoint){min.x, min.y + ry[3],      0, -ky, 0,
                               ky,    KKBezierPointBezier};
  } else {
    tmp[n++] = (KKBezierPoint){min.x, min.y, 0, 0, 0, 0, KKBezierPointLinear};
  }

  // Merge adjacent points that overlap (when a side fully collapses)
  KKBezierPoint merged[12];
  NSUInteger m = 0;
  for (NSUInteger i = 0; i < n; i++) {
    NSUInteger next = (i + 1) % n;
    float dx = tmp[next].x - tmp[i].x;
    float dy = tmp[next].y - tmp[i].y;
    if (dx * dx + dy * dy < 0.0001f && i < n - 1) {
      // Merge: take in-handle from first, out-handle from second
      merged[m] = tmp[i];
      merged[m].outX = tmp[next].outX;
      merged[m].outY = tmp[next].outY;
      merged[m].type = KKBezierPointBezier;
      m++;
      i++; // skip next
    } else {
      merged[m++] = tmp[i];
    }
  }
  // Also check wrap-around: last point and first point
  if (m >= 2) {
    float dx = merged[0].x - merged[m - 1].x;
    float dy = merged[0].y - merged[m - 1].y;
    if (dx * dx + dy * dy < 0.0001f) {
      merged[0].inX = merged[m - 1].inX;
      merged[0].inY = merged[m - 1].inY;
      merged[0].type = KKBezierPointBezier;
      m--;
    }
  }

  [self ensureCapacity:m];
  _count = m;
  memcpy(_points, merged, m * sizeof(KKBezierPoint));
  _closed = YES;
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
