/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <simd/simd.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 3x3 rotation matrix stored as 3 float3 columns (matches the shader
/// uniforms). Used by both the viewer-side `KKRotationOSC` and the
/// mini-viewer renderer so the visual + hit-test geometry stay in sync.
typedef struct {
  simd_float3 col0;
  simd_float3 col1;
  simd_float3 col2;
} KKRotMatrix3;

/// Which Euler axes a rotation control drives. The bound lane carries one
/// component per enabled axis, in X, Y, Z order (Z-only = a 1-component lane
/// holding the Z angle; the default X|Y|Z = the classic 3-component lane). A
/// disabled axis is never drawn, hit-tested, or written - so a 2D plugin can
/// reuse the gizmo (viewer `KKRotationOSC` + mini-viewer renderer) with a
/// single Z rotation. Shared here so both the viewer + mini sides agree.
typedef enum {
  KKRotationAxisX = 1 << 0,
  KKRotationAxisY = 1 << 1,
  KKRotationAxisZ = 1 << 2,
  KKRotationAxesAll = KKRotationAxisX | KKRotationAxisY | KKRotationAxisZ,
} KKRotationAxes;

/// World matrix R = Ry * Rx * Rz.
static inline KKRotMatrix3 KKBuildRotationMatrix(float rx, float ry, float rz) {
  float cx = cosf(rx), sx = sinf(rx);
  float cy = cosf(ry), sy = sinf(ry);
  float cz = cosf(rz), sz = sinf(rz);
  KKRotMatrix3 m;
  m.col0 = simd_make_float3(cy * cz + sy * sx * sz, cx * sz,
                            -sy * cz + cy * sx * sz);
  m.col1 = simd_make_float3(-cy * sz + sy * sx * cz, cx * cz,
                            sy * sz + cy * sx * cz);
  m.col2 = simd_make_float3(sy * cx, -sx, cy * cx);
  return m;
}

/// The display matrix for ring `k` (0=X, 1=Y, 2=Z). A FULL 3-axis gizmo draws
/// every ring under the whole pose (its trackball drag spins about the
/// visible axis, so pose and motion agree). A PARTIAL axis set drags as a
/// plain Euler increment (the trackball compose needs the disabled axes to
/// store its result), so each ring draws in the NESTED frame where its Euler
/// rotation actually applies - order R = Ry * Rx * Rz, so the Y ring sits
/// under Ry, the X ring under Ry * Rx, the Z ring under the full pose. A
/// ring's circle is invariant to its own rotation, so including it is safe.
static inline KKRotMatrix3 KKRingDisplayMatrix(float rx, float ry, float rz,
                                               int axesMask, int k) {
  if ((axesMask & KKRotationAxesAll) == KKRotationAxesAll || k == 2)
    return KKBuildRotationMatrix(rx, ry, rz);
  if (k == 1)
    return KKBuildRotationMatrix(0.0f, ry, 0.0f);
  return KKBuildRotationMatrix(rx, ry, 0.0f); // X ring: Ry * Rx
}

/// Fill a KKRotationOSCParams' per-ring U/V bases from three per-ring display
/// matrices (X ring spans col1/col2, Y spans col0/col2, Z spans col0/col1 -
/// the ring's own axis column is its normal and is dropped). Declared here
/// (not the shared shader-types header) so Metal never sees KKRotMatrix3; the
/// params struct type is opaque via the macro-free field writes below.
#define KKRotationOSCParamsSetRingBases(p, mx, my, mz)                         \
  do {                                                                         \
    (p)->ringUX = (mx).col1;                                                   \
    (p)->ringVX = (mx).col2;                                                   \
    (p)->ringUY = (my).col0;                                                   \
    (p)->ringVY = (my).col2;                                                   \
    (p)->ringUZ = (mz).col0;                                                   \
    (p)->ringVZ = (mz).col1;                                                   \
  } while (0)

/// Identity rotation.
static inline KKRotMatrix3 KKRotMatrixIdentity(void) {
  KKRotMatrix3 m;
  m.col0 = simd_make_float3(1, 0, 0);
  m.col1 = simd_make_float3(0, 1, 0);
  m.col2 = simd_make_float3(0, 0, 1);
  return m;
}

/// m · v (column-major).
static inline simd_float3 KKRotMatrixApply(KKRotMatrix3 m, simd_float3 v) {
  return m.col0 * v.x + m.col1 * v.y + m.col2 * v.z;
}

/// a · b (apply b then a).
static inline KKRotMatrix3 KKRotMatrixMul(KKRotMatrix3 a, KKRotMatrix3 b) {
  KKRotMatrix3 r;
  r.col0 = KKRotMatrixApply(a, b.col0);
  r.col1 = KKRotMatrixApply(a, b.col1);
  r.col2 = KKRotMatrixApply(a, b.col2);
  return r;
}

/// Plane basis (U, V) for ring `k` (0=X, 1=Y, 2=Z) under the current matrix.
static inline void KKRingBasis(KKRotMatrix3 m, int k, simd_float3 *outU,
                               simd_float3 *outV) {
  if (k == 0) {
    *outU = m.col1;
    *outV = m.col2;
  } else if (k == 1) {
    *outU = m.col0;
    *outV = m.col2;
  } else {
    *outU = m.col0;
    *outV = m.col1;
  }
}

/// Result of `KKClosestAngleOnRing`: overall (front or back) closest sample
/// + front-only closest, so callers can prefer front matches (what the
/// shader visibly renders as bright).
typedef struct {
  double overallDist;
  double overallT;
  double overallZ;
  CGPoint overallQ;
  double frontDist;
  double frontT;
  CGPoint frontQ;
} KKRingHit;

/// Find the angle t on ring k whose screen-projected polyline is closest to
/// `p` (canvas pixels, relative to center). Camera at z = -camD; "front" =
/// z <= 0. `samples` is the polyline resolution (192 is the viewer OSC
/// default; the mini-viewer may use less).
static inline KKRingHit KKClosestAngleOnRing(KKRotMatrix3 m, int k,
                                             double radius, CGPoint p,
                                             int samples) {
  simd_float3 U, V;
  KKRingBasis(m, k, &U, &V);
  KKRingHit r = {
      .overallDist = 1e9,
      .overallT = 0,
      .overallZ = 0,
      .overallQ = CGPointZero,
      .frontDist = 1e9,
      .frontT = 0,
      .frontQ = CGPointZero,
  };
  const double twoPi = 6.28318530717958647692;
  double prevX = radius * U.x;
  double prevY = radius * U.y;
  double prevZ = radius * U.z;
  for (int i = 1; i <= samples; i++) {
    double t = twoPi * ((double)i / (double)samples);
    double cx = radius * (cos(t) * U.x + sin(t) * V.x);
    double cy = radius * (cos(t) * U.y + sin(t) * V.y);
    double cz = radius * (cos(t) * U.z + sin(t) * V.z);
    double sx = cx - prevX;
    double sy = cy - prevY;
    double L2 = sx * sx + sy * sy;
    double u = 0.0;
    if (L2 > 1e-9) {
      u = ((p.x - prevX) * sx + (p.y - prevY) * sy) / L2;
      if (u < 0.0)
        u = 0.0;
      if (u > 1.0)
        u = 1.0;
    }
    double qx = prevX + u * sx;
    double qy = prevY + u * sy;
    double qz = prevZ + u * (cz - prevZ);
    double dx = p.x - qx;
    double dy = p.y - qy;
    double d = sqrt(dx * dx + dy * dy);
    double prevT = twoPi * ((double)(i - 1) / (double)samples);
    double tAt = prevT + u * (t - prevT);
    if (d < r.overallDist) {
      r.overallDist = d;
      r.overallT = tAt;
      r.overallZ = qz;
      r.overallQ = CGPointMake(qx, qy);
    }
    if (qz <= 0.0 && d < r.frontDist) {
      r.frontDist = d;
      r.frontT = tAt;
      r.frontQ = CGPointMake(qx, qy);
    }
    prevX = cx;
    prevY = cy;
    prevZ = cz;
  }
  return r;
}

/// Per-axis single rotations (double precision, used for the
/// compose-decompose drag path).
static inline simd_double3x3 KKRotXMat(double a) {
  double c = cos(a), s = sin(a);
  simd_double3x3 R;
  R.columns[0] = simd_make_double3(1, 0, 0);
  R.columns[1] = simd_make_double3(0, c, s);
  R.columns[2] = simd_make_double3(0, -s, c);
  return R;
}
static inline simd_double3x3 KKRotYMat(double a) {
  double c = cos(a), s = sin(a);
  simd_double3x3 R;
  R.columns[0] = simd_make_double3(c, 0, -s);
  R.columns[1] = simd_make_double3(0, 1, 0);
  R.columns[2] = simd_make_double3(s, 0, c);
  return R;
}
static inline simd_double3x3 KKRotZMat(double a) {
  double c = cos(a), s = sin(a);
  simd_double3x3 R;
  R.columns[0] = simd_make_double3(c, s, 0);
  R.columns[1] = simd_make_double3(-s, c, 0);
  R.columns[2] = simd_make_double3(0, 0, 1);
  return R;
}

/// Same R = Ry * Rx * Rz convention but in double precision (for the
/// compose-decompose drag math).
static inline simd_double3x3 KKBuildRotationMatrixD(double rx, double ry,
                                                    double rz) {
  double cx = cos(rx), sx = sin(rx);
  double cy = cos(ry), sy = sin(ry);
  double cz = cos(rz), sz = sin(rz);
  simd_double3x3 R;
  R.columns[0] = simd_make_double3(cy * cz + sy * sx * sz, cx * sz,
                                   -sy * cz + cy * sx * sz);
  R.columns[1] = simd_make_double3(-cy * sz + sy * sx * cz, cx * cz,
                                   sy * sz + cy * sx * cz);
  R.columns[2] = simd_make_double3(sy * cx, -sx, cy * cx);
  return R;
}

static inline double KKEulerWrap(double a) {
  while (a > M_PI)
    a -= 2.0 * M_PI;
  while (a < -M_PI)
    a += 2.0 * M_PI;
  return a;
}
static inline double KKEulerDist(double rx, double ry, double rz, double px,
                                 double py, double pz) {
  return fabs(KKEulerWrap(rx - px)) + fabs(KKEulerWrap(ry - py)) +
         fabs(KKEulerWrap(rz - pz));
}

/// Decompose R into (rx, ry, rz) under the YXZ convention used by
/// `KKBuildRotationMatrixD`, picking the branch closest to (pressRx,
/// pressRy, pressRz). Output is unwrapped to stay within ±π of press so big
/// drags accumulate instead of wrapping. Anchoring on the *previous tick's*
/// stored values (not the original press) is what keeps 0→90→180→... sweeps
/// continuous across the asin branch flip at ±90°.
static inline void KKDecomposeEulerNear(simd_double3x3 R, double pressRx,
                                        double pressRy, double pressRz,
                                        double *rx, double *ry, double *rz) {
  double r_1_2 = R.columns[2][1];
  double r_0_2 = R.columns[2][0];
  double r_2_2 = R.columns[2][2];
  double r_1_0 = R.columns[0][1];
  double r_1_1 = R.columns[1][1];
  double sx = -r_1_2;
  if (sx > 1.0)
    sx = 1.0;
  if (sx < -1.0)
    sx = -1.0;
  double primaryRx = asin(sx);
  double cx = cos(primaryRx);
  double primaryRy, primaryRz;
  if (fabs(cx) > 1e-6) {
    primaryRy = atan2(r_0_2, r_2_2);
    primaryRz = atan2(r_1_0, r_1_1);
  } else {
    primaryRz = 0.0;
    primaryRy = atan2(-R.columns[0][2], R.columns[0][0]);
  }
  double altRx = M_PI - primaryRx;
  double altRy = primaryRy + M_PI;
  double altRz = primaryRz + M_PI;
  double dPrimary =
      KKEulerDist(primaryRx, primaryRy, primaryRz, pressRx, pressRy, pressRz);
  double dAlt = KKEulerDist(altRx, altRy, altRz, pressRx, pressRy, pressRz);
  double chosenRx, chosenRy, chosenRz;
  if (dAlt < dPrimary) {
    chosenRx = altRx;
    chosenRy = altRy;
    chosenRz = altRz;
  } else {
    chosenRx = primaryRx;
    chosenRy = primaryRy;
    chosenRz = primaryRz;
  }
  *rx = pressRx + KKEulerWrap(chosenRx - pressRx);
  *ry = pressRy + KKEulerWrap(chosenRy - pressRy);
  *rz = pressRz + KKEulerWrap(chosenRz - pressRz);
}

/// One drag-tick of additive axis rotation. Builds the press matrix, post-
/// multiplies by an elemental rotation around `axis` (0=X, 1=Y, 2=Z) by
/// `dAngle` radians, decomposes near the previous tick's stored Euler so
/// the result stays continuous across the asin branch flip at ±90°, and
/// writes the new Euler back to the lastWritten anchor (so the next tick
/// decomposes near it, not the original press) AND to out*. This is the
/// shared press-matrix × axis(delta) → decompose-near → unwrap idiom every
/// plugin's rotation drag uses (viewer OSC + mini-viewer renderer).
static inline void
KKRotationComposeAxisDelta(int axis, double dAngle, double pressRx,
                           double pressRy, double pressRz, double *inOutLastRx,
                           double *inOutLastRy, double *inOutLastRz,
                           double *outRx, double *outRy, double *outRz) {
  simd_double3x3 RPress = KKBuildRotationMatrixD(pressRx, pressRy, pressRz);
  simd_double3x3 RElem = (axis == 0)   ? KKRotXMat(dAngle)
                         : (axis == 1) ? KKRotYMat(dAngle)
                                       : KKRotZMat(dAngle);
  simd_double3x3 RNew = simd_mul(RPress, RElem);
  double rx = 0, ry = 0, rz = 0;
  KKDecomposeEulerNear(RNew, *inOutLastRx, *inOutLastRy, *inOutLastRz, &rx, &ry,
                       &rz);
  *inOutLastRx = rx;
  *inOutLastRy = ry;
  *inOutLastRz = rz;
  *outRx = rx;
  *outRy = ry;
  *outRz = rz;
}

/// Cmd-snap step for ring drags, shared by the viewer + mini surfaces.
static const double KKRingDragSnapRad = 15.0 * M_PI / 180.0;

/// Unit Y-DOWN screen tangent of ring `k` at t-angle `t` in display frame `m`
/// (ring point = r(cos t·U + sin t·V) => tangent = -sin t·U + cos t·V).
/// Captured at press so the drag stays consistent even if the pose is nudged
/// mid-drag.
static inline void KKRingScreenTangentAtT(KKRotMatrix3 m, int k, double t,
                                          double *outTx, double *outTy) {
  simd_float3 U, V;
  KKRingBasis(m, k, &U, &V);
  double tx = -sin(t) * U.x + cos(t) * V.x;
  double ty = -sin(t) * U.y + cos(t) * V.y;
  double len = sqrt(tx * tx + ty * ty);
  if (len > 1e-6) {
    tx /= len;
    ty /= len;
  }
  *outTx = tx;
  *outTy = ty;
}

/// Tangent-projected ring-drag delta in radians: the screen displacement
/// (dx, dyYDown - callers flip their Y-up mouse dy) projected on the press
/// tangent, per-axis user-natural sign {+1,-1,+1}, scaled by the ring radius.
/// `snap` quantizes the OBJECT-axis delta to KKRingDragSnapRad BEFORE
/// composing - snapping decomposed Euler values instead jiggles the other two
/// axes (their decomposition shifts tick-to-tick as the object rotates).
static inline double KKRingDragAngleDelta(int axis, double dx, double dyYDown,
                                          double tanX, double tanY,
                                          double radius, BOOL snap) {
  double projected = dx * tanX + dyYDown * tanY;
  double sign = (axis == 1) ? -1.0 : 1.0;
  double dAngle = sign * projected / radius;
  if (snap)
    dAngle = round(dAngle / KKRingDragSnapRad) * KKRingDragSnapRad;
  return dAngle;
}

/// Apply a ring drag delta to the press-time Euler pose. A FULL 3-axis set
/// composes around the object's current ring axis (trackball feel, decomposed
/// nearest lastWritten for continuity past ±90°). A PARTIAL set uses a plain
/// Euler increment on the grabbed axis - the composed pose generally needs
/// the disabled axes to represent it (dropping them corrupts the pose into a
/// global-axis-like drift), so the slider semantic is exact and stable inside
/// the storable subspace.
static inline void KKRingApplyDragDelta(int axis, BOOL fullAxes, double dAngle,
                                        double pressRx, double pressRy,
                                        double pressRz, double *inOutLastRx,
                                        double *inOutLastRy,
                                        double *inOutLastRz, double *outRx,
                                        double *outRy, double *outRz) {
  if (fullAxes) {
    KKRotationComposeAxisDelta(axis, dAngle, pressRx, pressRy, pressRz,
                               inOutLastRx, inOutLastRy, inOutLastRz, outRx,
                               outRy, outRz);
    return;
  }
  *outRx = pressRx + (axis == 0 ? dAngle : 0.0);
  *outRy = pressRy + (axis == 1 ? dAngle : 0.0);
  *outRz = pressRz + (axis == 2 ? dAngle : 0.0);
  *inOutLastRx = *outRx;
  *inOutLastRy = *outRy;
  *inOutLastRz = *outRz;
}

#ifdef __cplusplus
}
#endif
