/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "OSCRotationGeometry.h"
#include <assert.h>
#include <stdio.h>

static const double kDegrees = M_PI / 180;
static OSCBoxPose Identity(void) { return (OSCBoxPose){0, 0, 100, 100, 0, 0, 0, 0, 0}; }

// R(press) turned about its own `axis`, the rotation a ring drag must produce.
static OSCRotationMatrix3 Compose(const double press[3], int axis, double delta) {
  OSCRotationMatrix3 pose = OSCRotationMatrixFromEuler(press[0], press[1], press[2]);
  double spin[3] = {0, 0, 0};
  spin[axis] = delta;
  OSCRotationMatrix3 turn = OSCRotationMatrixFromEuler(spin[0], spin[1], spin[2]);
  OSCRotationMatrix3 out;
  for (int c = 0; c < 3; ++c)
    for (int r = 0; r < 3; ++r)
      out.column[c][r] = pose.column[0][r] * turn.column[c][0] +
                         pose.column[1][r] * turn.column[c][1] +
                         pose.column[2][r] * turn.column[c][2];
  return out;
}
static bool SameRotation(OSCRotationMatrix3 m, const double euler[3]) {
  OSCRotationMatrix3 other = OSCRotationMatrixFromEuler(euler[0], euler[1], euler[2]);
  for (int c = 0; c < 3; ++c)
    for (int r = 0; r < 3; ++r)
      if (fabs(m.column[c][r] - other.column[c][r]) > 1e-9) return false;
  return true;
}

// The rings must project like the image they surround, so the matrix' screen
// block has to agree with the projection OSCBoxCorners already uses.
static void projection(void) {
  CGSize square = CGSizeMake(1000, 1000);
  const double angles[] = {-150, -90, -37, 0, 22, 90, 133};
  for (unsigned ix = 0; ix < sizeof(angles) / sizeof(*angles); ++ix)
    for (unsigned iy = 0; iy < sizeof(angles) / sizeof(*angles); ++iy)
      for (unsigned iz = 0; iz < sizeof(angles) / sizeof(*angles); ++iz) {
        OSCBoxPose pose = Identity();
        pose.rotationX = angles[ix];
        pose.rotationY = angles[iy];
        pose.rotation = angles[iz];
        CGPoint object[4];
        if (!OSCBoxCorners(pose, square, object)) continue; // edge-on: nothing to compare
        CGPoint low = OSCBoxPixelFromObject(object[1], square);  // local (500, -500)
        CGPoint high = OSCBoxPixelFromObject(object[2], square); // local (500, 500)
        OSCRotationMatrix3 m = OSCRotationMatrixFromEuler(pose.rotationX * kDegrees,
                                                          pose.rotationY * kDegrees,
                                                          pose.rotation * kDegrees);
        assert(fabs((high.x + low.x) / 1000 - m.column[0][0]) < 1e-9);
        assert(fabs((high.y + low.y) / 1000 - m.column[0][1]) < 1e-9);
        assert(fabs((high.x - low.x) / 1000 - m.column[1][0]) < 1e-9);
        assert(fabs((high.y - low.y) / 1000 - m.column[1][1]) < 1e-9);
      }
  // The gizmo sits on the render's pivot, not the image centre.
  OSCBoxPose offset = Identity();
  offset.positionX = 10;
  offset.positionY = -20;
  offset.anchorX = 30;
  offset.anchorY = 40;
  CGPoint pivot = OSCBoxPivotPixels(offset, CGSizeMake(1920, 1080));
  assert(fabs(pivot.x - 222) < 1e-9 && fabs(pivot.y + 176) < 1e-9);
}

static void columnsOrthonormal(void) {
  OSCRotationMatrix3 m = OSCRotationMatrixFromEuler(0.4, -1.2, 2.7);
  for (int a = 0; a < 3; ++a)
    for (int b = 0; b < 3; ++b) {
      double dot = 0;
      for (int i = 0; i < 3; ++i) dot += m.column[a][i] * m.column[b][i];
      assert(fabs(dot - (a == b ? 1 : 0)) < 1e-12);
    }
  // Right handed with Z toward the viewer: a positive Z turn sends X toward Y.
  OSCRotationMatrix3 spin = OSCRotationMatrixFromEuler(0, 0, M_PI / 2);
  assert(fabs(spin.column[0][1] - 1) < 1e-12 && fabs(spin.column[0][0]) < 1e-12);
}

// Every pose has two Euler branches; the decomposition must return one that
// rebuilds the same rotation, and the requested one when it is already valid.
static void roundTrip(void) {
  const double angles[] = {-179, -91, -90, -89, -45, 0, 30, 89, 90, 91, 179};
  for (unsigned ix = 0; ix < sizeof(angles) / sizeof(*angles); ++ix)
    for (unsigned iy = 0; iy < sizeof(angles) / sizeof(*angles); ++iy)
      for (unsigned iz = 0; iz < sizeof(angles) / sizeof(*angles); ++iz) {
        double press[3] = {angles[ix] * kDegrees, angles[iy] * kDegrees, angles[iz] * kDegrees};
        double last[3] = {press[0], press[1], press[2]}, out[3];
        OSCRotationApplyRingDelta(OSCRingAxisZ, 0, press, last, out);
        assert(SameRotation(Compose(press, OSCRingAxisZ, 0), out));
        // Outside gimbal lock the press values come back exactly; inside it
        // only rx -+ rz is recoverable, so the pose above is all that holds.
        if (fabs(cos(press[1])) > 1e-3)
          for (int i = 0; i < 3; ++i) assert(fabs(out[i] - press[i]) < 1e-9);
        for (int i = 0; i < 3; ++i) assert(last[i] == out[i]);
      }
}

// A sweep has to keep writing one smooth path: no branch flip, and values that
// accumulate past a full turn instead of wrapping.
static void sweepStaysContinuous(void) {
  for (int axis = 0; axis < OSCRingCount; ++axis) {
    double press[3] = {0.3, -0.2, 0.5};
    double last[3] = {press[0], press[1], press[2]}, previous[3] = {last[0], last[1], last[2]};
    for (int tick = 1; tick <= 72; ++tick) { // a full turn in 5 degree ticks
      double delta = tick * 5 * kDegrees, out[3];
      OSCRotationApplyRingDelta(axis, delta, press, last, out);
      // Picking the wrong branch shifts two axes by 180 degrees at once. The
      // Euler split itself speeds up as the pose approaches gimbal lock, where
      // a 5 degree turn can legitimately move rx and rz several times that, so
      // the bound only has to exclude a flip.
      for (int i = 0; i < 3; ++i) {
        assert(fabs(out[i] - previous[i]) < 45 * kDegrees);
        previous[i] = out[i];
        assert(last[i] == out[i]);
      }
      // Whatever the Euler values, the pose is the press turned about its own
      // ring axis by exactly the requested delta.
      assert(SameRotation(Compose(press, axis, delta), out));
    }
  }
  // From rest each ring drives its own axis alone, tick by tick, and keeps
  // counting past 360 degrees.
  double rest[3] = {0, 0, 0};
  for (int axis = 0; axis < OSCRingCount; ++axis) {
    double last[3] = {0, 0, 0};
    for (int tick = 1; tick <= 144; ++tick) {
      double delta = tick * 5 * kDegrees, out[3];
      OSCRotationApplyRingDelta(axis, delta, rest, last, out);
      for (int i = 0; i < 3; ++i) assert(fabs(out[i] - (i == axis ? delta : 0)) < 1e-9);
    }
  }
}

static void dragDelta(void) {
  double tangentX = 1, tangentY = 0;
  // The projection onto the press tangent drives the angle; the Y ring runs
  // backwards because its plane basis leaves the axis pointing away.
  double x = OSCRingDragAngleDelta(OSCRingAxisX, 45, 0, tangentX, tangentY, 90, 0, false);
  double y = OSCRingDragAngleDelta(OSCRingAxisY, 45, 0, tangentX, tangentY, 90, 0, false);
  assert(fabs(x - 0.5) < 1e-12 && fabs(y + 0.5) < 1e-12);
  // Perpendicular movement does nothing, and a zero radius cannot divide.
  assert(OSCRingDragAngleDelta(OSCRingAxisZ, 0, 45, tangentX, tangentY, 90, 0, false) == 0);
  assert(OSCRingDragAngleDelta(OSCRingAxisZ, 45, 0, tangentX, tangentY, 0, 0, false) == 0);
  // Cmd snaps the axis to whole 15 degree marks, both directions.
  double snapped = OSCRingDragAngleDelta(OSCRingAxisZ, 30, 0, tangentX, tangentY, 90, 0, true);
  assert(fabs(snapped - 15 * kDegrees) < 1e-12);
  assert(OSCRingDragAngleDelta(OSCRingAxisZ, 10, 0, tangentX, tangentY, 90, 0, true) == 0);
  assert(fabs(OSCRingDragAngleDelta(OSCRingAxisZ, -80, 0, tangentX, tangentY, 90, 0, true) +
              45 * kDegrees) < 1e-12);
  // The marks are absolute, not 15 degree steps from wherever the press was:
  // pressed at 7 degrees, a small drag lands the axis exactly on 15, and a
  // smaller one pulls it back to 0.
  double press = 7 * kDegrees, reach = 10 * kDegrees * 90;
  double toward = OSCRingDragAngleDelta(OSCRingAxisZ, reach, 0, tangentX, tangentY, 90, press, true);
  assert(fabs(press + toward - 15 * kDegrees) < 1e-12);
  double back = OSCRingDragAngleDelta(OSCRingAxisZ, -reach, 0, tangentX, tangentY, 90, press, true);
  assert(fabs(press + back) < 1e-12);
  // Past a full turn the marks keep counting: 370 degrees snaps to 375.
  double turned = 370 * kDegrees;
  double onward = OSCRingDragAngleDelta(OSCRingAxisZ, reach, 0, tangentX, tangentY, 90, turned, true);
  assert(fabs(turned + onward - 375 * kDegrees) < 1e-9);
}

static void ringHits(void) {
  OSCRotationMatrix3 flat = OSCRotationMatrixFromEuler(0, 0, 0);
  OSCRingHit hit = OSCRingClosestAngle(flat, OSCRingAxisZ, 90, CGPointMake(88, 0), OSCRingHitSamples);
  // An unrotated Z ring lies in the screen plane, so all of it is grabbable.
  assert(fabs(hit.frontDistance - 2) < 0.05 && fabs(hit.frontAngle) < 0.05);
  assert(hit.distance == hit.frontDistance);
  hit = OSCRingClosestAngle(flat, OSCRingAxisZ, 90, CGPointMake(0, 0), OSCRingHitSamples);
  assert(fabs(hit.frontDistance - 90) < 0.1);
  // Tilting the Z ring 60 degrees about X leaves its lower half behind the
  // pivot: a point right on that back arc must not be grabbable, even though
  // it is the closest part of the polyline.
  OSCRotationMatrix3 tilted = OSCRotationMatrixFromEuler(60 * kDegrees, 0, 0);
  hit = OSCRingClosestAngle(tilted, OSCRingAxisZ, 90, CGPointMake(0, -45), OSCRingHitSamples);
  assert(hit.distance < 0.2 && hit.z < 0);
  assert(hit.frontDistance > OSCRingHitRadius);
  // The front match is the visible top of the same ellipse.
  assert(fabs(hit.frontDistance - 90) < 1);
  // Degenerate requests report no match at all.
  hit = OSCRingClosestAngle(flat, OSCRingAxisX, 0, CGPointZero, OSCRingHitSamples);
  assert(hit.distance == INFINITY && hit.frontDistance == INFINITY);
}

static void tangents(void) {
  const double poses[][3] = {{0, 0, 0}, {0.6, -0.4, 1.1}, {M_PI / 2, 0, 0}, {0, M_PI / 2, 0}};
  for (unsigned p = 0; p < sizeof(poses) / sizeof(*poses); ++p)
    for (int axis = 0; axis < OSCRingCount; ++axis) {
      OSCRotationMatrix3 m = OSCRotationMatrixFromEuler(poses[p][0], poses[p][1], poses[p][2]);
      for (int step = 0; step < 8; ++step) {
        double tx, ty;
        OSCRingScreenTangent(m, axis, step * M_PI / 4, &tx, &ty);
        double length = hypot(tx, ty);
        // Edge-on rings project to a segment, where two angles have no screen
        // tangent at all; everywhere else the tangent is a unit direction.
        assert(fabs(length - 1) < 1e-9 || length == 0);
      }
    }
  // The tangent is the direction the grab point moves as the angle grows: on a
  // flat Z ring, the right-hand point travels up.
  double tx, ty;
  OSCRingScreenTangent(OSCRotationMatrixFromEuler(0, 0, 0), OSCRingAxisZ, 0, &tx, &ty);
  assert(fabs(tx) < 1e-12 && fabs(ty - 1) < 1e-12);
}

int main(void) {
  projection();
  columnsOrthonormal();
  roundTrip();
  sweepStaysContinuous();
  dragDelta();
  ringHits();
  tangents();
  puts("Rotation geometry: render projection, orthonormal pose, branch round trip, continuous "
       "sweeps, drag deltas with snap, front-only ring hits and unit tangents passed");
  return 0;
}
