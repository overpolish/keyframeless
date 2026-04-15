/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Tessellation.h"

NSUInteger KKTessellateDashedPath(KKBezierPath *path, float strokeWidth,
                                  float outputWidth, float outputHeight,
                                  float dashLength, float dashGap,
                                  uint8_t lineJoin, CanvasVertex *vertices) {
  float aaPadding = 1.0f;
  float halfWidth = (strokeWidth / 2.0f) + aaPadding;
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;

  float cycle = dashLength + dashGap;
  if (cycle < 1.0f)
    cycle = 1.0f;

  NSUInteger totalSamples = curveCount * (segsPerCurve + 1);
  float *arcLengths = calloc(totalSamples + 1, sizeof(float));
  simd_float2 *positions = malloc((totalSamples + 1) * sizeof(simd_float2));
  {
    NSUInteger idx = 0;
    for (NSUInteger c = 0; c < curveCount; c++) {
      for (NSUInteger i = 0; i <= segsPerCurve; i++) {
        float t = (float)i / (float)segsPerCurve;
        NSUInteger nextIdx = (c + 1) % path.count;
        simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
        simd_float2 px = {pos.x * outputWidth - outputWidth / 2.0f,
                          (1.0f - pos.y) * outputHeight - outputHeight / 2.0f};
        positions[idx] = px;
        if (idx > 0)
          arcLengths[idx] =
              arcLengths[idx - 1] + simd_length(px - positions[idx - 1]);
        idx++;
      }
    }
  }

  NSUInteger vc = 0;
  NSUInteger sampleIdx = 0;
  BOOL wasInDash = NO;
  simd_float2 lastEmittedCenter = {0, 0};
  simd_float2 lastEmittedNormal = {0, 0};

  for (NSUInteger c = 0; c < curveCount; c++) {
    simd_float2 segEndCenter = {0, 0}, segEndNormal = {0, 0};

    for (NSUInteger i = 0; i <= segsPerCurve; i++) {
      float t = (float)i / (float)segsPerCurve;
      NSUInteger nextIdx = (c + 1) % path.count;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      simd_float2 normal =
          KKNormalAtPoint(path, c, segsPerCurve, i, outputWidth, outputHeight);

      simd_float2 centered = {pos.x * outputWidth - outputWidth / 2.0f,
                              (1.0f - pos.y) * outputHeight -
                                  outputHeight / 2.0f};

      if (i == segsPerCurve) {
        segEndCenter = centered;
        segEndNormal = normal;
      }

      float arc = arcLengths[sampleIdx];
      float phase = fmodf(arc, cycle);
      BOOL inDash = (phase < dashLength);

      BOOL atDashBoundary = (inDash != wasInDash);
      if (lineJoin == 0 && !atDashBoundary) {
        if (i == segsPerCurve &&
            (c < curveCount - 1 || (path.closed && c == curveCount - 1))) {
          float nextArc = (sampleIdx + 1 < totalSamples)
                              ? arcLengths[sampleIdx + 1]
                              : arcLengths[sampleIdx];
          BOOL nextInDash = (fmodf(nextArc, cycle) < dashLength);
          if (nextInDash) {
            NSUInteger nextC = (c < curveCount - 1) ? (c + 1) % path.count : 0;
            simd_float2 nextN =
                KKRawNormalAtSegStart(path, nextC, outputWidth, outputHeight);
            simd_float2 avg = normal + nextN;
            float avgLen = simd_length(avg);
            if (avgLen > 1e-6f) {
              avg /= avgLen;
              float d = simd_dot(avg, normal);
              if (d > 1e-6f) {
                float ext = fminf(1.0f / d, 1.0f);
                normal = avg * ext;
              }
            }
          }
        } else if (i == 0 && (c > 0 || (path.closed && c == 0))) {
          float prevArc =
              (sampleIdx > 0) ? arcLengths[sampleIdx - 1] : arcLengths[0];
          BOOL prevInDash = (fmodf(prevArc, cycle) < dashLength);
          if (prevInDash) {
            NSUInteger prevC = (c > 0) ? c - 1 : curveCount - 1;
            simd_float2 prevN =
                KKNormalAtPoint(path, prevC, segsPerCurve, segsPerCurve,
                                outputWidth, outputHeight);
            simd_float2 avg = prevN + normal;
            float avgLen = simd_length(avg);
            if (avgLen > 1e-6f) {
              avg /= avgLen;
              float d = simd_dot(avg, prevN);
              if (d > 1e-6f) {
                float ext = fminf(1.0f / d, 1.0f);
                normal = avg * ext;
              }
            }
          }
        }
      }

      if (inDash && !wasInDash) {
        simd_float2 tangent = {normal.y, -normal.x};
        if (vc > 0) {
          simd_float2 prevLast = vertices[vc - 1].position;
          simd_float2 nextFirst = centered + normal * halfWidth;
          vc = KKEmitBridge(vertices, vc, prevLast, nextFirst);
        }
        vc = KKEmitRoundCapStandalone(vertices, vc, centered, tangent, normal,
                                      halfWidth, YES);
        simd_float2 prevLast = vertices[vc - 1].position;
        simd_float2 nextFirst = centered + normal * halfWidth;
        vc = KKEmitBridge(vertices, vc, prevLast, nextFirst);
      }

      if (!inDash && wasInDash) {
        simd_float2 capTan = {lastEmittedNormal.y, -lastEmittedNormal.x};
        simd_float2 prevLast = vertices[vc - 1].position;
        simd_float2 capFirst =
            lastEmittedCenter + lastEmittedNormal * halfWidth;
        vc = KKEmitBridge(vertices, vc, prevLast, capFirst);
        vc = KKEmitRoundCapStandalone(vertices, vc, lastEmittedCenter, capTan,
                                      lastEmittedNormal, halfWidth, NO);
      }

      if (inDash) {
        BOOL skipForJoin = (i == 0 && c > 0 && lineJoin != 0);
        if (!skipForJoin) {
          if (i == 0 && c > 0 && lineJoin == 0 && vc > 0) {
            vertices[vc] = vertices[vc - 1];
            vc++;
          }

          vertices[vc].position = centered + normal * halfWidth;
          vertices[vc].edgeDistance = 1.0f;
          vertices[vc].capDistance = 0.0f;
          vc++;
          vertices[vc].position = centered - normal * halfWidth;
          vertices[vc].edgeDistance = -1.0f;
          vertices[vc].capDistance = 0.0f;
          vc++;
        }
        lastEmittedCenter = centered;
        lastEmittedNormal = normal;
      }

      wasInDash = inDash;
      sampleIdx++;
    }

    BOOL atJoin = (c < curveCount - 1) || (path.closed && c == curveCount - 1);
    float joinArc = arcLengths[sampleIdx - 1];
    BOOL joinInDash = (fmodf(joinArc, cycle) < dashLength);

    if (atJoin && lineJoin != 0 && joinInDash) {
      NSUInteger nextC = (c + 1) % curveCount;
      if (path.closed && c == curveCount - 1)
        nextC = 0;
      simd_float2 n2 =
          KKRawNormalAtSegStart(path, nextC, outputWidth, outputHeight);

      vc = KKEmitJoinGeometry(vertices, vc, segEndCenter, segEndNormal, n2,
                              halfWidth, lineJoin);

      if (c < curveCount - 1) {
        vertices[vc] = vertices[vc - 1];
        vc++;
        vertices[vc].position = segEndCenter + n2 * halfWidth;
        vertices[vc].edgeDistance = 1.0f;
        vertices[vc].capDistance = 0.0f;
        vc++;
        vertices[vc].position = segEndCenter - n2 * halfWidth;
        vertices[vc].edgeDistance = -1.0f;
        vertices[vc].capDistance = 0.0f;
        vc++;
      }
    } else if (c < curveCount - 1 && lineJoin == 0 && joinInDash) {
      vertices[vc] = vertices[vc - 1];
      vc++;
    }
  }

  if (wasInDash && vc > 0) {
    simd_float2 capTan = {lastEmittedNormal.y, -lastEmittedNormal.x};
    simd_float2 prevLast = vertices[vc - 1].position;
    simd_float2 capFirst = lastEmittedCenter + lastEmittedNormal * halfWidth;
    vc = KKEmitBridge(vertices, vc, prevLast, capFirst);
    vc = KKEmitRoundCapStandalone(vertices, vc, lastEmittedCenter, capTan,
                                  lastEmittedNormal, halfWidth, NO);
  }

  free(arcLengths);
  free(positions);
  return vc;
}

NSUInteger KKTessellateDottedPath(KKBezierPath *path, float strokeWidth,
                                  float outputWidth, float outputHeight,
                                  float dotGap, CanvasVertex *vertices) {
  PathSample *samples = NULL;
  NSUInteger sampleCount =
      KKSamplePathPolyline(path, outputWidth, outputHeight, &samples);
  if (sampleCount < 2) {
    free(samples);
    return 0;
  }

  float totalLength = samples[sampleCount - 1].arcLength;
  float aaPadding = 1.0f;
  float halfWidth = (strokeWidth / 2.0f) + aaPadding;
  float spacing = strokeWidth + dotGap;
  if (spacing < 1.0f)
    spacing = 1.0f;

  NSUInteger vc = 0;
  NSUInteger hint = 0;
  float pos = 0.0f;

  while (pos <= totalLength) {
    PathSample s = KKSampleAtArc(samples, sampleCount, pos, &hint);
    simd_float2 tangent = {s.normal.y, -s.normal.x};

    if (vc > 0) {
      simd_float2 prevLast = vertices[vc - 1].position;
      simd_float2 nextFirst = s.position + s.normal * halfWidth;
      vc = KKEmitBridge(vertices, vc, prevLast, nextFirst);
    }

    vc = KKEmitRoundCapStandalone(vertices, vc, s.position, tangent, s.normal,
                                  halfWidth, NO);
    {
      simd_float2 prevLast = vertices[vc - 1].position;
      simd_float2 nextFirst = s.position + s.normal * halfWidth;
      vc = KKEmitBridge(vertices, vc, prevLast, nextFirst);
    }
    vc = KKEmitRoundCapStandalone(vertices, vc, s.position, tangent, s.normal,
                                  halfWidth, YES);

    pos += spacing;
  }

  free(samples);
  return vc;
}
