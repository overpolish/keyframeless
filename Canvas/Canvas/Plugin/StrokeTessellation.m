/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Tessellation.h"

NSUInteger KKTessellatePath(KKBezierPath *path, float strokeWidth,
                            float outputWidth, float outputHeight,
                            uint8_t lineCap, uint8_t lineJoin,
                            CanvasVertex *vertices) {
  float aaPadding = 1.0f;
  float halfWidth = (strokeWidth / 2.0f) + aaPadding;
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;
  NSUInteger vertexCount = 0;
  BOOL isOpen = !path.closed;

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

      vertices[vertexCount].position = centered + normal * halfWidth;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = centered - normal * halfWidth;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
    }

    BOOL atJoin = (c < curveCount - 1) || (path.closed && c == curveCount - 1);
    if (atJoin && lineJoin != 0) {
      NSUInteger nextC = (c + 1) % curveCount;
      if (path.closed && c == curveCount - 1)
        nextC = 0;
      simd_float2 n2 =
          KKRawNormalAtSegStart(path, nextC, outputWidth, outputHeight);

      vertexCount = KKEmitJoinGeometry(vertices, vertexCount, segEndCenter,
                                       segEndNormal, n2, halfWidth, lineJoin);

      if (c < curveCount - 1) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
        vertices[vertexCount].position = segEndCenter + n2 * halfWidth;
        vertices[vertexCount].edgeDistance = 1.0f;
        vertices[vertexCount].capDistance = 0.0f;
        vertexCount++;
        vertices[vertexCount].position = segEndCenter - n2 * halfWidth;
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
    if (lineCap == 1) {
      vertexCount = KKAddRoundCap(vertices, vertexCount, endCenter, endTangent,
                                  endNormal, halfWidth, NO);
      if (vertexCount > 0) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
      }
      CanvasVertex startFirst;
      startFirst.position = startCenter + startNormal * halfWidth;
      startFirst.edgeDistance = 0.0f;
      startFirst.capDistance = 0.0f;
      vertices[vertexCount] = startFirst;
      vertexCount++;
      vertices[vertexCount] = startFirst;
      vertexCount++;
      vertexCount = KKAddRoundCap(vertices, vertexCount, startCenter,
                                  startTangent, startNormal, halfWidth, YES);
    } else if (lineCap == 2) {
      float ext = strokeWidth / 2.0f;

      simd_float2 eTop = endCenter + endNormal * halfWidth;
      simd_float2 eBot = endCenter - endNormal * halfWidth;
      simd_float2 eTopExt = eTop + endTangent * ext;
      simd_float2 eBotExt = eBot + endTangent * ext;

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

      simd_float2 sTop = startCenter + startNormal * halfWidth;
      simd_float2 sBot = startCenter - startNormal * halfWidth;
      simd_float2 sTopExt = sTop - startTangent * ext;
      simd_float2 sBotExt = sBot - startTangent * ext;

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

NSUInteger KKTessellateTrimmedPath(KKBezierPath *path, float strokeWidth,
                                   float outputWidth, float outputHeight,
                                   uint8_t lineCap, uint8_t lineJoin,
                                   float startTrim, float endTrim,
                                   CanvasVertex *vertices) {
  if (startTrim <= 0.0f && endTrim <= 0.0f) {
    return KKTessellatePath(path, strokeWidth, outputWidth, outputHeight,
                            lineCap, lineJoin, vertices);
  }

  float aaPadding = 1.0f;
  float halfWidth = (strokeWidth / 2.0f) + aaPadding;

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
  vertices[vc].position = trimStart.position + trimStart.normal * halfWidth;
  vertices[vc].edgeDistance = 1.0f;
  vertices[vc].capDistance = 0.0f;
  vc++;
  vertices[vc].position = trimStart.position - trimStart.normal * halfWidth;
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
    vertices[vc].position = samples[i].position + n * halfWidth;
    vertices[vc].edgeDistance = 1.0f;
    vertices[vc].capDistance = 0.0f;
    vc++;
    vertices[vc].position = samples[i].position - n * halfWidth;
    vertices[vc].edgeDistance = -1.0f;
    vertices[vc].capDistance = 0.0f;
    vc++;
  }

  // Emit the interpolated end point.
  PathSample trimEnd = KKSampleAtArc(samples, count, arcEnd, &hint);
  vertices[vc].position = trimEnd.position + trimEnd.normal * halfWidth;
  vertices[vc].edgeDistance = 1.0f;
  vertices[vc].capDistance = 0.0f;
  vc++;
  vertices[vc].position = trimEnd.position - trimEnd.normal * halfWidth;
  vertices[vc].edgeDistance = -1.0f;
  vertices[vc].capDistance = 0.0f;
  vc++;

  // Add caps at trimmed endpoints if the original path is open and has caps,
  // but only at ends that don't have markers (trim == 0 means no marker).
  BOOL isOpen = !path.closed;
  if (isOpen && lineCap != 0) {
    if (startTrim <= 0.0f) {
      simd_float2 sTan = (simd_float2){trimStart.normal.y, -trimStart.normal.x};
      if (lineCap == 1) {
        vc = KKAddRoundCap(vertices, vc, trimStart.position, -sTan,
                           trimStart.normal, halfWidth, YES);
      }
    }
    if (endTrim <= 0.0f) {
      simd_float2 eTan = (simd_float2){trimEnd.normal.y, -trimEnd.normal.x};
      if (lineCap == 1) {
        vc = KKAddRoundCap(vertices, vc, trimEnd.position, eTan, trimEnd.normal,
                           halfWidth, NO);
      }
    }
  }

  free(samples);
  return vc;
}
