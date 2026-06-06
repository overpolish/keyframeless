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

/// World matrix R = Ry * Rx * Rz (matches MagicMove.metal's order).
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

#ifdef __cplusplus
}
#endif
