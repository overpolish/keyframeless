/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "SketchPath.h"

// Seeded PRNG (xorshift32). Returns float in [0, 1).
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

// Roughness gain dampening based on segment length (normalized coords).
static float roughnessGainForLength(float length) {
  if (length < 0.1f)
    return 1.0f;
  if (length > 0.25f)
    return 0.4f;
  return (-3.334f) * length + 1.333f;
}

/// Copy all rendering properties from src to dst (except geometry).
static void copyPathProps(KKBezierPath *dst, KKBezierPath *src) {
  dst.closed = src.closed;
  dst.isRect = NO;
  dst.hidden = src.hidden;
  dst.locked = src.locked;
  dst.name = src.name;
  dst.parentGroupID = src.parentGroupID;
  dst.strokeEnabled = src.strokeEnabled;
  dst.strokeWidth = src.strokeWidth;
  dst.strokeR = src.strokeR;
  dst.strokeG = src.strokeG;
  dst.strokeB = src.strokeB;
  dst.opacity = src.opacity;
  dst.lineCap = src.lineCap;
  dst.lineJoin = src.lineJoin;
  dst.strokeStyle = src.strokeStyle;
  dst.dashLength = src.dashLength;
  dst.dashGap = src.dashGap;
  dst.dotGap = src.dotGap;
  dst.fillEnabled = src.fillEnabled;
  dst.fillR = src.fillR;
  dst.fillG = src.fillG;
  dst.fillB = src.fillB;
  dst.sketchEnabled = src.sketchEnabled;
  dst.sketchRoughness = src.sketchRoughness;
  dst.sketchBowing = src.sketchBowing;
  dst.sketchFillStyle = src.sketchFillStyle;
  dst.sketchFillGap = src.sketchFillGap;
  dst.sketchFillAngle = src.sketchFillAngle;
  dst.sketchFillWeight = src.sketchFillWeight;
  dst.sketchSeed = src.sketchSeed;
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

/// Build one continuous pass of the sketch path.
/// Each original point becomes one jittered point in the output.
/// Linear segments get bowing via bezier handles.
/// Curve segments get subtle handle jitter.
/// If `overlay` is YES, jitter is halved (second pass).
static KKBezierPath *buildPass(KKBezierPath *path, float roughness,
                               float bowing, float baseOffset, BOOL overlay) {
  NSUInteger segCount = path.closed ? path.count : (path.count - 1);
  NSUInteger ptCount = path.closed ? path.count : path.count;

  KKBezierPath *pass = [[KKBezierPath alloc] init];
  copyPathProps(pass, path);
  pass.lineJoin = 1;
  pass.lineCap = 1;

  // Determine which points touch a curve segment so we can reduce their
  // position jitter. Heavy anchor jitter on tight arcs (rounded corners)
  // creates visible gaps between adjacent curves.
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

  // Insert all points with jittered positions.
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
    // Points on curve segments get 20% position jitter to match handle jitter.
    if (touchesCurve[i])
      off *= 0.2f;

    float jx = offsetOpt(off, roughness, rGain);
    float jy = offsetOpt(off, roughness, rGain);
    [pass insertAtIndex:i position:(simd_float2){orig.x + jx, orig.y + jy}];
  }
  free(touchesCurve);

  // Set handles per-segment.
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

        // Bowing: perpendicular midpoint displacement (Rough.js style).
        float midDispX = bowing * off * dy / 0.5f;
        float midDispY = bowing * off * (p0.x - p1.x) / 0.5f;
        midDispX = offsetOpt(midDispX, roughness, rGain);
        midDispY = offsetOpt(midDispY, roughness, rGain);

        float divergePoint = 0.2f + randUnit() * 0.2f;
        float oFull = overlay ? baseOffset * 0.5f : baseOffset;

        // Control point 1 at divergePoint along segment.
        float cp1x = midDispX + p0.x + dx * divergePoint +
                     offsetOpt(oFull, roughness, rGain);
        float cp1y = midDispY + p0.y + dy * divergePoint +
                     offsetOpt(oFull, roughness, rGain);
        // Control point 2 at 2*divergePoint along segment.
        float cp2x = midDispX + p0.x + dx * 2.0f * divergePoint +
                     offsetOpt(oFull, roughness, rGain);
        float cp2y = midDispY + p0.y + dy * 2.0f * divergePoint +
                     offsetOpt(oFull, roughness, rGain);

        // Get jittered positions of the endpoints.
        KKBezierPoint jp0 = [pass pointAtIndex:i];

        [pass setType:KKBezierPointBezier atIndex:i];
        [pass setOutHandle:(simd_float2){cp1x - jp0.x, cp1y - jp0.y} atIndex:i];

        // Only set the in-handle if it hasn't been set by a prior curve
        // segment.
        [pass setType:KKBezierPointBezier atIndex:ni < ptCount ? ni : 0];
        KKBezierPoint existing = [pass pointAtIndex:ni < ptCount ? ni : 0];
        [pass setInHandle:(simd_float2){cp2x - existing.x, cp2y - existing.y}
                  atIndex:ni < ptCount ? ni : 0];
      }
    } else {
      // Curve segment: jitter handles subtly (20% of base offset).
      float curveOff = baseOffset * 0.2f;

      [pass setType:KKBezierPointBezier atIndex:i];
      [pass setOutHandle:(simd_float2){
                             p0.outX + offsetOpt(curveOff, roughness, rGain),
                             p0.outY + offsetOpt(curveOff, roughness, rGain)}
                 atIndex:i];

      NSUInteger targetIdx = ni < ptCount ? ni : 0;
      [pass setType:KKBezierPointBezier atIndex:targetIdx];
      [pass setInHandle:(simd_float2){
                            p1.inX + offsetOpt(curveOff, roughness, rGain),
                            p1.inY + offsetOpt(curveOff, roughness, rGain)}
                atIndex:targetIdx];
    }
  }

  return pass;
}

KKBezierPath *KKSketchPath(KKBezierPath *path, float roughness, float bowing,
                           uint32_t seed, uint8_t strokes, float canvasWidth,
                           float canvasHeight) {
  if (path.count < 2 || roughness <= 0.0001f)
    return path;

  seedRNG(seed);

  float canvasSize = fmaxf(canvasWidth, canvasHeight);
  if (canvasSize < 1.0f)
    canvasSize = 1920.0f;
  float strokeNorm = path.strokeWidth / canvasSize;
  float baseOffset = strokeNorm * 1.5f + 0.003f;

  // Pass 1: primary stroke — continuous path with full jitter.
  KKBezierPath *pass1 = buildPass(path, roughness, bowing, baseOffset, NO);

  if (strokes < 2)
    return pass1;

  // Pass 2: overlay stroke — continuous path with half jitter.
  // We need to combine both passes into a single path for the renderer.
  // Insert pass2 points after pass1 points as a disjoint subpath.
  KKBezierPath *pass2 = buildPass(path, roughness, bowing, baseOffset, YES);

  // Merge: append pass2 points into pass1.
  // Open both paths so they render as two separate strokes.
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
