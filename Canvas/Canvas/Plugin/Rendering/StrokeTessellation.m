/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Tessellation.h"

NSUInteger KKTessellatePath(KKBezierPath *path, float startWidth,
                            float endWidth, float outputWidth,
                            float outputHeight, uint8_t lineCap,
                            uint8_t lineJoin, CanvasVertex *vertices) {
  float aaPadding = 1.0f;
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;
  NSUInteger vertexCount = 0;
  BOOL isOpen = !path.closed;
  BOOL tapers = isOpen && fabsf(startWidth - endWidth) > 0.001f;
  float totalSteps = (float)(curveCount * segsPerCurve);

  simd_float2 startCenter = {0, 0}, endCenter = {0, 0};
  simd_float2 startTangent = {0, 0}, endTangent = {0, 0};
  simd_float2 startNormal = {0, 0}, endNormal = {0, 0};

  for (NSUInteger c = 0; c < curveCount; c++) {

    simd_float2 segEndCenter = {0, 0}, segEndNormal = {0, 0};

    for (NSUInteger i = 0; i <= segsPerCurve; i++) {
      float t = (float)i / (float)segsPerCurve;
      NSUInteger nextIdx = (c + 1) % path.count;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      simd_float2 normal =
          KKNormalAtPoint(path, c, segsPerCurve, i, outputWidth, outputHeight);

      simd_float2 pixelPos = {pos.x * outputWidth,
                              (1.0f - pos.y) * outputHeight};
      simd_float2 centered = {pixelPos.x - outputWidth / 2.0f,
                              pixelPos.y - outputHeight / 2.0f};

      if (i == segsPerCurve) {
        segEndCenter = centered;
        segEndNormal = normal;
      }

      BOOL isFirstPoint = (c == 0 && i == 0);
      BOOL isLastPoint = (c == curveCount - 1 && i == segsPerCurve);
      if (isFirstPoint) {
        startCenter = centered;
        startNormal = normal;
        startTangent = (simd_float2){normal.y, -normal.x};
      }
      if (isLastPoint) {
        endCenter = centered;
        endNormal = normal;
        endTangent = (simd_float2){normal.y, -normal.x};
      }

      if (lineJoin == 0) {
        if (i == segsPerCurve &&
            (c < curveCount - 1 || (path.closed && c == curveCount - 1))) {
          NSUInteger nextC = (c < curveCount - 1) ? (c + 1) % path.count : 0;
          simd_float2 nextN =
              KKRawNormalAtSegStart(path, nextC, outputWidth, outputHeight);
          normal = KKMiterNormal(normal, nextN);
          if (isLastPoint) {
            endNormal = normal;
            endTangent = (simd_float2){normal.y, -normal.x};
          }
        } else if (i == 0 && (c > 0 || (path.closed && c == 0))) {
          NSUInteger prevC = (c > 0) ? c - 1 : curveCount - 1;
          simd_float2 prevN =
              KKNormalAtPoint(path, prevC, segsPerCurve, segsPerCurve,
                              outputWidth, outputHeight);
          normal = KKMiterNormal(prevN, normal);
          if (isFirstPoint) {
            startNormal = normal;
            startTangent = (simd_float2){normal.y, -normal.x};
          }
        }
      }

      if (i == 0 && c > 0 && lineJoin != 0)
        continue;

      if (i == 0 && c > 0 && lineJoin == 0 && vertexCount > 0) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
      }

      float globalT =
          totalSteps > 0 ? (float)(c * segsPerCurve + i) / totalSteps : 0.0f;
      float hw =
          tapers ? ((startWidth + (endWidth - startWidth) * globalT) / 2.0f +
                    aaPadding)
                 : (startWidth / 2.0f + aaPadding);

      vertices[vertexCount].position = centered + normal * hw;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = centered - normal * hw;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
    }

    BOOL atJoin = (c < curveCount - 1) || (path.closed && c == curveCount - 1);
    float joinT =
        totalSteps > 0 ? (float)((c + 1) * segsPerCurve) / totalSteps : 0.0f;
    float joinHW =
        tapers ? ((startWidth + (endWidth - startWidth) * joinT) / 2.0f +
                  aaPadding)
               : (startWidth / 2.0f + aaPadding);
    if (atJoin && lineJoin != 0) {
      NSUInteger nextC = (c + 1) % curveCount;
      if (path.closed && c == curveCount - 1)
        nextC = 0;
      simd_float2 n2 =
          KKRawNormalAtSegStart(path, nextC, outputWidth, outputHeight);

      vertexCount = KKEmitJoinGeometry(vertices, vertexCount, segEndCenter,
                                       segEndNormal, n2, joinHW, lineJoin);

      if (c < curveCount - 1) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
        vertices[vertexCount].position = segEndCenter + n2 * joinHW;
        vertices[vertexCount].edgeDistance = 1.0f;
        vertices[vertexCount].capDistance = 0.0f;
        vertexCount++;
        vertices[vertexCount].position = segEndCenter - n2 * joinHW;
        vertices[vertexCount].edgeDistance = -1.0f;
        vertices[vertexCount].capDistance = 0.0f;
        vertexCount++;
      }
    } else if (c < curveCount - 1 && lineJoin == 0) {
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
    }
  }

  if (isOpen && lineCap != 0 && curveCount > 0) {
    float startHW = startWidth / 2.0f + aaPadding;
    float endHW = endWidth / 2.0f + aaPadding;
    if (lineCap == 1) {
      vertexCount = KKAddRoundCap(vertices, vertexCount, endCenter, endTangent,
                                  endNormal, endHW, NO);
      if (vertexCount > 0) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
      }
      CanvasVertex startFirst;
      startFirst.position = startCenter + startNormal * startHW;
      startFirst.edgeDistance = 0.0f;
      startFirst.capDistance = 0.0f;
      vertices[vertexCount] = startFirst;
      vertexCount++;
      vertices[vertexCount] = startFirst;
      vertexCount++;
      vertexCount = KKAddRoundCap(vertices, vertexCount, startCenter,
                                  startTangent, startNormal, startHW, YES);
    } else if (lineCap == 2) {
      float endExt = endWidth / 2.0f;

      simd_float2 eTop = endCenter + endNormal * endHW;
      simd_float2 eBot = endCenter - endNormal * endHW;
      simd_float2 eTopExt = eTop + endTangent * endExt;
      simd_float2 eBotExt = eBot + endTangent * endExt;

      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
      vertices[vertexCount].position = eTop;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
      vertices[vertexCount].position = eTop;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = eBot;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = eTopExt;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = eBotExt;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;

      float startExt = startWidth / 2.0f;
      simd_float2 sTop = startCenter + startNormal * startHW;
      simd_float2 sBot = startCenter - startNormal * startHW;
      simd_float2 sTopExt = sTop - startTangent * startExt;
      simd_float2 sBotExt = sBot - startTangent * startExt;

      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
      vertices[vertexCount].position = sTopExt;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
      vertices[vertexCount].position = sTopExt;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = sBotExt;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = sTop;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = sBot;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
    }
  }

  return vertexCount;
}

NSUInteger KKTessellateTrimmedPath(KKBezierPath *path, float startWidth,
                                   float endWidth, float outputWidth,
                                   float outputHeight, uint8_t lineCap,
                                   uint8_t lineJoin, float startTrim,
                                   float endTrim, CanvasVertex *vertices) {
  if (startTrim <= 0.0f && endTrim <= 0.0f) {
    return KKTessellatePath(path, startWidth, endWidth, outputWidth,
                            outputHeight, lineCap, lineJoin, vertices);
  }

  float aaPadding = 1.0f;
  BOOL isOpen = !path.closed;
  BOOL tapers = isOpen && fabsf(startWidth - endWidth) > 0.001f;

  PathSample *samples = NULL;
  NSUInteger count =
      KKSamplePathPolyline(path, outputWidth, outputHeight, &samples);
  if (count < 2) {
    free(samples);
    return 0;
  }

  float totalArc = samples[count - 1].arcLength;
  float arcStart = startTrim;
  float arcEnd = totalArc - endTrim;
  if (arcStart >= arcEnd) {
    free(samples);
    return 0;
  }

  NSUInteger vc = 0;
  NSUInteger hint = 0;

  // Find the first and last sample indices within the trimmed range.
  NSUInteger firstIdx = 0;
  while (firstIdx < count && samples[firstIdx].arcLength < arcStart)
    firstIdx++;
  NSUInteger lastIdx = count - 1;
  while (lastIdx > 0 && samples[lastIdx].arcLength > arcEnd)
    lastIdx--;

  // Emit the interpolated start point.
  PathSample trimStart = KKSampleAtArc(samples, count, arcStart, &hint);
  float tsT = (totalArc > 0) ? arcStart / totalArc : 0.0f;
  float tsHW =
      tapers ? ((startWidth + (endWidth - startWidth) * tsT) / 2.0f + aaPadding)
             : (startWidth / 2.0f + aaPadding);
  vertices[vc].position = trimStart.position + trimStart.normal * tsHW;
  vertices[vc].edgeDistance = 1.0f;
  vertices[vc].capDistance = 0.0f;
  vc++;
  vertices[vc].position = trimStart.position - trimStart.normal * tsHW;
  vertices[vc].edgeDistance = -1.0f;
  vertices[vc].capDistance = 0.0f;
  vc++;

  // Emit interior samples.
  for (NSUInteger i = firstIdx; i <= lastIdx; i++) {
    simd_float2 n = samples[i].normal;
    if (lineJoin == 0 && i > 0 && i < count - 1) {
      simd_float2 n2 = samples[i + 1].normal;
      simd_float2 miter = KKMiterNormal(samples[i].normal, n2);
      float miterLen = simd_length(miter);
      if (miterLen > 0.0f && miterLen < kMiterLimit)
        n = miter;
    }
    float iT = (totalArc > 0) ? samples[i].arcLength / totalArc : 0.0f;
    float iHW =
        tapers
            ? ((startWidth + (endWidth - startWidth) * iT) / 2.0f + aaPadding)
            : (startWidth / 2.0f + aaPadding);
    vertices[vc].position = samples[i].position + n * iHW;
    vertices[vc].edgeDistance = 1.0f;
    vertices[vc].capDistance = 0.0f;
    vc++;
    vertices[vc].position = samples[i].position - n * iHW;
    vertices[vc].edgeDistance = -1.0f;
    vertices[vc].capDistance = 0.0f;
    vc++;

    // Curve→curve boundary: emit round/bevel join geometry, then re-seed the
    // strip at the joint with the next curve's starting normal so subsequent
    // samples flow cleanly into curve c+1.
    if (samples[i].atJoin && lineJoin != 0 && i < lastIdx) {
      simd_float2 n2 = samples[i].nextCurveStartNormal;
      vc = KKEmitJoinGeometry(vertices, vc, samples[i].position,
                              samples[i].normal, n2, iHW, lineJoin);
      vertices[vc] = vertices[vc - 1];
      vc++;
      vertices[vc].position = samples[i].position + n2 * iHW;
      vertices[vc].edgeDistance = 1.0f;
      vertices[vc].capDistance = 0.0f;
      vc++;
      vertices[vc].position = samples[i].position - n2 * iHW;
      vertices[vc].edgeDistance = -1.0f;
      vertices[vc].capDistance = 0.0f;
      vc++;
    }
  }

  // Emit the interpolated end point.
  PathSample trimEnd = KKSampleAtArc(samples, count, arcEnd, &hint);
  float teT = (totalArc > 0) ? arcEnd / totalArc : 0.0f;
  float teHW =
      tapers ? ((startWidth + (endWidth - startWidth) * teT) / 2.0f + aaPadding)
             : (startWidth / 2.0f + aaPadding);
  vertices[vc].position = trimEnd.position + trimEnd.normal * teHW;
  vertices[vc].edgeDistance = 1.0f;
  vertices[vc].capDistance = 0.0f;
  vc++;
  vertices[vc].position = trimEnd.position - trimEnd.normal * teHW;
  vertices[vc].edgeDistance = -1.0f;
  vertices[vc].capDistance = 0.0f;
  vc++;

  // Add caps at trimmed endpoints if the original path is open and has caps,
  // but only at ends without a positive trim (markers use trim > 0).
  float sCapHW = startWidth / 2.0f + aaPadding;
  float eCapHW = endWidth / 2.0f + aaPadding;
  if (isOpen && lineCap != 0) {
    // End cap first (appended right after the stroke body — short bridge).
    if (endTrim <= 0.0f) {
      simd_float2 eTan = (simd_float2){trimEnd.normal.y, -trimEnd.normal.x};
      if (lineCap == 1) {
        vc = KKAddRoundCap(vertices, vc, trimEnd.position, eTan, trimEnd.normal,
                           eCapHW, NO);
      }
    }
    // Start cap last — needs a full degenerate bridge back to the path start,
    // matching the pattern in KKTessellatePath.
    if (startTrim <= 0.0f) {
      simd_float2 sTan = (simd_float2){trimStart.normal.y, -trimStart.normal.x};
      if (lineCap == 1) {
        if (vc > 0) {
          vertices[vc] = vertices[vc - 1];
          vc++;
        }
        CanvasVertex startFirst;
        startFirst.position = trimStart.position + trimStart.normal * sCapHW;
        startFirst.edgeDistance = 0.0f;
        startFirst.capDistance = 0.0f;
        vertices[vc] = startFirst;
        vc++;
        vertices[vc] = startFirst;
        vc++;
        vc = KKAddRoundCap(vertices, vc, trimStart.position, -sTan,
                           trimStart.normal, sCapHW, YES);
      }
    }
  }

  free(samples);
  return vc;
}
