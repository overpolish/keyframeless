/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#include "OSCBoxGeometry.h"
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>

// Rotation gizmo: three great circles around the pivot, one per Euler axis.
// Everything here lives in one screen frame: canvas pixels, origin at the
// gizmo centre, X right, Y up, Z toward the viewer. That frame is right
// handed, so a positive angle about an axis turns counter-clockwise when the
// axis points at the viewer, and the visible hemisphere is z >= 0.
//
// The pose matrix is the render's Rz * Ry * Rx (see MagicMove.metal and
// OSCBoxCorners), so its top-left 2x2 block is the image plane's own
// projection: the rings tilt exactly like the image they belong to.

enum { OSCRingAxisX = 0, OSCRingAxisY = 1, OSCRingAxisZ = 2, OSCRingCount = 3 };
// Part numbering continues the box's: one part per ring after the 8 handles.
enum { OSCBoxPartRingBase = OSCBoxPartHandleBase + OSCBoxHandleCount };

// Gizmo metrics in canvas pixels, and the Cmd-snap step for a ring drag.
#define OSCRingRadius 90.0
#define OSCRingHalfWidth 2.5
#define OSCRingOutlineWidth 1.0
#define OSCRingBackDim 0.3
#define OSCRingHitRadius 10.0
// Polyline resolution of the hit test. The shader uses fewer samples; both
// only need to agree to within the ring's own width.
#define OSCRingHitSamples 192
#define OSCRingSnapRadians (15.0 * M_PI / 180.0)

// Column-major: column[i] is where basis vector i lands.
typedef struct {
  double column[3][3];
} OSCRotationMatrix3;

// Euler angles in radians, applied Rz * Ry * Rx.
OSCRotationMatrix3 OSCRotationMatrixFromEuler(double rx, double ry, double rz);
// The two columns spanning ring `axis`'s plane, in draw order: the ring point
// at angle t is radius * (cos(t) * u + sin(t) * v). The axis' own column is
// the ring normal, so it drops out.
void OSCRingBasis(OSCRotationMatrix3 m, int axis, double u[3], double v[3]);

// Closest point on a ring's projected polyline to `local`, tracked twice: the
// closest sample anywhere, and the closest one on the visible hemisphere.
// Only the front match is grabbable, because the back half draws dimmed and
// reads as empty space.
typedef struct {
  double distance, angle, z;
  double frontDistance, frontAngle;
} OSCRingHit;
OSCRingHit OSCRingClosestAngle(OSCRotationMatrix3 m, int axis, double radius,
                               CGPoint local, int samples);
// Unit screen direction the grab point travels as the ring angle grows, or
// zero where an edge-on ring has no screen direction at that angle.
void OSCRingScreenTangent(OSCRotationMatrix3 m, int axis, double angle,
                          double *tangentX, double *tangentY);
// Object-axis rotation, in radians, for a screen drag of (dx, dy) away from
// the press point: the displacement projected on the press tangent, scaled by
// the ring radius. `snap` lands `pressAngle + delta` on a multiple of
// OSCRingSnapRadians, so a snapped drag reads 0, 15, 30 degrees rather than 15
// degree steps away from wherever the press happened to be. The snap applies
// to the object-axis turn, before composing; snapping the decomposed Euler
// angles instead jiggles the other two axes.
double OSCRingDragAngleDelta(int axis, double dx, double dy, double tangentX,
                             double tangentY, double radius, double pressAngle,
                             bool snap);
// One drag tick: turn the press pose about its own `axis` by `delta`, then
// decompose back to Euler angles (radians). The branch nearest `last` wins and
// the result is unwrapped to within +-pi of it, so a sweep through +-90 degrees
// stays continuous and full turns accumulate instead of wrapping. `last` is
// updated to the result, so the next tick anchors on this one.
void OSCRotationApplyRingDelta(int axis, double delta, const double press[3],
                               double last[3], double out[3]);
