/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Hand-drawn (rough.js-style) path + hachure jitter for the Sketch feature.
// Ported from the pre-v3 SketchPath: anchor/handle jitter + perpendicular
// bowing on linear segments, with a roughness-gain dampening by segment length.
// v3 reads geometry, not flat path props, so the caller passes the effective
// stroke width (the jitter scale) rather than the function reading it.

#import "CanvasSketchPath.h"

// Seeded PRNG (xorshift32). Returns float in [0, 1). File-static, seeded per
// call - the render encodes paths sequentially within an instance's XPC.
static uint32_t s_rngState;

static void seedRNG(uint32_t seed) { s_rngState = seed ? seed : 1; }

static float randUnit(void) {
  s_rngState ^= s_rngState << 13;
  s_rngState ^= s_rngState >> 17;
  s_rngState ^= s_rngState << 5;
  return (float)(s_rngState & 0xFFFF) / 65536.0f;
}

// Offset in [-x, x] scaled by roughness and roughnessGain.
static float offsetOpt(float x, float roughness, float roughnessGain) {
  return roughness * roughnessGain * (randUnit() * 2.0f * x - x);
}

// Roughness gain dampening based on segment length (normalised coords). Short
// segments (dense curves) get reduced gain to avoid a jagged zigzag; long
// segments also dampen (rough.js behaviour).
static float roughnessGainForLength(float length) {
  if (length < 0.005f)
    return 0.15f;
  if (length < 0.02f)
    return 0.15f + (length - 0.005f) * ((1.0f - 0.15f) / (0.02f - 0.005f));
  if (length < 0.1f)
    return 1.0f;
  if (length > 0.25f)
    return 0.4f;
  return (-3.334f) * length + 1.333f;
}

static BOOL isSegmentLinear(KKBezierPoint p0, KKBezierPoint p1) {
  if (p0.type == KKBezierPointLinear && p1.type == KKBezierPointLinear)
    return YES;
  if (p0.type == KKBezierPointBezier) {
    float hLen = p0.outX * p0.outX + p0.outY * p0.outY + p1.inX * p1.inX +
                 p1.inY * p1.inY;
    if (hLen < 0.000001f)
      return YES;
  }
  return NO;
}

// Build one continuous jittered pass. Each original point becomes one jittered
// point; linear segments get bowing via bezier handles, curve segments get
// subtle handle jitter. `overlay` halves the jitter (the second pass).
static KKBezierPath *buildPass(KKBezierPath *path, float roughness,
                               float bowing, float baseOffset, BOOL overlay) {
  NSUInteger segCount = path.closed ? path.count : (path.count - 1);
  NSUInteger ptCount = path.count;

  KKBezierPath *pass = [[KKBezierPath alloc] init];
  pass.closed = path.closed;

  // Points touching a curve segment get reduced position jitter: heavy anchor
  // jitter on tight arcs (rounded corners) opens visible gaps between curves.
  BOOL *touchesCurve = calloc(ptCount, sizeof(BOOL));
  for (NSUInteger i = 0; i < segCount; i++) {
    KKBezierPoint p0 = [path pointAtIndex:i];
    NSUInteger ni = (i + 1) % path.count;
    KKBezierPoint p1 = [path pointAtIndex:ni];
    if (!isSegmentLinear(p0, p1)) {
      touchesCurve[i] = YES;
      if (ni < ptCount)
        touchesCurve[ni] = YES;
    }
  }

  for (NSUInteger i = 0; i < ptCount; i++) {
    KKBezierPoint orig = [path pointAtIndex:i];
    float dx2 = 0, dy2 = 0;
    if (i < segCount) {
      NSUInteger ni = (i + 1) % path.count;
      KKBezierPoint next = [path pointAtIndex:ni];
      dx2 = next.x - orig.x;
      dy2 = next.y - orig.y;
    } else if (i > 0) {
      KKBezierPoint prev = [path pointAtIndex:i - 1];
      dx2 = orig.x - prev.x;
      dy2 = orig.y - prev.y;
    }
    float segLen = sqrtf(dx2 * dx2 + dy2 * dy2);
    float rGain = roughnessGainForLength(segLen);
    float off = overlay ? baseOffset * 0.5f : baseOffset;
    if (touchesCurve[i])
      off *= 0.2f;
    float jx = offsetOpt(off, roughness, rGain);
    float jy = offsetOpt(off, roughness, rGain);
    [pass insertAtIndex:i position:(simd_float2){orig.x + jx, orig.y + jy}];
  }
  free(touchesCurve);

  for (NSUInteger i = 0; i < segCount; i++) {
    KKBezierPoint p0 = [path pointAtIndex:i];
    NSUInteger ni = (i + 1) % path.count;
    KKBezierPoint p1 = [path pointAtIndex:ni];

    float dx = p1.x - p0.x;
    float dy = p1.y - p0.y;
    float segLen = sqrtf(dx * dx + dy * dy);
    float rGain = roughnessGainForLength(segLen);

    if (isSegmentLinear(p0, p1)) {
      if (bowing > 0.0001f && segLen > 0.0001f) {
        float off = overlay ? baseOffset * 0.5f : baseOffset;
        // Bowing: perpendicular midpoint displacement (rough.js style).
        float midDispX = bowing * off * dy / 0.5f;
        float midDispY = bowing * off * (p0.x - p1.x) / 0.5f;
        midDispX = offsetOpt(midDispX, roughness, rGain);
        midDispY = offsetOpt(midDispY, roughness, rGain);

        float divergePoint = 0.2f + randUnit() * 0.2f;
        float oFull = overlay ? baseOffset * 0.5f : baseOffset;

        float cp1x = midDispX + p0.x + dx * divergePoint +
                     offsetOpt(oFull, roughness, rGain);
        float cp1y = midDispY + p0.y + dy * divergePoint +
                     offsetOpt(oFull, roughness, rGain);
        float cp2x = midDispX + p0.x + dx * 2.0f * divergePoint +
                     offsetOpt(oFull, roughness, rGain);
        float cp2y = midDispY + p0.y + dy * 2.0f * divergePoint +
                     offsetOpt(oFull, roughness, rGain);

        KKBezierPoint jp0 = [pass pointAtIndex:i];
        [pass setType:KKBezierPointBezier atIndex:i];
        [pass setOutHandle:(simd_float2){cp1x - jp0.x, cp1y - jp0.y} atIndex:i];

        NSUInteger ti = ni < ptCount ? ni : 0;
        [pass setType:KKBezierPointBezier atIndex:ti];
        KKBezierPoint existing = [pass pointAtIndex:ti];
        [pass setInHandle:(simd_float2){cp2x - existing.x, cp2y - existing.y}
                  atIndex:ti];
      }
    } else {
      // Curve segment: jitter handles subtly (20% of base), plus bowing.
      float curveOff = baseOffset * 0.2f;
      float bowOutX = 0, bowOutY = 0, bowInX = 0, bowInY = 0;
      if (bowing > 0.0001f && segLen > 0.0001f) {
        float off = overlay ? baseOffset * 0.5f : baseOffset;
        float perpX = -dy;
        float perpY = dx;
        float bowScale = bowing * off * 0.5f;
        bowOutX = offsetOpt(bowScale * perpX, roughness, rGain);
        bowOutY = offsetOpt(bowScale * perpY, roughness, rGain);
        bowInX = offsetOpt(bowScale * perpX, roughness, rGain);
        bowInY = offsetOpt(bowScale * perpY, roughness, rGain);
      }
      [pass setType:KKBezierPointBezier atIndex:i];
      [pass
          setOutHandle:(simd_float2){p0.outX + bowOutX +
                                         offsetOpt(curveOff, roughness, rGain),
                                     p0.outY + bowOutY +
                                         offsetOpt(curveOff, roughness, rGain)}
               atIndex:i];

      NSUInteger targetIdx = ni < ptCount ? ni : 0;
      [pass setType:KKBezierPointBezier atIndex:targetIdx];
      [pass setInHandle:(simd_float2){p1.inX + bowInX +
                                          offsetOpt(curveOff, roughness, rGain),
                                      p1.inY + bowInY +
                                          offsetOpt(curveOff, roughness, rGain)}
                atIndex:targetIdx];
    }
  }

  return pass;
}

// Roughness gain dampening by pixel length (rough.js _line scaling): shorter
// lines get full roughness, longer lines dampen.
static float pixelRoughnessGain(float pixelLength) {
  if (pixelLength < 200.0f)
    return 1.0f;
  if (pixelLength > 500.0f)
    return 0.4f;
  return (-0.0016668f) * pixelLength + 1.233334f;
}

void CanvasSketchifyHachureLines(CanvasHachureLine **lines, NSUInteger *count,
                                 float roughness, float bowing, uint32_t seed,
                                 float canvasWidth, float canvasHeight) {
  (void)canvasWidth;
  (void)canvasHeight;
  if (!lines || !*lines || *count == 0 || roughness <= 0.0001f)
    return;

  NSUInteger inCount = *count;
  CanvasHachureLine *inLines = *lines;

  // Seed offset so fill jitter differs from stroke jitter.
  seedRNG(seed ^ 0xBEEF1234);

  float maxOff = roughness * 2.0f; // rough.js maxRandomnessOffset
  NSUInteger segsPerLine = 8;
  NSUInteger outCapacity = inCount * segsPerLine;
  CanvasHachureLine *out = malloc(outCapacity * sizeof(CanvasHachureLine));
  NSUInteger oc = 0;

  for (NSUInteger i = 0; i < inCount; i++) {
    simd_float2 a = inLines[i].a;
    simd_float2 b = inLines[i].b;
    float dx = b.x - a.x, dy = b.y - a.y;
    float lenSq = dx * dx + dy * dy;
    float len = sqrtf(lenSq);
    if (len < 0.5f) {
      out[oc++] = inLines[i];
      continue;
    }
    float off = maxOff;
    if (off * off * 100.0f > lenSq)
      off = len / 10.0f; // clamp so short lines don't explode
    float rGain = pixelRoughnessGain(len);

    float jbx = offsetOpt(off, roughness, rGain);
    float jby = offsetOpt(off, roughness, rGain);
    simd_float2 jb = {b.x + jbx, b.y + jby};

    float midDispX = bowing * maxOff * (dy) / 200.0f;
    float midDispY = bowing * maxOff * (a.x - b.x) / 200.0f;
    midDispX = offsetOpt(midDispX, roughness, rGain);
    midDispY = offsetOpt(midDispY, roughness, rGain);

    float diverge = 0.2f + randUnit() * 0.2f;
    simd_float2 cp1 = {
        midDispX + a.x + dx * diverge + offsetOpt(off, roughness, rGain),
        midDispY + a.y + dy * diverge + offsetOpt(off, roughness, rGain)};
    simd_float2 cp2 = {midDispX + a.x + dx * 2.0f * diverge +
                           offsetOpt(off, roughness, rGain),
                       midDispY + a.y + dy * 2.0f * diverge +
                           offsetOpt(off, roughness, rGain)};

    simd_float2 prev = a;
    for (NSUInteger s = 1; s <= segsPerLine; s++) {
      float t = (float)s / (float)segsPerLine;
      float u = 1.0f - t;
      simd_float2 pt = {u * u * u * a.x + 3.0f * u * u * t * cp1.x +
                            3.0f * u * t * t * cp2.x + t * t * t * jb.x,
                        u * u * u * a.y + 3.0f * u * u * t * cp1.y +
                            3.0f * u * t * t * cp2.y + t * t * t * jb.y};
      out[oc++] = (CanvasHachureLine){prev, pt};
      prev = pt;
    }
  }

  free(inLines);
  *lines = out;
  *count = oc;
}

KKBezierPath *CanvasSketchPath(KKBezierPath *path, float roughness,
                               float bowing, uint32_t seed, uint8_t strokes,
                               float strokeWidth, float canvasWidth,
                               float canvasHeight) {
  if (path.count < 2 || roughness <= 0.0001f)
    return path;

  // Compound paths: sketch each contour independently, then reassemble with the
  // contour starts preserved so the renderer's split sees them again.
  if (path.contourCount > 1) {
    NSArray<KKBezierPath *> *subs = [path splitContours];
    if (subs.count > 1) {
      KKBezierPath *combined = [[KKBezierPath alloc] init];
      NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
      for (NSUInteger si = 0; si < subs.count; si++) {
        KKBezierPath *sketched = CanvasSketchPath(
            subs[si], roughness, bowing, seed + (uint32_t)si * 0x9E3779B1u,
            strokes, strokeWidth, canvasWidth, canvasHeight);
        if (si > 0)
          [starts addObject:@(combined.count)];
        for (NSUInteger i = 0; i < sketched.count; i++) {
          KKBezierPoint pt = [sketched pointAtIndex:i];
          NSUInteger ci = combined.count;
          [combined insertAtIndex:ci position:(simd_float2){pt.x, pt.y}];
          [combined setType:pt.type atIndex:ci];
          if (pt.type == KKBezierPointBezier) {
            [combined setOutHandle:(simd_float2){pt.outX, pt.outY} atIndex:ci];
            [combined setInHandle:(simd_float2){pt.inX, pt.inY} atIndex:ci];
          }
        }
      }
      combined.closed = path.closed;
      [combined setContourStarts:starts];
      return combined;
    }
  }

  seedRNG(seed);

  float canvasSize = fmaxf(canvasWidth, canvasHeight);
  if (canvasSize < 1.0f)
    canvasSize = 1920.0f;
  float strokeNorm = fmaxf(strokeWidth, 1.0f) / canvasSize;
  float baseOffset = strokeNorm * 1.5f + 0.003f;

  KKBezierPath *pass1 = buildPass(path, roughness, bowing, baseOffset, NO);
  if (strokes < 2)
    return pass1;

  // Double-draw: append a half-jitter overlay pass as a disjoint subpath so the
  // renderer strokes both. Open pass1 so the two read as separate strokes.
  KKBezierPath *pass2 = buildPass(path, roughness, bowing, baseOffset, YES);
  pass1.closed = NO;
  NSUInteger p1Count = pass1.count;
  for (NSUInteger i = 0; i < pass2.count; i++) {
    KKBezierPoint pt = [pass2 pointAtIndex:i];
    [pass1 insertAtIndex:p1Count + i position:(simd_float2){pt.x, pt.y}];
    [pass1 setType:pt.type atIndex:p1Count + i];
    if (pt.type == KKBezierPointBezier) {
      [pass1 setOutHandle:(simd_float2){pt.outX, pt.outY} atIndex:p1Count + i];
      [pass1 setInHandle:(simd_float2){pt.inX, pt.inY} atIndex:p1Count + i];
    }
  }
  return pass1;
}
