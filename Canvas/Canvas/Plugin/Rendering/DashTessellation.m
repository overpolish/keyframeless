/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Tessellation.h"

NSUInteger KKTessellateDashedPath(KKBezierPath *path, float startWidth,
                                  float endWidth, float outputWidth,
                                  float outputHeight, float dashLength,
                                  float dashGap, uint8_t lineJoin,
                                  float startTrim, float endTrim,
                                  float phaseOffset, CanvasVertex *vertices) {
  float aaPadding = 1.0f;
  NSUInteger segsPerCurve = 512;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;

  BOOL isOpen = !path.closed;
  BOOL tapers = isOpen && fabsf(startWidth - endWidth) > 0.001f;

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

  float totalArc = (totalSamples > 0) ? arcLengths[totalSamples - 1] : 0.0f;
  float arcStart = fmaxf(0.0f, startTrim);
  float arcEnd = totalArc - fmaxf(0.0f, endTrim);
  if (arcStart >= arcEnd) {
    free(arcLengths);
    free(positions);
    return 0;
  }

  NSUInteger vc = 0;
  NSUInteger sampleIdx = 0;
  BOOL wasInDash = NO;
  simd_float2 lastEmittedCenter = {0, 0};
  simd_float2 lastEmittedNormal = {0, 0};
  float lastEmittedHW = startWidth / 2.0f + aaPadding;

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
      float phase = fmodf(arc - phaseOffset, cycle);
      if (phase < 0.0f)
        phase += cycle;
      BOOL inDash =
          (phase < dashLength) && (arc >= arcStart) && (arc <= arcEnd);

      float arcT = (totalArc > 0) ? arc / totalArc : 0.0f;
      float hw = tapers
                     ? ((startWidth + (endWidth - startWidth) * arcT) / 2.0f +
                        aaPadding)
                     : (startWidth / 2.0f + aaPadding);

      BOOL atDashBoundary = (inDash != wasInDash);
      if (lineJoin == 0 && !atDashBoundary) {
        if (i == segsPerCurve &&
            (c < curveCount - 1 || (path.closed && c == curveCount - 1))) {
          float nextArc = (sampleIdx + 1 < totalSamples)
                              ? arcLengths[sampleIdx + 1]
                              : arcLengths[sampleIdx];
          float nextPhase = fmodf(nextArc - phaseOffset, cycle);
          if (nextPhase < 0.0f)
            nextPhase += cycle;
          BOOL nextInDash = (nextPhase < dashLength) && (nextArc >= arcStart) &&
                            (nextArc <= arcEnd);
          if (nextInDash) {
            NSUInteger nextC = (c < curveCount - 1) ? (c + 1) % path.count : 0;
            simd_float2 nextN = KKNormalAtPoint(path, nextC, segsPerCurve, 0,
                                                outputWidth, outputHeight);
            normal = KKMiterNormal(normal, nextN);
          }
        } else if (i == 0 && (c > 0 || (path.closed && c == 0))) {
          float prevArc =
              (sampleIdx > 0) ? arcLengths[sampleIdx - 1] : arcLengths[0];
          float prevPhase = fmodf(prevArc - phaseOffset, cycle);
          if (prevPhase < 0.0f)
            prevPhase += cycle;
          BOOL prevInDash = (prevPhase < dashLength) && (prevArc >= arcStart) &&
                            (prevArc <= arcEnd);
          if (prevInDash) {
            NSUInteger prevC = (c > 0) ? c - 1 : curveCount - 1;
            simd_float2 prevN =
                KKNormalAtPoint(path, prevC, segsPerCurve, segsPerCurve,
                                outputWidth, outputHeight);
            normal = KKMiterNormal(prevN, normal);
          }
        }
      }

      if (inDash && !wasInDash) {
        simd_float2 tangent = {normal.y, -normal.x};
        if (vc > 0) {
          simd_float2 prevLast = vertices[vc - 1].position;
          simd_float2 nextFirst = centered + normal * hw;
          vc = KKEmitBridge(vertices, vc, prevLast, nextFirst);
        }
        vc = KKEmitRoundCapStandalone(vertices, vc, centered, tangent, normal,
                                      hw, YES);
        simd_float2 prevLast = vertices[vc - 1].position;
        simd_float2 nextFirst = centered + normal * hw;
        vc = KKEmitBridge(vertices, vc, prevLast, nextFirst);
      }

      if (!inDash && wasInDash) {
        simd_float2 capTan = {lastEmittedNormal.y, -lastEmittedNormal.x};
        simd_float2 prevLast = vertices[vc - 1].position;
        simd_float2 capFirst =
            lastEmittedCenter + lastEmittedNormal * lastEmittedHW;
        vc = KKEmitBridge(vertices, vc, prevLast, capFirst);
        vc = KKEmitRoundCapStandalone(vertices, vc, lastEmittedCenter, capTan,
                                      lastEmittedNormal, lastEmittedHW, NO);
      }

      if (inDash) {
        BOOL skipForJoin = (i == 0 && c > 0 && lineJoin != 0);
        if (!skipForJoin) {
          if (i == 0 && c > 0 && lineJoin == 0 && vc > 0) {
            vertices[vc] = vertices[vc - 1];
            vc++;
          }

          vertices[vc].position = centered + normal * hw;
          vertices[vc].edgeDistance = 1.0f;
          vertices[vc].capDistance = 0.0f;
          vc++;
          vertices[vc].position = centered - normal * hw;
          vertices[vc].edgeDistance = -1.0f;
          vertices[vc].capDistance = 0.0f;
          vc++;
        }
        lastEmittedCenter = centered;
        lastEmittedNormal = normal;
        lastEmittedHW = hw;
      }

      wasInDash = inDash;
      sampleIdx++;
    }

    BOOL atJoin = (c < curveCount - 1) || (path.closed && c == curveCount - 1);
    float joinArc = arcLengths[sampleIdx - 1];
    float joinPhase = fmodf(joinArc - phaseOffset, cycle);
    if (joinPhase < 0.0f)
      joinPhase += cycle;
    BOOL joinInDash = (joinPhase < dashLength) && (joinArc >= arcStart) &&
                      (joinArc <= arcEnd);
    float joinT = (totalArc > 0) ? joinArc / totalArc : 0.0f;
    float joinHW =
        tapers ? ((startWidth + (endWidth - startWidth) * joinT) / 2.0f +
                  aaPadding)
               : (startWidth / 2.0f + aaPadding);

    if (atJoin && lineJoin != 0 && joinInDash) {
      NSUInteger nextC = (c + 1) % curveCount;
      if (path.closed && c == curveCount - 1)
        nextC = 0;
      simd_float2 n2 = KKNormalAtPoint(path, nextC, segsPerCurve, 0,
                                       outputWidth, outputHeight);

      vc = KKEmitJoinGeometry(vertices, vc, segEndCenter, segEndNormal, n2,
                              joinHW, lineJoin);

      if (c < curveCount - 1) {
        vertices[vc] = vertices[vc - 1];
        vc++;
        vertices[vc].position = segEndCenter + n2 * joinHW;
        vertices[vc].edgeDistance = 1.0f;
        vertices[vc].capDistance = 0.0f;
        vc++;
        vertices[vc].position = segEndCenter - n2 * joinHW;
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
    simd_float2 capFirst =
        lastEmittedCenter + lastEmittedNormal * lastEmittedHW;
    vc = KKEmitBridge(vertices, vc, prevLast, capFirst);
    vc = KKEmitRoundCapStandalone(vertices, vc, lastEmittedCenter, capTan,
                                  lastEmittedNormal, lastEmittedHW, NO);
  }

  free(arcLengths);
  free(positions);
  return vc;
}

NSUInteger KKTessellateDottedPath(KKBezierPath *path, float startWidth,
                                  float endWidth, float outputWidth,
                                  float outputHeight, float dotGap,
                                  float startTrim, float endTrim,
                                  float phaseOffset, CanvasVertex *vertices) {
  PathSample *samples = NULL;
  NSUInteger sampleCount =
      KKSamplePathPolyline(path, outputWidth, outputHeight, &samples);
  if (sampleCount < 2) {
    free(samples);
    return 0;
  }

  float totalLength = samples[sampleCount - 1].arcLength;
  float arcStart = fmaxf(0.0f, startTrim);
  float arcEnd = totalLength - fmaxf(0.0f, endTrim);
  if (arcStart >= arcEnd) {
    free(samples);
    return 0;
  }
  float aaPadding = 1.0f;
  BOOL isOpen = !path.closed;
  BOOL tapers = isOpen && fabsf(startWidth - endWidth) > 0.001f;
  float spacing = startWidth + dotGap;
  if (spacing < 1.0f)
    spacing = 1.0f;

  NSUInteger vc = 0;
  NSUInteger hint = 0;
  // Wrap phase into [0, spacing) so dots shift forward by `phaseOffset` along
  // arc length; start one cycle earlier than arcStart so a dot that lands near
  // the start boundary still emits.
  float phaseShift = fmodf(phaseOffset, spacing);
  if (phaseShift < 0.0f)
    phaseShift += spacing;
  float pos = arcStart + phaseShift - spacing;

  while (pos <= arcEnd) {
    if (pos < arcStart) {
      pos += spacing;
      continue;
    }
    PathSample s = KKSampleAtArc(samples, sampleCount, pos, &hint);
    simd_float2 tangent = {s.normal.y, -s.normal.x};

    float arcT = (totalLength > 0) ? pos / totalLength : 0.0f;
    float localW =
        tapers ? (startWidth + (endWidth - startWidth) * arcT) : startWidth;
    float hw = localW / 2.0f + aaPadding;

    if (vc > 0) {
      simd_float2 prevLast = vertices[vc - 1].position;
      simd_float2 nextFirst = s.position + s.normal * hw;
      vc = KKEmitBridge(vertices, vc, prevLast, nextFirst);
    }

    vc = KKEmitRoundCapStandalone(vertices, vc, s.position, tangent, s.normal,
                                  hw, NO);
    {
      simd_float2 prevLast = vertices[vc - 1].position;
      simd_float2 nextFirst = s.position + s.normal * hw;
      vc = KKEmitBridge(vertices, vc, prevLast, nextFirst);
    }
    vc = KKEmitRoundCapStandalone(vertices, vc, s.position, tangent, s.normal,
                                  hw, YES);

    pos += spacing;
  }

  free(samples);
  return vc;
}
