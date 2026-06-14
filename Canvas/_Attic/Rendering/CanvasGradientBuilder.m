/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasGradientBuilder.h"
#import <KeyframelessKit/KKGradientSampling.h>

BOOL KKBuildCanvasGradientSamples(KKBezierPath *path, BOOL isStroke,
                                  CanvasGradientParams *out) {
  uint8_t mode = isStroke ? path.strokeColorMode : path.fillColorMode;
  if (mode != 1) {
    out->useGradient = 0;
    return NO;
  }
  NSString *json = isStroke ? path.strokeGradientJSON : path.fillGradientJSON;
  if (json.length == 0)
    json = KKDefaultGradientJSON();
  NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
  if (stops.count < 2) {
    out->useGradient = 0;
    return NO;
  }
  KKGradientSampleStopsToLUT(stops, out->lut, KK_GRADIENT_LUT_SIZE);
  out->useGradient = 1;
  out->gradientType =
      isStroke ? path.strokeGradientType : path.fillGradientType;
  out->gradientAngle =
      isStroke ? path.strokeGradientAngle : path.fillGradientAngle;
  return YES;
}

void KKCanvasPathBBoxCenteredPx(KKBezierPath *path, float outputWidth,
                                float outputHeight, float pad,
                                simd_float2 *bbMin, simd_float2 *bbMax) {
  simd_float2 lo = (simd_float2){FLT_MAX, FLT_MAX};
  simd_float2 hi = (simd_float2){-FLT_MAX, -FLT_MAX};
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    // Framebuffer-Y convention (no (1-y) flip): the fragment shader's
    // [[position]] is Y-down framebuffer pixels, so the bbox must be in the
    // same space or sampling is inverted relative to the rendered geometry.
    float px = pt.x * outputWidth - outputWidth * 0.5f;
    float py = pt.y * outputHeight - outputHeight * 0.5f;
    if (px < lo.x)
      lo.x = px;
    if (py < lo.y)
      lo.y = py;
    if (px > hi.x)
      hi.x = px;
    if (py > hi.y)
      hi.y = py;
  }
  lo.x -= pad;
  lo.y -= pad;
  hi.x += pad;
  hi.y += pad;
  *bbMin = lo;
  *bbMax = hi;
}
