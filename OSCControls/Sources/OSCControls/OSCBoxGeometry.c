/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "OSCBoxGeometry.h"
#include <math.h>

CGPoint OSCBoxPixelFromObject(CGPoint object, CGSize imageSize) {
  return CGPointMake((object.x - 0.5) * imageSize.width, (object.y - 0.5) * imageSize.height);
}
CGPoint OSCBoxObjectFromPixel(CGPoint pixel, CGSize imageSize) {
  return CGPointMake(0.5 + pixel.x / imageSize.width, 0.5 + pixel.y / imageSize.height);
}

static CGPoint OSCBoxOffsetPixels(OSCBoxPose pose, CGSize imageSize) {
  return CGPointMake(pose.positionX / 100 * imageSize.width, pose.positionY / 100 * imageSize.height);
}
CGPoint OSCBoxPivotPixels(OSCBoxPose pose, CGSize imageSize) {
  CGPoint offset = OSCBoxOffsetPixels(pose, imageSize);
  return CGPointMake(offset.x + pose.anchorX, offset.y + pose.anchorY);
}
// Rotation-only orthographic projection of the image plane (Rz·Ry·Rx, no
// scale), matching the render shader so the OSC stays glued to the image at any
// X/Y/Z rotation. Row-major 2x2 {m0 m1 / m2 m3}. `det` receives the planar
// determinant (== cos(x)·cos(y)); zero means the plane is edge-on.
static void OSCBoxRotationMatrix(OSCBoxPose pose, double m[4], double *det) {
  double ax = pose.rotationX * M_PI / 180, ay = pose.rotationY * M_PI / 180, az = pose.rotation * M_PI / 180;
  double cx = cos(ax), sx = sin(ax), cy = cos(ay), sy = sin(ay), cz = cos(az), sz = sin(az);
  m[0] = cz * cy;                 // p
  m[1] = cz * sy * sx - sz * cx;  // q
  m[2] = sz * cy;                 // r
  m[3] = sz * sy * sx + cz * cx;  // s
  *det = m[0] * m[3] - m[1] * m[2];
}
// Unscaled handle position relative to the image centre.
static CGPoint OSCBoxHandleLocal(long index, CGSize imageSize) {
  double w = imageSize.width / 2, h = imageSize.height / 2;
  switch (index) {
  case 0: return CGPointMake(-w, -h);
  case 1: return CGPointMake(w, -h);
  case 2: return CGPointMake(w, h);
  case 3: return CGPointMake(-w, h);
  case 4: return CGPointMake(0, -h);
  case 5: return CGPointMake(w, 0);
  case 6: return CGPointMake(0, h);
  case 7: return CGPointMake(-w, 0);
  default: return CGPointZero;
  }
}

bool OSCBoxCorners(OSCBoxPose pose, CGSize imageSize, CGPoint corners[4]) {
  CGPoint anchor = CGPointMake(pose.anchorX, pose.anchorY);
  CGPoint offset = OSCBoxOffsetPixels(pose, imageSize);
  double r[4], det;
  OSCBoxRotationMatrix(pose, r, &det);
  // Fold scale into the projection; the render's pixel aspect cancels out, so
  // this maps anchor-relative image pixels directly.
  double scX = pose.scaleX / 100, scY = pose.scaleY / 100;
  double a = r[0] * scX, b = r[1] * scY, c = r[2] * scX, d = r[3] * scY;
  // Edge-on, or zero scale: the render draws nothing, so no handle is reachable.
  if (fabs(det) < 1e-6 || fabs(a * d - b * c) < 1e-12) return false;
  for (long i = 0; i < 4; ++i) {
    CGPoint l = OSCBoxHandleLocal(i, imageSize);
    double lx = l.x - anchor.x, ly = l.y - anchor.y;
    CGPoint q = CGPointMake(a * lx + b * ly, c * lx + d * ly);
    corners[i] = OSCBoxObjectFromPixel(CGPointMake(q.x + anchor.x + offset.x, q.y + anchor.y + offset.y), imageSize);
  }
  return true;
}

CGPoint OSCBoxHandlePoint(const CGPoint corners[4], long index) {
  if (index >= 0 && index < 4) return corners[index];
  if (index < 4 || index >= OSCBoxHandleCount) return CGPointZero;
  CGPoint a = corners[index - 4], b = corners[(index - 3) % 4];
  return CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2);
}

CGPoint OSCBoxHandleAxis(const CGPoint corners[4], long index) {
  if (index < 4 || index >= OSCBoxHandleCount) return CGPointZero;
  CGPoint a = corners[index - 4], b = corners[(index - 3) % 4];
  double length = hypot(b.x - a.x, b.y - a.y);
  return length > 0 ? CGPointMake((b.x - a.x) / length, (b.y - a.y) / length) : CGPointZero;
}

long OSCBoxHitTest(const CGPoint corners[4], CGPoint point, double radius,
                   bool handlesEnabled) {
  long best = -1;
  double bestDistance = INFINITY;
  for (long i = 0; handlesEnabled && i < OSCBoxHandleCount; ++i) {
    CGPoint centre = OSCBoxHandlePoint(corners, i), axis = OSCBoxHandleAxis(corners, i);
    double dx = point.x - centre.x, dy = point.y - centre.y;
    double along = fmax(-OSCBoxPillHalfLength, fmin(OSCBoxPillHalfLength, dx * axis.x + dy * axis.y));
    double d = hypot(dx - along * axis.x, dy - along * axis.y);
    if (d <= radius && d < bestDistance) { bestDistance = d; best = i; }
  }
  return best >= 0 ? OSCBoxPartHandleBase + best : OSCBoxPartPosition;
}

OSCBoxPose OSCBoxPoseMovedBy(OSCBoxPose press, CGPoint deltaPixels, CGSize imageSize) {
  OSCBoxPose pose = press;
  if (imageSize.width > 0) pose.positionX = press.positionX + deltaPixels.x / imageSize.width * 100;
  if (imageSize.height > 0) pose.positionY = press.positionY + deltaPixels.y / imageSize.height * 100;
  return pose;
}

static double OSCBoxClampScale(double value) {
  if (!isfinite(value)) return 0;
  return fmax(0, fmin(OSCBoxMaxScale, value));
}

OSCBoxPose OSCBoxPoseScaledByHandle(OSCBoxPose press, long handle, CGPoint pressPixels,
                                  CGPoint currentPixels, CGSize imageSize, bool proportional) {
  OSCBoxPose pose = press;
  if (handle < 0 || handle >= OSCBoxHandleCount) return pose;
  // Work in the unrotated frame about the anchor, where the box is axis-aligned.
  CGPoint anchor = CGPointMake(press.anchorX, press.anchorY);
  CGPoint offset = OSCBoxOffsetPixels(press, imageSize);
  // Un-project the press/current points through the rotation-only inverse, so a
  // drag tracks the image's own (foreshortened) axes rather than the screen's.
  double r[4], det;
  OSCBoxRotationMatrix(press, r, &det);
  if (fabs(det) < 1e-6) return press; // edge-on: unreachable behind a hit handle
  double i00 = r[3] / det, i01 = -r[1] / det, i10 = -r[2] / det, i11 = r[0] / det;
  double px = pressPixels.x - offset.x - anchor.x, py = pressPixels.y - offset.y - anchor.y;
  double cxx = currentPixels.x - offset.x - anchor.x, cyy = currentPixels.y - offset.y - anchor.y;
  CGPoint pressLocal = CGPointMake(i00 * px + i01 * py, i10 * px + i11 * py);
  CGPoint currentLocal = CGPointMake(i00 * cxx + i01 * cyy, i10 * cxx + i11 * cyy);
  CGPoint base = OSCBoxHandleLocal(handle, imageSize);
  base = CGPointMake(base.x - anchor.x, base.y - anchor.y);
  CGPoint handleAtPress = CGPointMake(base.x * press.scaleX / 100, base.y * press.scaleY / 100);
  // Keep the grab offset so the handle never jumps under the pointer.
  CGPoint target = CGPointMake(handleAtPress.x + (currentLocal.x - pressLocal.x),
                               handleAtPress.y + (currentLocal.y - pressLocal.y));
  bool drivesX = handle < 4 || handle == 5 || handle == 7;
  bool drivesY = handle < 4 || handle == 4 || handle == 6;
  if (proportional) {
    double factor = 1;
    if (drivesX && drivesY) {
      double length = handleAtPress.x * handleAtPress.x + handleAtPress.y * handleAtPress.y;
      if (length > 0) factor = (target.x * handleAtPress.x + target.y * handleAtPress.y) / length;
    } else if (drivesX && handleAtPress.x != 0) {
      factor = target.x / handleAtPress.x;
    } else if (drivesY && handleAtPress.y != 0) {
      factor = target.y / handleAtPress.y;
    }
    factor = fmax(0, factor);
    double x = press.scaleX * factor, y = press.scaleY * factor;
    if (x > OSCBoxMaxScale) { y *= OSCBoxMaxScale / x; x = OSCBoxMaxScale; }
    if (y > OSCBoxMaxScale) { x *= OSCBoxMaxScale / y; y = OSCBoxMaxScale; }
    pose.scaleX = OSCBoxClampScale(x);
    pose.scaleY = OSCBoxClampScale(y);
    return pose;
  }
  if (drivesX && base.x != 0) pose.scaleX = OSCBoxClampScale(target.x / base.x * 100);
  if (drivesY && base.y != 0) pose.scaleY = OSCBoxClampScale(target.y / base.y * 100);
  return pose;
}
