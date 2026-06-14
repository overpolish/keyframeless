/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Tessellation.h"

simd_float2 KKMiterNormal(simd_float2 n1, simd_float2 n2) {
  simd_float2 avg = n1 + n2;
  float avgLen = simd_length(avg);
  if (avgLen < 1e-6f)
    return n1;
  avg /= avgLen;
  float d = simd_dot(avg, n1);
  if (d < 1e-6f)
    return n1;
  float extension = 1.0f / d;
  if (extension > kMiterLimit)
    extension = kMiterLimit;
  return avg * extension;
}

simd_float2 KKNormalAtPoint(KKBezierPath *path, NSUInteger c,
                            NSUInteger segsPerCurve, NSUInteger i,
                            float outputWidth, float outputHeight) {
  NSUInteger nextIdx = (c + 1) % path.count;
  float t = (float)i / (float)segsPerCurve;
  simd_float2 tangent = [path evaluateTangentAtIndex:c nextIndex:nextIdx atT:t];
  tangent.x *= outputWidth;
  tangent.y *= -outputHeight;
  float len = simd_length(tangent);
  if (len < 1e-2f) {
    float step = 1.0f / (float)segsPerCurve;
    float probeT = (t < 0.5f) ? t + step : t - step;
    probeT = fmaxf(0.0f, fminf(1.0f, probeT));
    simd_float2 probe = [path evaluateTangentAtIndex:c
                                           nextIndex:nextIdx
                                                 atT:probeT];
    probe.x *= outputWidth;
    probe.y *= -outputHeight;
    float probeLen = simd_length(probe);
    if (probeLen > len) {
      tangent = probe;
      len = probeLen;
    }
    if (len < 1e-6f) {
      simd_float2 p0 = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:0.0f];
      simd_float2 p1 = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:1.0f];
      tangent = (simd_float2){(p1.x - p0.x) * outputWidth,
                              (p0.y - p1.y) * outputHeight};
      len = simd_length(tangent);
    }
  }
  if (len < 1e-6f)
    tangent = (simd_float2){1.0f, 0.0f};
  else
    tangent /= len;
  return (simd_float2){-tangent.y, tangent.x};
}

simd_float2 KKRawNormalAtSegStart(KKBezierPath *path, NSUInteger c,
                                  float outputWidth, float outputHeight) {
  NSUInteger nextIdx = (c + 1) % path.count;
  simd_float2 tangent = [path evaluateTangentAtIndex:c
                                           nextIndex:nextIdx
                                                 atT:0.0f];
  tangent.x *= outputWidth;
  tangent.y *= -outputHeight;
  float len = simd_length(tangent);
  if (len < 1e-6f) {
    simd_float2 a = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:0.0f];
    simd_float2 b = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:1.0f];
    tangent =
        (simd_float2){(b.x - a.x) * outputWidth, (a.y - b.y) * outputHeight};
    len = simd_length(tangent);
  }
  if (len < 1e-6f)
    return (simd_float2){-1.0f, 0.0f};
  tangent /= len;
  return (simd_float2){-tangent.y, tangent.x};
}

NSUInteger KKAddRoundCap(CanvasVertex *vertices, NSUInteger vertexCount,
                         simd_float2 center, simd_float2 tangent,
                         simd_float2 normal, float halfWidth, BOOL isStart) {
  NSUInteger capSegs = 16;
  simd_float2 capDir = isStart ? -tangent : tangent;

  if (vertexCount > 0) {
    vertices[vertexCount] = vertices[vertexCount - 1];
    vertexCount++;
  }

  for (NSUInteger i = 0; i <= capSegs; i++) {
    float angle = (float)i / (float)capSegs * M_PI;
    float cosA = cosf(angle);
    float sinA = sinf(angle);
    simd_float2 dir = normal * cosA + capDir * sinA;

    simd_float2 outer = center + dir * halfWidth;
    vertices[vertexCount].position = outer;
    vertices[vertexCount].edgeDistance = 0.0f;
    vertices[vertexCount].capDistance = 1.0f;
    vertexCount++;

    vertices[vertexCount].position = center;
    vertices[vertexCount].edgeDistance = 0.0f;
    vertices[vertexCount].capDistance = 0.0f;
    vertexCount++;

    if (i == 0 && vertexCount >= 4) {
      vertices[vertexCount] = vertices[vertexCount - 2];
      vertexCount++;
      vertices[vertexCount] = vertices[vertexCount - 2];
      vertexCount++;
    }
  }
  return vertexCount;
}

NSUInteger KKEmitRoundCapStandalone(CanvasVertex *vertices,
                                    NSUInteger vertexCount, simd_float2 center,
                                    simd_float2 tangent, simd_float2 normal,
                                    float halfWidth, BOOL isStart) {
  NSUInteger capSegs = 16;
  simd_float2 capDir = isStart ? -tangent : tangent;

  for (NSUInteger i = 0; i <= capSegs; i++) {
    float angle = (float)i / (float)capSegs * M_PI;
    float cosA = cosf(angle);
    float sinA = sinf(angle);
    simd_float2 dir = normal * cosA + capDir * sinA;
    simd_float2 outer = center + dir * halfWidth;

    vertices[vertexCount].position = outer;
    vertices[vertexCount].edgeDistance = 0.0f;
    vertices[vertexCount].capDistance = 1.0f;
    vertexCount++;

    vertices[vertexCount].position = center;
    vertices[vertexCount].edgeDistance = 0.0f;
    vertices[vertexCount].capDistance = 0.0f;
    vertexCount++;
  }
  return vertexCount;
}

NSUInteger KKEmitBridge(CanvasVertex *vertices, NSUInteger vertexCount,
                        simd_float2 prevLast, simd_float2 nextFirst) {
  vertices[vertexCount].position = prevLast;
  vertices[vertexCount].edgeDistance = 0.0f;
  vertices[vertexCount].capDistance = 0.0f;
  vertexCount++;
  vertices[vertexCount].position = nextFirst;
  vertices[vertexCount].edgeDistance = 0.0f;
  vertices[vertexCount].capDistance = 0.0f;
  vertexCount++;
  vertices[vertexCount].position = nextFirst;
  vertices[vertexCount].edgeDistance = 0.0f;
  vertices[vertexCount].capDistance = 0.0f;
  vertexCount++;
  return vertexCount;
}

NSUInteger KKEmitJoinGeometry(CanvasVertex *vertices, NSUInteger vc,
                              simd_float2 jCenter, simd_float2 n1,
                              simd_float2 n2, float halfWidth,
                              uint8_t lineJoin) {
  float cross = n1.x * n2.y - n1.y * n2.x;
  float side = (cross >= 0.0f) ? -1.0f : 1.0f;

  simd_float2 outerEnd = jCenter + n1 * halfWidth * side;
  simd_float2 outerStart = jCenter + n2 * halfWidth * side;

  if (vc > 0) {
    vertices[vc] = vertices[vc - 1];
    vc++;
  }

  if (lineJoin == 1) {
    float dot = simd_dot(n1 * side, n2 * side);
    dot = fmaxf(-1.0f, fminf(1.0f, dot));
    float angle = acosf(dot);

    if (angle > 1e-4f) {
      simd_float2 on1 = n1 * side;
      simd_float2 on2 = n2 * side;
      float sweepCross = on1.x * on2.y - on1.y * on2.x;
      float dir = (sweepCross >= 0.0f) ? 1.0f : -1.0f;
      NSUInteger segs = (NSUInteger)fmaxf(4.0f, angle / (M_PI / 16.0f));

      CanvasVertex first;
      first.position = jCenter + on1 * halfWidth;
      first.edgeDistance = 0.0f;
      first.capDistance = 0.0f;
      vertices[vc] = first;
      vc++;
      vertices[vc] = first;
      vc++;

      for (NSUInteger s = 0; s <= segs; s++) {
        float st = (float)s / (float)segs;
        float a = st * angle * dir;
        float cosA = cosf(a);
        float sinA = sinf(a);
        simd_float2 rotated = {on1.x * cosA - on1.y * sinA,
                               on1.x * sinA + on1.y * cosA};
        vertices[vc].position = jCenter + rotated * halfWidth;
        vertices[vc].edgeDistance = 0.0f;
        vertices[vc].capDistance = 1.0f;
        vc++;
        vertices[vc].position = jCenter;
        vertices[vc].edgeDistance = 0.0f;
        vertices[vc].capDistance = 0.0f;
        vc++;
      }
    }
  } else {
    CanvasVertex first;
    first.position = outerEnd;
    first.edgeDistance = 0.0f;
    first.capDistance = 0.0f;
    vertices[vc] = first;
    vc++;
    vertices[vc] = first;
    vc++;

    vertices[vc].position = outerEnd;
    vertices[vc].edgeDistance = 0.0f;
    vertices[vc].capDistance = 1.0f;
    vc++;
    vertices[vc].position = jCenter;
    vertices[vc].edgeDistance = 0.0f;
    vertices[vc].capDistance = 0.0f;
    vc++;
    vertices[vc].position = outerStart;
    vertices[vc].edgeDistance = 0.0f;
    vertices[vc].capDistance = 1.0f;
    vc++;
  }

  return vc;
}

NSUInteger KKSamplePathPolyline(KKBezierPath *path, float outputWidth,
                                float outputHeight, PathSample **outSamples) {
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;
  NSUInteger maxSamples = curveCount * (segsPerCurve + 1) + 1;
  PathSample *samples = malloc(maxSamples * sizeof(PathSample));
  NSUInteger count = 0;
  float cumLen = 0.0f;

  for (NSUInteger c = 0; c < curveCount; c++) {
    NSUInteger startI = (c == 0) ? 0 : 1;
    NSUInteger nextIdx = (c + 1) % path.count;
    for (NSUInteger i = startI; i <= segsPerCurve; i++) {
      float t = (float)i / (float)segsPerCurve;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      simd_float2 normal =
          KKNormalAtPoint(path, c, segsPerCurve, i, outputWidth, outputHeight);
      simd_float2 px = {pos.x * outputWidth - outputWidth / 2.0f,
                        (1.0f - pos.y) * outputHeight - outputHeight / 2.0f};
      if (count > 0)
        cumLen += simd_length(px - samples[count - 1].position);
      samples[count].position = px;
      samples[count].normal = normal;
      samples[count].nextCurveStartNormal = (simd_float2){0, 0};
      samples[count].prevCurveEndNormal = (simd_float2){0, 0};
      samples[count].arcLength = cumLen;
      samples[count].atJoin = false;
      samples[count].atWrapStart = false;
      // Mark the last sample of this curve as a join when there's a
      // following curve (open paths: c+1 < curveCount; closed paths: also
      // after the final curve so the wrap-around joint emits geometry).
      if (i == segsPerCurve) {
        BOOL hasNext = (c + 1 < curveCount) || path.closed;
        if (hasNext) {
          NSUInteger nextC = (c + 1) % path.count;
          if (path.closed && c == curveCount - 1)
            nextC = 0;
          samples[count].atJoin = true;
          samples[count].nextCurveStartNormal = KKNormalAtPoint(
              path, nextC, segsPerCurve, 0, outputWidth, outputHeight);
        }
      }
      count++;
    }
  }
  // For closed paths, the very first sample is also the wrap-join partner of
  // the last sample. Stash the previous-curve end normal here so trimmed
  // tessellation can miter-extend strip 2's start at the wrap.
  if (path.closed && count > 1) {
    samples[0].atWrapStart = true;
    samples[0].prevCurveEndNormal = samples[count - 1].normal;
  }
  *outSamples = samples;
  return count;
}

PathSample KKLerpSample(const PathSample *a, const PathSample *b,
                        float targetArc) {
  float range = b->arcLength - a->arcLength;
  float t = (range > 1e-6f) ? (targetArc - a->arcLength) / range : 0.0f;
  t = fmaxf(0.0f, fminf(1.0f, t));
  PathSample s;
  s.position = a->position + (b->position - a->position) * t;
  simd_float2 n = a->normal + (b->normal - a->normal) * t;
  float nlen = simd_length(n);
  s.normal = (nlen > 1e-6f) ? n / nlen : a->normal;
  s.arcLength = targetArc;
  return s;
}

static NSUInteger findSampleAtArc(const PathSample *samples, NSUInteger count,
                                  float arc, NSUInteger hint) {
  NSUInteger i = hint;
  while (i + 1 < count && samples[i + 1].arcLength <= arc)
    i++;
  return i;
}

PathSample KKSampleAtArc(const PathSample *samples, NSUInteger count, float arc,
                         NSUInteger *hint) {
  NSUInteger si = findSampleAtArc(samples, count, arc, *hint);
  *hint = si;
  return KKLerpSample(&samples[si],
                      (si + 1 < count) ? &samples[si + 1] : &samples[si], arc);
}
