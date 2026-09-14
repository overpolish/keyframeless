/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Leaf math for the alpha-aware image hit-test: the inverse-bilinear quad solve
// and the CPU alpha-mask sampler. Split out of CanvasLayerHitTest.m (which
// keeps the projection + stroke/polygon picking).

#import "CanvasHitTestGeometry.h"
#import <AppKit/AppKit.h>

static float CanvasCross2(simd_float2 a, simd_float2 b) {
  return a.x * b.y - a.y * b.x;
}

BOOL CanvasInvBilinear(simd_float2 p, simd_float2 a, simd_float2 b,
                       simd_float2 c, simd_float2 d, simd_float2 *outUV) {
  simd_float2 e = b - a;
  simd_float2 f = d - a;
  simd_float2 g = (a - b) + (c - d);
  simd_float2 h = p - a;
  float k2 = CanvasCross2(g, f);
  float k1 = CanvasCross2(e, f) + CanvasCross2(h, g);
  float k0 = CanvasCross2(h, e);
  float u, v;
  // Solve e.x+g.x*v (or the y row if that's degenerate) for u given v.
  float (^uForV)(float) = ^float(float vv) {
    float dux = e.x + g.x * vv;
    if (fabsf(dux) > 1e-9f)
      return (h.x - f.x * vv) / dux;
    float duy = e.y + g.y * vv;
    if (fabsf(duy) > 1e-9f)
      return (h.y - f.y * vv) / duy;
    return -1.0f;
  };
  if (fabsf(k2) < 1e-9f) {
    if (fabsf(k1) < 1e-12f)
      return NO;
    v = -k0 / k1;
    u = uForV(v);
  } else {
    float w = k1 * k1 - 4.0f * k0 * k2;
    if (w < 0.0f)
      return NO;
    w = sqrtf(w);
    float vA = (-k1 - w) / (2.0f * k2);
    float uA = uForV(vA);
    if (vA < 0.0f || vA > 1.0f || uA < 0.0f || uA > 1.0f) {
      float vB = (-k1 + w) / (2.0f * k2);
      v = vB;
      u = uForV(vB);
    } else {
      v = vA;
      u = uA;
    }
  }
  if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f)
    return NO;
  *outUV = simd_make_float2(u, v);
  return YES;
}

// CPU alpha mask for an image path: an upright (row 0 = image TOP) 8-bit
// alpha-only buffer, capped to keep memory + decode cheap. Cached per path
// (this runs in the OSC process; a plain static is fine).
@interface _CanvasAlphaMask : NSObject
@property(nonatomic) NSInteger w;
@property(nonatomic) NSInteger h;
@property(nonatomic, strong) NSData *bytes;
@end
@implementation _CanvasAlphaMask
@end

float CanvasSampleImageAlpha(NSString *imagePath, float u, float v) {
  static NSMutableDictionary<NSString *, _CanvasAlphaMask *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
  });
  _CanvasAlphaMask *mask = cache[imagePath];
  if (!mask) {
    mask =
        [_CanvasAlphaMask new]; // cache misses too (w=0) so we don't re-decode
    cache[imagePath] = mask;
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:imagePath];
    CGImageRef cg =
        img ? [img CGImageForProposedRect:NULL context:nil hints:nil] : NULL;
    if (cg) {
      NSInteger iw = (NSInteger)CGImageGetWidth(cg);
      NSInteger ih = (NSInteger)CGImageGetHeight(cg);
      const NSInteger cap = 512;
      double s = fmin(1.0, (double)cap / (double)MAX(MAX(iw, ih), 1));
      NSInteger w = MAX(1, (NSInteger)(iw * s));
      NSInteger h = MAX(1, (NSInteger)(ih * s));
      NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)(w * h)];
      CGContextRef ctx = CGBitmapContextCreate(
          buf.mutableBytes, w, h, 8, w, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
      if (ctx) {
        // Flip so byte row 0 = image TOP (v=0), matching the render's UV.
        CGContextTranslateCTM(ctx, 0, h);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        CGContextRelease(ctx);
        mask.w = w;
        mask.h = h;
        mask.bytes = buf;
      }
    }
  }
  if (mask.w == 0 || !mask.bytes)
    return 1.0f;
  float uu = fminf(fmaxf(u, 0.0f), 1.0f);
  float vv = fminf(fmaxf(v, 0.0f), 1.0f);
  NSInteger x = (NSInteger)(uu * (mask.w - 1));
  NSInteger y = (NSInteger)(vv * (mask.h - 1));
  const uint8_t *p = (const uint8_t *)mask.bytes.bytes;
  return p[y * mask.w + x] / 255.0f;
}
