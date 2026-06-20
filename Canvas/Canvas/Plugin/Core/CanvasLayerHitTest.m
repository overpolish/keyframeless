/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h" // CanvasHitTestLayerID (public decl)
#import "CanvasLayerTimeline.h"
#import "CanvasLayerTransform.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKPluginHost.h>
#import <KeyframelessKit/KKShape.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <simd/simd.h>

// A layer's on-screen quad corner in object space [0,1] (Y-up), through the SAME
// pipeline the render uses (CanvasComposedModelMatrix + the perspective divide).
// The pipeline is scale-invariant in object space, so we feed a nominal pixel
// scale of (aspect, 1) - only the canvas aspect matters, not the render's true
// pixel dims. tileShift is 0 (the viewer OSC isn't tiled like the render).
static simd_float2 CanvasProjectedCornerObj(float nx, float ny,
                                            CanvasLayerTransform t, float cx,
                                            float cy, float aspect,
                                            const CanvasGroupXform *groups,
                                            NSInteger ng) {
  simd_float2 scl = simd_make_float2(aspect > 0.0f ? aspect : 1.0f, 1.0f);
  simd_float2 half = simd_make_float2(0.5f, 0.5f);
  matrix_float4x4 m = CanvasComposedModelMatrix(t, simd_make_float2(cx, cy),
                                                groups, ng, scl,
                                                simd_make_float2(0, 0));
  simd_float2 pPix = (simd_make_float2(nx, ny) - half) * scl;
  simd_float4 clip = simd_mul(m, simd_make_float4(pPix.x, pPix.y, 0.0f, 1.0f));
  if (clip.w == 0.0f)
    return simd_make_float2(nx, ny);
  simd_float2 screen = simd_make_float2(clip.x / clip.w, clip.y / clip.w);
  return screen / scl + half;
}

static float CanvasCross2(simd_float2 a, simd_float2 b) {
  return a.x * b.y - a.y * b.x;
}

// Inverse bilinear: where is p inside the quad whose corners map to UV
// a=(0,0) b=(1,0) c=(1,1) d=(0,1)? Returns NO when p is outside (u or v beyond
// [0,1]). Standard Inigo-Quilez solution; handles the parallelogram (k2~0)
// degenerate case linearly. Under perspective this is the bilinear approximation
// of the projective UV - precise enough for alpha hit-testing.
static BOOL CanvasInvBilinear(simd_float2 p, simd_float2 a, simd_float2 b,
                              simd_float2 c, simd_float2 d,
                              simd_float2 *outUV) {
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
// alpha-only buffer, capped to keep memory + decode cheap. Cached per path (this
// runs in the OSC process; a plain static is fine). u in [0,1] = left to right,
// v in [0,1] = top to bottom (matching the render's UVs). Returns 1.0 (opaque)
// when the image has no decodable alpha, so opaque formats (JPEG) hit across
// their whole quad.
@interface _CanvasAlphaMask : NSObject
@property(nonatomic) NSInteger w;
@property(nonatomic) NSInteger h;
@property(nonatomic, strong) NSData *bytes;
@end
@implementation _CanvasAlphaMask
@end

static float CanvasSampleImageAlpha(NSString *imagePath, float u, float v) {
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

// YES if `path` is editable at clip fraction `frac`: it has at least one constant
// param (per `templates`) OR an animated lane visible at `frac` (at a keypose or
// its lead-in/out hold). Gates the viewer auto-select so a fully-animated layer
// with no keypose at the playhead isn't pickable.
static BOOL CanvasLayerEditableAtFraction(KKBezierPath *path, double frac,
                                          NSArray<KKLane *> *templates) {
  if (CanvasLayerHasConstant(path, templates))
    return YES;
  if (path.animationJSON.length == 0)
    return YES;
  KKTimeline *tl = [KKTimeline timelineFromJSON:path.animationJSON];
  double frameDur = KKProcessFrameDurationSeconds();
  for (KKLane *l in tl.lanes)
    if (l.enabled && KKLaneVisibleAtFraction(l, frac, frameDur))
      return YES;
  return NO;
}

static NSUInteger CanvasLayerIndexOf(NSArray<KKBezierPath *> *layers,
                                    KKBezierPath *path) {
  NSUInteger idx = [layers indexOfObjectIdenticalTo:path];
  if (idx == NSNotFound)
    for (NSUInteger i = 0; i < layers.count; i++)
      if (layers[i].layerID.length &&
          [layers[i].layerID isEqualToString:path.layerID])
        return i;
  return idx;
}

void CanvasProjectLayerPointsObj(NSArray<KKBezierPath *> *layers,
                                 KKBezierPath *path, double frac, float aspect,
                                 const simd_float2 *localPts,
                                 simd_float2 *outProj, NSUInteger count) {
  if (!path || count == 0)
    return;
  CanvasLayerTransform t = (frac < 0.0)
                               ? CanvasLayerTransformIdentity()
                               : CanvasLayerTransformAtFraction(path, frac);
  simd_float2 c = CanvasLayerObjectCenter(path);
  NSUInteger idx = CanvasLayerIndexOf(layers, path);
  CanvasGroupXform groups[kCanvasGroupXformCap];
  NSInteger ng = (idx == NSNotFound)
                     ? 0
                     : CanvasBuildGroupXforms(layers, idx, frac, nil, nil,
                                              groups, kCanvasGroupXformCap);
  for (NSUInteger i = 0; i < count; i++)
    outProj[i] = CanvasProjectedCornerObj(localPts[i].x, localPts[i].y, t, c.x,
                                          c.y, aspect, groups, ng);
}

simd_float2 CanvasProjectLayerPointObj(NSArray<KKBezierPath *> *layers,
                                       KKBezierPath *path, double frac,
                                       float aspect, float localX,
                                       float localY) {
  simd_float2 in = simd_make_float2(localX, localY), out = in;
  CanvasProjectLayerPointsObj(layers, path, frac, aspect, &in, &out, 1);
  return out;
}

simd_float2 CanvasUnprojectLayerPointObj(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *path, double frac,
                                         float aspect, float screenX,
                                         float screenY) {
  simd_float2 unit[4] = {simd_make_float2(0, 0), simd_make_float2(1, 0),
                         simd_make_float2(1, 1), simd_make_float2(0, 1)};
  simd_float2 proj[4];
  CanvasProjectLayerPointsObj(layers, path, frac, aspect, unit, proj, 4);
  simd_float3x3 H = CanvasSquareToQuadHomography(
      CGPointMake(proj[0].x, proj[0].y), CGPointMake(proj[1].x, proj[1].y),
      CGPointMake(proj[2].x, proj[2].y), CGPointMake(proj[3].x, proj[3].y));
  simd_float3 v =
      simd_mul(simd_inverse(H), simd_make_float3(screenX, screenY, 1.0f));
  if (fabsf(v.z) < 1e-9f)
    return simd_make_float2(screenX, screenY);
  return simd_make_float2(v.x / v.z, v.y / v.z);
}

BOOL CanvasComposedGroupPointObj(NSArray<KKBezierPath *> *layers,
                                 KKBezierPath *member, double frac, float aspect,
                                 float inX, float inY, float *outX, float *outY) {
  if (outX)
    *outX = inX;
  if (outY)
    *outY = inY;
  if (!member || member.isGroup)
    return YES;
  NSUInteger idx = [layers indexOfObjectIdenticalTo:member];
  if (idx == NSNotFound)
    for (NSUInteger i = 0; i < layers.count; i++)
      if (layers[i].layerID.length &&
          [layers[i].layerID isEqualToString:member.layerID]) {
        idx = i;
        break;
      }
  if (idx == NSNotFound)
    return YES;
  CanvasGroupXform groups[kCanvasGroupXformCap];
  NSInteger ng = CanvasBuildGroupXforms(layers, idx, frac, nil, nil, groups,
                                        kCanvasGroupXformCap);
  if (ng == 0)
    return YES;
  // Identity member transform centred on the point: the member model becomes a
  // no-op, so the point (already in clip space) is transformed by the groups
  // alone, through the same perspective the render applies.
  simd_float2 c = CanvasProjectedCornerObj(
      inX, inY, CanvasLayerTransformIdentity(), inX, inY, aspect, groups, ng);
  if (outX)
    *outX = c.x;
  if (outY)
    *outY = c.y;
  return YES;
}

KKRotMatrix3 CanvasComposedGroupRotation(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *member, double frac) {
  KKRotMatrix3 base = KKRotMatrixIdentity();
  if (!member || member.isGroup)
    return base;
  NSUInteger idx = [layers indexOfObjectIdenticalTo:member];
  if (idx == NSNotFound)
    for (NSUInteger i = 0; i < layers.count; i++)
      if (layers[i].layerID.length &&
          [layers[i].layerID isEqualToString:member.layerID]) {
        idx = i;
        break;
      }
  if (idx == NSNotFound)
    return base;
  CanvasGroupXform groups[kCanvasGroupXformCap];
  NSInteger ng = CanvasBuildGroupXforms(layers, idx, frac, nil, nil, groups,
                                        kCanvasGroupXformCap);
  // groups[0] is the innermost parent; compose Rk · base each step so the
  // outermost ends up leftmost (matching the render's group·member order).
  for (NSInteger k = 0; k < ng; k++) {
    KKRotMatrix3 Rk = KKBuildRotationMatrix(groups[k].t.rotX, groups[k].t.rotY,
                                            groups[k].t.rotation);
    base = KKRotMatrixMul(Rk, base);
  }
  return base;
}

// Flatten a vector path to a normalized [0,1] (Y-up) polyline, the raw geometry
// CanvasProjectedCornerObj then projects through the layer transform. Coarser
// than the render tessellation (selection doesn't need 32 steps/segment).
static const NSUInteger kHitFlattenSteps = 16;
static NSUInteger CanvasFlattenPathNormalized(KKBezierPath *path,
                                              simd_float2 *pts,
                                              NSUInteger maxPts) {
  NSUInteger count = path.count;
  if (count < 2)
    return 0;
  NSUInteger segs = path.closed ? count : count - 1;
  NSUInteger n = 0;
  for (NSUInteger c = 0; c < segs; c++) {
    NSUInteger next = (c + 1) % count;
    for (NSUInteger i = 0; i < kHitFlattenSteps; i++) {
      float t = (float)i / (float)kHitFlattenSteps;
      simd_float2 p = [path evaluatePointAtIndex:c nextIndex:next atT:t];
      if (n > 0 && simd_distance_squared(p, pts[n - 1]) < 1e-9f)
        continue;
      if (n < maxPts)
        pts[n++] = p;
    }
  }
  if (!path.closed) {
    simd_float2 p = [path evaluatePointAtIndex:segs - 1 nextIndex:segs atT:1.0f];
    if ((n == 0 || simd_distance_squared(p, pts[n - 1]) > 1e-9f) && n < maxPts)
      pts[n++] = p;
  }
  return n;
}

// Nearest distance from `q` to the projected polyline, in ASPECT-CORRECTED
// object units (X scaled by aspect so a pixel-round tolerance stays round). The
// polyline is in screen-object [0,1]; tolerance is compared in object-Y units.
static float CanvasDistToProjectedPolyline(simd_float2 q,
                                           const simd_float2 *proj, NSUInteger n,
                                           BOOL closed, float aspect) {
  simd_float2 qa = simd_make_float2(q.x * aspect, q.y);
  float best = FLT_MAX;
  NSUInteger segs = closed ? n : (n > 0 ? n - 1 : 0);
  for (NSUInteger i = 0; i < segs; i++) {
    simd_float2 a =
        simd_make_float2(proj[i].x * aspect, proj[i].y);
    simd_float2 b = simd_make_float2(proj[(i + 1) % n].x * aspect,
                                     proj[(i + 1) % n].y);
    simd_float2 ab = b - a;
    float L2 = simd_length_squared(ab);
    float t = L2 > 1e-12f
                  ? simd_clamp(simd_dot(qa - a, ab) / L2, 0.0f, 1.0f)
                  : 0.0f;
    float d2 = simd_distance_squared(qa, a + t * ab);
    if (d2 < best)
      best = d2;
  }
  return best == FLT_MAX ? FLT_MAX : sqrtf(best);
}

// YES if the query is within the (transformed) stroke of a vector layer. Tol is
// the stroke half-width in object-Y units plus a screen-slop floor so clicking
// near a thin stroke still selects it.
static const NSUInteger kHitPolyCap = 2048;
static const float kHitStrokeSlopObj = 0.012f; // ~1.2% of canvas height
static BOOL CanvasVectorLayerHit(KKBezierPath *path, double frac, float aspect,
                                 simd_float2 q, float canvasHeightPx,
                                 const CanvasGroupXform *groups, NSInteger ng) {
  simd_float2 norm[kHitPolyCap];
  NSUInteger n = CanvasFlattenPathNormalized(path, norm, kHitPolyCap);
  if (n < 2)
    return NO;
  CanvasLayerTransform t = (frac < 0.0)
                               ? CanvasLayerTransformIdentity()
                               : CanvasLayerTransformAtFraction(path, frac);
  simd_float2 c = CanvasLayerObjectCenter(path);
  simd_float2 proj[kHitPolyCap];
  for (NSUInteger i = 0; i < n; i++)
    proj[i] = CanvasProjectedCornerObj(norm[i].x, norm[i].y, t, c.x, c.y, aspect,
                                       groups, ng);
  float h = canvasHeightPx > 1.0f ? canvasHeightPx : 1000.0f;
  float tol = fmaxf(path.strokeWidth * 0.5f / h, kHitStrokeSlopObj);
  float d = CanvasDistToProjectedPolyline(q, proj, n, path.closed, aspect);
  return d <= tol;
}

NSString *CanvasHitTestLayerID(NSArray<KKBezierPath *> *layers, double frac,
                               float aspect, float objX, float objY,
                               BOOL alphaAware,
                               NSSet<NSString *> *excludedLayerIDs,
                               BOOL requireEditableAtFrac,
                               NSArray<KKLane *> *templates,
                               float canvasHeightPx) {
  simd_float2 q = simd_make_float2(objX, objY);
  for (NSInteger i = 0; i < (NSInteger)layers.count; i++) { // 0 = topmost
    KKBezierPath *path = layers[i];
    if (path.hidden || path.isGroup || path.locked)
      continue;
    if (path.layerID && [excludedLayerIDs containsObject:path.layerID])
      continue; // non-selectable (mirrors the layer list's gating)
    if (requireEditableAtFrac && frac >= 0.0 &&
        !CanvasLayerEditableAtFraction(path, frac, templates))
      continue; // viewer: nothing to edit here (animated, off-keypose)

    BOOL isImage = path.isImage && path.imagePath.length &&
                   [path.shape isKindOfClass:[KKRectShape class]];
    BOOL isVector = !path.isImage && path.strokeEnabled && path.count >= 2;
    if (!isImage && !isVector)
      continue;

    // Compose ancestor group transforms so a member moved by its group is
    // hit-tested where it's actually drawn. ng==0 for an ungrouped layer.
    CanvasGroupXform groups[kCanvasGroupXformCap];
    NSInteger ng = CanvasBuildGroupXforms(layers, (NSUInteger)i, frac, nil, nil,
                                          groups, kCanvasGroupXformCap);

    if (isVector) {
      // The stroke distance test IS the "what you see" test, so alphaAware
      // doesn't apply - a click in an open stroke's hollow interior simply
      // misses and falls through to the layer beneath.
      if (CanvasVectorLayerHit(path, frac, aspect, q, canvasHeightPx, groups, ng))
        return path.layerID;
      continue;
    }

    KKRectShape *rect = (KKRectShape *)path.shape;
    CanvasLayerTransform t = (frac < 0.0)
                                 ? CanvasLayerTransformIdentity()
                                 : CanvasLayerTransformAtFraction(path, frac);
    float cx = (rect.min.x + rect.max.x) * 0.5f;
    float cy = (rect.min.y + rect.max.y) * 0.5f;
    // Corner -> UV: tl=(0,0) tr=(1,0) br=(1,1) bl=(0,1). Object Y-up, so the
    // image TOP is at max.y (v=0) and the bottom at min.y (v=1).
    simd_float2 tl = CanvasProjectedCornerObj(rect.min.x, rect.max.y, t, cx, cy,
                                              aspect, groups, ng);
    simd_float2 tr = CanvasProjectedCornerObj(rect.max.x, rect.max.y, t, cx, cy,
                                              aspect, groups, ng);
    simd_float2 br = CanvasProjectedCornerObj(rect.max.x, rect.min.y, t, cx, cy,
                                              aspect, groups, ng);
    simd_float2 bl = CanvasProjectedCornerObj(rect.min.x, rect.min.y, t, cx, cy,
                                              aspect, groups, ng);
    simd_float2 uv;
    if (!CanvasInvBilinear(q, tl, tr, br, bl, &uv))
      continue; // outside the transformed quad
    if (alphaAware &&
        CanvasSampleImageAlpha(path.imagePath, uv.x, uv.y) <= 0.04f)
      continue; // transparent here -> fall through to the layer beneath
    return path.layerID;
  }
  return nil;
}
