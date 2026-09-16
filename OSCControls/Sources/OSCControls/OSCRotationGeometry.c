/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "OSCRotationGeometry.h"

OSCRotationMatrix3 OSCRotationMatrixFromEuler(double rx, double ry, double rz) {
  double cx = cos(rx), sx = sin(rx), cy = cos(ry), sy = sin(ry), cz = cos(rz), sz = sin(rz);
  OSCRotationMatrix3 m;
  m.column[0][0] = cz * cy;
  m.column[0][1] = sz * cy;
  m.column[0][2] = -sy;
  m.column[1][0] = cz * sy * sx - sz * cx;
  m.column[1][1] = sz * sy * sx + cz * cx;
  m.column[1][2] = cy * sx;
  m.column[2][0] = cz * sy * cx + sz * sx;
  m.column[2][1] = sz * sy * cx - cz * sx;
  m.column[2][2] = cy * cx;
  return m;
}

void OSCRingBasis(OSCRotationMatrix3 m, int axis, double u[3], double v[3]) {
  // Drop the ring's own axis: X spans Y/Z, Y spans X/Z, Z spans X/Y.
  int uIndex = axis == OSCRingAxisX ? 1 : 0, vIndex = axis == OSCRingAxisZ ? 1 : 2;
  for (int i = 0; i < 3; ++i) { u[i] = m.column[uIndex][i]; v[i] = m.column[vIndex][i]; }
}

OSCRingHit OSCRingClosestAngle(OSCRotationMatrix3 m, int axis, double radius,
                               CGPoint local, int samples) {
  OSCRingHit hit = {INFINITY, 0, 0, INFINITY, 0};
  double u[3], v[3];
  OSCRingBasis(m, axis, u, v);
  if (samples < 3 || radius <= 0) return hit;
  const double twoPi = 2 * M_PI;
  double previous[3] = {radius * u[0], radius * u[1], radius * u[2]};
  for (int i = 1; i <= samples; ++i) {
    double t = twoPi * i / samples, c = cos(t), s = sin(t);
    double current[3] = {radius * (c * u[0] + s * v[0]), radius * (c * u[1] + s * v[1]),
                         radius * (c * u[2] + s * v[2])};
    // Closest point on this segment's screen projection, with the depth
    // interpolated the same way so the front/back split follows the polyline.
    double ex = current[0] - previous[0], ey = current[1] - previous[1];
    double lengthSquared = ex * ex + ey * ey, along = 0;
    if (lengthSquared > 1e-12) {
      along = ((local.x - previous[0]) * ex + (local.y - previous[1]) * ey) / lengthSquared;
      along = fmax(0, fmin(1, along));
    }
    double dx = local.x - (previous[0] + along * ex), dy = local.y - (previous[1] + along * ey);
    double distance = hypot(dx, dy), z = previous[2] + along * (current[2] - previous[2]);
    double previousT = twoPi * (i - 1) / samples, angle = previousT + along * (t - previousT);
    if (distance < hit.distance) { hit.distance = distance; hit.angle = angle; hit.z = z; }
    if (z >= 0 && distance < hit.frontDistance) { hit.frontDistance = distance; hit.frontAngle = angle; }
    for (int k = 0; k < 3; ++k) previous[k] = current[k];
  }
  return hit;
}

void OSCRingScreenTangent(OSCRotationMatrix3 m, int axis, double angle,
                          double *tangentX, double *tangentY) {
  double u[3], v[3];
  OSCRingBasis(m, axis, u, v);
  // d/dt of radius * (cos t * u + sin t * v), radius cancels once normalised.
  double tx = -sin(angle) * u[0] + cos(angle) * v[0];
  double ty = -sin(angle) * u[1] + cos(angle) * v[1];
  double length = hypot(tx, ty);
  // An edge-on ring projects to a segment: at its two turning points there is
  // no screen direction at all, reported as a zero tangent.
  *tangentX = length > 1e-9 ? tx / length : 0;
  *tangentY = length > 1e-9 ? ty / length : 0;
}

double OSCRingDragAngleDelta(int axis, double dx, double dy, double tangentX,
                             double tangentY, double radius, double pressAngle,
                             bool snap) {
  if (!(radius > 0)) return 0;
  // A post-multiplied rotation moves the grabbed point to the ring angle
  // t + delta, except on the Y ring: its basis (column 0, column 2) has the
  // ring normal as -Y, so the same turn runs the angle backwards there.
  double sign = axis == OSCRingAxisY ? -1 : 1;
  double delta = sign * (dx * tangentX + dy * tangentY) / radius;
  if (!snap) return delta;
  double snapped = round((pressAngle + delta) / OSCRingSnapRadians) * OSCRingSnapRadians;
  return snapped - pressAngle;
}

static OSCRotationMatrix3 OSCRotationAxisMatrix(int axis, double angle) {
  double c = cos(angle), s = sin(angle);
  OSCRotationMatrix3 m = {{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}};
  int a = (axis + 1) % 3, b = (axis + 2) % 3;
  m.column[a][a] = c;
  m.column[a][b] = s;
  m.column[b][a] = -s;
  m.column[b][b] = c;
  return m;
}

static OSCRotationMatrix3 OSCRotationMultiply(OSCRotationMatrix3 a, OSCRotationMatrix3 b) {
  OSCRotationMatrix3 m;
  for (int c = 0; c < 3; ++c)
    for (int r = 0; r < 3; ++r)
      m.column[c][r] = a.column[0][r] * b.column[c][0] + a.column[1][r] * b.column[c][1] +
                       a.column[2][r] * b.column[c][2];
  return m;
}

static double OSCEulerWrap(double angle) { return remainder(angle, 2 * M_PI); }
static double OSCEulerDistance(const double a[3], const double b[3]) {
  return fabs(OSCEulerWrap(a[0] - b[0])) + fabs(OSCEulerWrap(a[1] - b[1])) +
         fabs(OSCEulerWrap(a[2] - b[2]));
}

// Euler angles for `m` under Rz * Ry * Rx. Two branches represent every pose,
// so take the one nearest `anchor`: that is what keeps a sweep continuous
// where the asin for Y folds back at +-90 degrees.
static void OSCDecomposeEulerNear(OSCRotationMatrix3 m, const double anchor[3], double out[3]) {
  double sy = fmax(-1, fmin(1, -m.column[0][2]));
  double primary[3], ry = asin(sy);
  if (fabs(cos(ry)) > 1e-6) {
    primary[0] = atan2(m.column[1][2], m.column[2][2]);
    primary[2] = atan2(m.column[0][1], m.column[0][0]);
  } else {
    // Gimbal lock: only rx -+ rz is determined, so pin rz and keep the sum.
    primary[0] = atan2(-m.column[2][1], m.column[1][1]);
    primary[2] = 0;
  }
  primary[1] = ry;
  double alternate[3] = {primary[0] + M_PI, M_PI - primary[1], primary[2] + M_PI};
  const double *chosen = OSCEulerDistance(alternate, anchor) < OSCEulerDistance(primary, anchor)
                             ? alternate : primary;
  for (int i = 0; i < 3; ++i) out[i] = anchor[i] + OSCEulerWrap(chosen[i] - anchor[i]);
}

void OSCRotationApplyRingDelta(int axis, double delta, const double press[3],
                               double last[3], double out[3]) {
  OSCRotationMatrix3 composed =
      OSCRotationMultiply(OSCRotationMatrixFromEuler(press[0], press[1], press[2]),
                          OSCRotationAxisMatrix(axis, delta));
  OSCDecomposeEulerNear(composed, last, out);
  for (int i = 0; i < 3; ++i) last[i] = out[i];
}
