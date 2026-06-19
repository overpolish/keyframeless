/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerTransform.h"
#import "CanvasLayerRender.h" // CanvasGroupContentCenterObj (public decl)
#import "CanvasLayerTree.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKShape.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimingStage.h>

#pragma mark - Matrix primitives (column-major simd_matrix)

static matrix_float4x4 CanvasTranslate4(float x, float y) {
  return simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0),
                     simd_make_float4(0, 0, 1, 0),
                     simd_make_float4(x, y, 0, 1));
}

static matrix_float4x4 CanvasScale4(float sx, float sy, float sz) {
  return simd_matrix(
      simd_make_float4(sx, 0, 0, 0), simd_make_float4(0, sy, 0, 0),
      simd_make_float4(0, 0, sz, 0), simd_make_float4(0, 0, 0, 1));
}

// In-plane (Z) rotation, CCW. Pixel space already carries the aspect, so no
// fudge.
static matrix_float4x4 CanvasRotZ4(float a) {
  float c = cosf(a), s = sinf(a);
  return simd_matrix(
      simd_make_float4(c, s, 0, 0), simd_make_float4(-s, c, 0, 0),
      simd_make_float4(0, 0, 1, 0), simd_make_float4(0, 0, 0, 1));
}

// Tilt about the screen X axis (positive tips the top toward the viewer).
static matrix_float4x4 CanvasRotX4(float a) {
  float c = cosf(a), s = sinf(a);
  return simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, c, s, 0),
                     simd_make_float4(0, -s, c, 0),
                     simd_make_float4(0, 0, 0, 1));
}

// Tilt about the screen Y axis (positive tips the right edge away).
static matrix_float4x4 CanvasRotY4(float a) {
  float c = cosf(a), s = sinf(a);
  return simd_matrix(simd_make_float4(c, 0, -s, 0),
                     simd_make_float4(0, 1, 0, 0), simd_make_float4(s, 0, c, 0),
                     simd_make_float4(0, 0, 0, 1));
}

// Camera at distance camD on +Z: (x,y,z,1) -> (camD x, camD y, z, z + camD);
// after the perspective divide, foreshortening scales by camD/(z + camD).
static matrix_float4x4 CanvasPerspective4(float camD) {
  return simd_matrix(
      simd_make_float4(camD, 0, 0, 0), simd_make_float4(0, camD, 0, 0),
      simd_make_float4(0, 0, 1, 1), simd_make_float4(0, 0, 0, camD));
}

#pragma mark - Layer transform evaluation

CanvasLayerTransform CanvasLayerTransformIdentity(void) {
  return (CanvasLayerTransform){1.0f, 1.0f, 0.0f, 0.5f, 0.5f,
                                0.0f, 0.0f, 1.0f, 0.5f, 0.5f};
}

CanvasLayerTransform CanvasLayerTransformFromTimeline(KKTimeline *tl,
                                                      double frac) {
  CanvasLayerTransform t = CanvasLayerTransformIdentity();
  for (KKLane *lane in tl.lanes) {
    if ([lane.label isEqualToString:@"Scale"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      // Overshoot/elastic easing can dip scale below 0; clamp rather than flip.
      if (v.count > 0)
        t.scaleX = (float)(fmax(0.0, v[0].doubleValue) / 100.0);
      if (v.count > 1)
        t.scaleY = (float)(fmax(0.0, v[1].doubleValue) / 100.0);
    } else if ([lane.label isEqualToString:@"Position"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        t.posX = (float)v[0].doubleValue;
      if (v.count > 1)
        t.posY = (float)v[1].doubleValue;
    } else if ([lane.label isEqualToString:@"Rotation"]) {
      // 3-axis Euler [X,Y,Z]°.
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      const double kDegToRad = M_PI / 180.0;
      if (v.count > 0)
        t.rotX = (float)(v[0].doubleValue * kDegToRad);
      if (v.count > 1)
        t.rotY = (float)(v[1].doubleValue * kDegToRad);
      if (v.count > 2)
        t.rotation = (float)(v[2].doubleValue * kDegToRad);
    } else if ([lane.label isEqualToString:@"Opacity"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        t.opacity = (float)(fmax(0.0, fmin(100.0, v[0].doubleValue)) / 100.0);
    } else if ([lane.label isEqualToString:@"Anchor"]) {
      // Pivot for Rotation/Scale, normalised (0.5,0.5 = layer centre). Empty
      // lane on a cold-boot snapshot evaluates to [0,0]; keep the centre
      // default.
      if (lane.keyposes.count > 0) {
        NSArray<NSNumber *> *v =
            KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
        if (v.count > 0)
          t.anchorX = (float)v[0].doubleValue;
        if (v.count > 1)
          t.anchorY = (float)v[1].doubleValue;
      }
    }
  }
  return t;
}

CanvasLayerTransform CanvasLayerTransformAtFraction(KKBezierPath *path,
                                                    double frac) {
  if (path.animationJSON.length == 0)
    return CanvasLayerTransformIdentity();
  return CanvasLayerTransformFromTimeline(
      [KKTimeline timelineFromJSON:path.animationJSON], frac);
}

// A group's own transform at `frac`. A group is a layer like any other (its own
// Scale/Position/Rotation/Opacity animationJSON), so this reuses the per-layer
// reader, with the same live-edit override hook.
static CanvasLayerTransform
CanvasGroupTransformAtFraction(KKBezierPath *group, double frac,
                               NSString *overrideLayerID,
                               KKTimeline *overrideTimeline) {
  if (frac < 0.0)
    return CanvasLayerTransformIdentity();
  if (overrideTimeline && overrideLayerID.length &&
      [group.layerID isEqualToString:overrideLayerID])
    return CanvasLayerTransformFromTimeline(overrideTimeline, frac);
  return CanvasLayerTransformAtFraction(group, frac);
}

#pragma mark - Group content bounds / centre

// Bounds of where the image layers nested under the group at `groupIdx`
// actually SIT, in object space (Y-up) - the bbox of each member's TRANSFORMED
// centre (rect centre + its Position offset), not the raw shape rect. Images
// are created centred at (0.5,0.5) and moved by their Position transform, so
// the rest rect alone collapses every layer to the clip centre; the group must
// pivot about its content's real location. Evaluated at frac 0 (the members'
// base pose) so the pivot is STABLE as it (and its members) animate. NO when
// the group has no rect-shaped image descendants. Scale/rotation about a
// layer's OWN centre don't move that centre, so only the Position offset
// matters here.
static BOOL CanvasGroupContentBoundsObj(NSArray<KKBezierPath *> *layers,
                                        NSUInteger groupIdx,
                                        simd_float2 *outMin,
                                        simd_float2 *outMax) {
  NSIndexSet *desc = CanvasLayerDescendantIndices(groupIdx, layers);
  __block BOOL found = NO;
  __block float minX = 0, minY = 0, maxX = 0, maxY = 0;
  [desc enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    KKBezierPath *p = layers[i];
    if (p.isGroup || ![p.shape isKindOfClass:[KKRectShape class]])
      return;
    KKRectShape *r = (KKRectShape *)p.shape;
    float rcx = (r.min.x + r.max.x) * 0.5f, rcy = (r.min.y + r.max.y) * 0.5f;
    CanvasLayerTransform t = CanvasLayerTransformAtFraction(p, 0.0);
    // Member's transformed centre (Y flips like the render: lane Y is Y-down).
    float mx = rcx + (t.posX - 0.5f), my = rcy - (t.posY - 0.5f);
    if (!found) {
      minX = maxX = mx;
      minY = maxY = my;
      found = YES;
    } else {
      minX = fminf(minX, mx);
      minY = fminf(minY, my);
      maxX = fmaxf(maxX, mx);
      maxY = fmaxf(maxY, my);
    }
  }];
  if (found) {
    *outMin = simd_make_float2(minX, minY);
    *outMax = simd_make_float2(maxX, maxY);
  }
  return found;
}

BOOL CanvasGroupContentCenterObj(NSArray<KKBezierPath *> *layers,
                                 KKBezierPath *group, float *outCx,
                                 float *outCy) {
  if (!group.isGroup)
    return NO;
  NSUInteger idx = [layers indexOfObjectIdenticalTo:group];
  if (idx == NSNotFound)
    for (NSUInteger i = 0; i < layers.count; i++)
      if (layers[i].layerID.length &&
          [layers[i].layerID isEqualToString:group.layerID]) {
        idx = i;
        break;
      }
  simd_float2 mn, mx;
  if (idx == NSNotFound || !CanvasGroupContentBoundsObj(layers, idx, &mn, &mx))
    return NO;
  if (outCx)
    *outCx = (mn.x + mx.x) * 0.5f;
  if (outCy)
    *outCy = (mn.y + mx.y) * 0.5f;
  return YES;
}

BOOL CanvasGroupPositionOffset(NSArray<KKBezierPath *> *layers,
                               KKBezierPath *group, double *outDX,
                               double *outDY) {
  float cx = 0.5f, cy = 0.5f;
  if (!group.isGroup || !CanvasGroupContentCenterObj(layers, group, &cx, &cy))
    return NO;
  if (outDX)
    *outDX = cx - 0.5; // X agrees; Y flips (Position is Y-down)
  if (outDY)
    *outDY = 0.5 - cy;
  return YES;
}

NSInteger CanvasBuildGroupXforms(NSArray<KKBezierPath *> *layers,
                                 NSUInteger idx, double frac,
                                 NSString *overrideLayerID,
                                 KKTimeline *overrideTimeline,
                                 CanvasGroupXform *out, NSInteger maxN) {
  // A group sits before its members in the flat stack, so a nested group has a
  // higher index than its parent - reverse index order gives innermost-first,
  // matching the parentGroupID chain (the index set loses the order). Composing
  // innermost-first means each outer group transforms the already-placed
  // result.
  NSIndexSet *anc = CanvasLayerAncestorIndices(idx, layers);
  __block NSInteger n = 0;
  [anc enumerateIndexesWithOptions:NSEnumerationReverse
                        usingBlock:^(NSUInteger gi, BOOL *stop) {
                          if (n >= maxN) {
                            *stop = YES;
                            return;
                          }
                          simd_float2 gmin, gmax;
                          float gcx = 0.5f, gcy = 0.5f;
                          if (CanvasGroupContentBoundsObj(layers, gi, &gmin,
                                                          &gmax)) {
                            gcx = (gmin.x + gmax.x) * 0.5f;
                            gcy = (gmin.y + gmax.y) * 0.5f;
                          }
                          out[n].t = CanvasGroupTransformAtFraction(
                              layers[gi], frac, overrideLayerID,
                              overrideTimeline);
                          out[n].cx = gcx;
                          out[n].cy = gcy;
                          n++;
                        }];
  return n;
}

#pragma mark - Model matrices

matrix_float4x4 CanvasLayerTiltMatrix(CanvasLayerTransform t,
                                      simd_float2 centerPx, float W, float H,
                                      simd_float2 tileShift) {
  matrix_float4x4 P = CanvasPerspective4(fmaxf(W, H));
  matrix_float4x4 Tshift = CanvasTranslate4(tileShift.x, tileShift.y);
  if (t.rotX == 0.0f && t.rotY == 0.0f)
    return simd_mul(Tshift, P); // no tilt: perspective (ortho at z=0) + shift
  // Tpos · P · Ry · Rx · Tneg: centre the layer at the origin, tilt, project
  // (perspective about the layer centre), translate back as a post-divide
  // screen offset; Tshift then nudges into the render tile.
  matrix_float4x4 R = simd_mul(CanvasRotY4(t.rotY), CanvasRotX4(t.rotX));
  matrix_float4x4 model = simd_mul(
      CanvasTranslate4(centerPx.x, centerPx.y),
      simd_mul(P, simd_mul(R, CanvasTranslate4(-centerPx.x, -centerPx.y))));
  return simd_mul(Tshift, model);
}

// A layer's full 3D model matrix in pixel space: T(centerPx+posPx) · Ry·Rx·Rz ·
// S · T(-centerPx). One matrix for ALL of the layer's rotation axes so X/Y/Z
// compose as a single rigid rotation about the layer's centre (Z is NOT split
// into a separate 2D bake - that split made combining Z with X/Y, or with a
// group's rotation, interleave wrong). Rotation about the rest centre then
// translate by Position == rotation about the POSITIONED centre (where the OSC
// rings sit). Z is scaled by the X/Y average so scaling TILTED geometry (a
// group shrinking its members, which carry a Z-extent) shrinks uniformly
// instead of flattening to a sliver; a no-op for flat (Z=0) geometry.
// `anchorPx` shifts the Rotation/Scale pivot off the layer centre (0 = centre).
// R/S swing around piv = centerPx + anchorPx instead, so a corner/edge anchor
// makes the layer spin/grow from there. With identity R/S it cancels out (the
// layer still sits at posPx), so the anchor does nothing visible on its own.
static matrix_float4x4 CanvasLayerModelMatrix(CanvasLayerTransform t,
                                              simd_float2 centerPx,
                                              simd_float2 posPx,
                                              simd_float2 anchorPx) {
  float scaleZ = sqrtf(fmaxf(0.0f, t.scaleX * t.scaleY));
  matrix_float4x4 S = CanvasScale4(t.scaleX, t.scaleY, scaleZ);
  matrix_float4x4 R = simd_mul(
      CanvasRotY4(t.rotY),
      simd_mul(CanvasRotX4(t.rotX), CanvasRotZ4(t.rotation))); // Ry·Rx·Rz
  simd_float2 piv = centerPx + anchorPx;
  matrix_float4x4 Tneg = CanvasTranslate4(-piv.x, -piv.y);
  matrix_float4x4 Tpos = CanvasTranslate4(piv.x + posPx.x, piv.y + posPx.y);
  return simd_mul(Tpos, simd_mul(R, simd_mul(S, Tneg)));
}

// The Anchor pivot offset in pixel space (Y flips: lane Y is Y-down, pixel
// Y-up), as a fraction of `dims`. 0 when the anchor is centred (0.5,0.5).
static simd_float2 CanvasAnchorOffsetPx(CanvasLayerTransform t,
                                        simd_float2 dims) {
  return simd_make_float2(t.anchorX - 0.5f, -(t.anchorY - 0.5f)) * dims;
}

// The Position offset in pixel space (Y flips: lane Y is Y-down, pixel Y-up).
static simd_float2 CanvasPosOffsetPx(CanvasLayerTransform t, simd_float2 dims) {
  return simd_make_float2(t.posX - 0.5f, -(t.posY - 0.5f)) * dims;
}

matrix_float4x4 CanvasComposedModelMatrix(CanvasLayerTransform memberT,
                                          simd_float2 memberCenterObj,
                                          const CanvasGroupXform *groups,
                                          NSInteger ng, simd_float2 dims,
                                          simd_float2 tileShift) {
  simd_float2 half = simd_make_float2(0.5f, 0.5f);
  simd_float2 mcPx = (memberCenterObj - half) * dims;
  simd_float2 mPosPx = CanvasPosOffsetPx(memberT, dims);
  matrix_float4x4 model = CanvasLayerModelMatrix(
      memberT, mcPx, mPosPx, CanvasAnchorOffsetPx(memberT, dims));
  simd_float2 pcPx = mcPx + mPosPx; // perspective centre = outermost element
  // Total scale applied to the geometry (member * each group, X/Y average). The
  // camera distance scales by this so the perspective is SCALE-INVARIANT: a
  // tilted layer scaled up grows uniformly instead of foreshortening harder and
  // "peeking over its edge" (z-extent and camera distance grow together).
  float camScale = sqrtf(fmaxf(0.0f, memberT.scaleX * memberT.scaleY));
  for (NSInteger k = 0; k < ng; k++) {
    simd_float2 gcPx =
        (simd_make_float2(groups[k].cx, groups[k].cy) - half) * dims;
    simd_float2 gPosPx = CanvasPosOffsetPx(groups[k].t, dims);
    model = simd_mul(
        CanvasLayerModelMatrix(groups[k].t, gcPx, gPosPx,
                               CanvasAnchorOffsetPx(groups[k].t, dims)),
        model);
    pcPx = gcPx + gPosPx; // outermost group wins
    camScale *= sqrtf(fmaxf(0.0f, groups[k].t.scaleX * groups[k].t.scaleY));
  }
  matrix_float4x4 P =
      CanvasPerspective4(fmaxf(dims.x, dims.y) * fmaxf(camScale, 1e-3f));
  matrix_float4x4 Tshift = CanvasTranslate4(tileShift.x, tileShift.y);
  // Tshift · Tpos(pc) · P · Tneg(pc) · model
  matrix_float4x4 persp =
      simd_mul(CanvasTranslate4(pcPx.x, pcPx.y),
               simd_mul(P, CanvasTranslate4(-pcPx.x, -pcPx.y)));
  return simd_mul(Tshift, simd_mul(persp, model));
}
