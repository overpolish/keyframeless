/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "OSCBoxGeometry.h"
#include "OSCAnchorGeometry.h"
#include <assert.h>
#include <math.h>

static bool Near(CGPoint a, double x, double y) { return fabs(a.x - x) < 1e-6 && fabs(a.y - y) < 1e-6; }
static OSCBoxPose Identity(void) { return (OSCBoxPose){0, 0, 100, 100, 0, 0, 0, 0, 0}; }

static void corners(void) {
  CGSize hd = CGSizeMake(1920, 1080), square = CGSizeMake(1000, 1000);
  CGPoint c[4];
  OSCBoxCorners(Identity(), hd, c);
  assert(Near(c[0], 0, 0) && Near(c[1], 1, 0) && Near(c[2], 1, 1) && Near(c[3], 0, 1));
  assert(Near(OSCBoxHandlePoint(c, 4), 0.5, 0) && Near(OSCBoxHandlePoint(c, 5), 1, 0.5) &&
         Near(OSCBoxHandlePoint(c, 6), 0.5, 1) && Near(OSCBoxHandlePoint(c, 7), 0, 0.5));
  OSCBoxPose moved = Identity(); moved.positionX = 10; moved.positionY = 20;
  OSCBoxCorners(moved, hd, c);
  assert(Near(c[0], 0.1, 0.2) && Near(c[2], 1.1, 1.2));
  OSCBoxPose half = Identity(); half.scaleX = 50;
  OSCBoxCorners(half, hd, c);
  assert(Near(c[0], 0.25, 0) && Near(c[1], 0.75, 0) && Near(c[2], 0.75, 1));
  // A quarter turn counter-clockwise sends the bottom-left corner to bottom-right.
  OSCBoxPose turned = Identity(); turned.rotation = 90;
  OSCBoxCorners(turned, square, c);
  assert(Near(c[0], 1, 0) && Near(c[1], 1, 1) && Near(c[2], 0, 1) && Near(c[3], 0, 0));
  // A 45° tilt around X foreshortens vertically by cos(45°).
  OSCBoxPose tiltX = Identity(); tiltX.rotationX = 45;
  assert(OSCBoxCorners(tiltX, square, c));
  assert(Near(c[0], 0, 0.14644661) && Near(c[1], 1, 0.14644661) &&
         Near(c[2], 1, 0.85355339) && Near(c[3], 0, 0.85355339));
  // A 90° tilt around Y is edge-on: the render draws nothing and no handle is reachable.
  OSCBoxPose edgeOn = Identity(); edgeOn.rotationY = 90;
  assert(!OSCBoxCorners(edgeOn, square, c));
  // Scaling pivots on the anchor, which stays put.
  OSCBoxPose pivot = Identity(); pivot.scaleX = pivot.scaleY = 50; pivot.anchorX = 500;
  OSCBoxCorners(pivot, square, c);
  assert(Near(c[0], 0.5, 0.25) && Near(c[1], 1, 0.25) && Near(c[2], 1, 0.75));
  CGPoint px = OSCBoxPixelFromObject(CGPointMake(0.75, 0.25), hd);
  assert(Near(px, 480, -270) && Near(OSCBoxObjectFromPixel(px, hd), 0.75, 0.25));
}

static void hits(void) {
  CGPoint c[4];
  OSCBoxCorners(Identity(), CGSizeMake(1000, 1000), c);
  for (long i = 0; i < 4; ++i) { c[i].x *= 1000; c[i].y *= 1000; }
  assert(Near(OSCBoxHandleAxis(c, 4), 1, 0) && Near(OSCBoxHandleAxis(c, 5), 0, 1) &&
         Near(OSCBoxHandleAxis(c, 6), -1, 0) && Near(OSCBoxHandleAxis(c, 7), 0, -1) && Near(OSCBoxHandleAxis(c, 0), 0, 0));
  assert(OSCBoxHitTest(c, CGPointMake(1002, 998), 10, true) == OSCBoxPartHandleBase + 2);
  assert(OSCBoxHitTest(c, CGPointMake(500, -6), 10, true) == OSCBoxPartHandleBase + 4);
  // Pills extend along their edge, so a point past the midpoint still hits.
  assert(OSCBoxHitTest(c, CGPointMake(500 + OSCBoxPillHalfLength + 4, 0), 10, true) == OSCBoxPartHandleBase + 4);
  assert(OSCBoxHitTest(c, CGPointMake(500 + OSCBoxPillHalfLength + 12, 0), 10, true) == OSCBoxPartPosition);
  assert(OSCBoxHitTest(c, CGPointMake(1000, 500 - OSCBoxPillHalfLength - 4), 10, true) == OSCBoxPartHandleBase + 5);
  // A corner beats the edge midpoints that share its coordinate.
  assert(OSCBoxHitTest(c, CGPointMake(3, 3), 10, true) == OSCBoxPartHandleBase + 0);
  // Anywhere else, including far outside the image, moves the image.
  assert(OSCBoxHitTest(c, CGPointMake(500, 500), 10, true) == OSCBoxPartPosition);
  assert(OSCBoxHitTest(c, CGPointMake(-9000, 40000), 10, true) == OSCBoxPartPosition);
  assert(OSCBoxHitTest(c, CGPointMake(1000, 1011), 10, true) == OSCBoxPartPosition);
  // Hidden handles leave no invisible resize region; the image still moves.
  assert(OSCBoxHitTest(c, CGPointMake(1002, 998), 10, false) == OSCBoxPartPosition);
  assert(OSCBoxHitTest(c, CGPointMake(500, -6), 10, false) == OSCBoxPartPosition);
  assert(OSCBoxHitTest(c, CGPointMake(500, 500), 10, false) == OSCBoxPartPosition);
}

static void moves(void) {
  OSCBoxPose pose = OSCBoxPoseMovedBy(Identity(), CGPointMake(192, -108), CGSizeMake(1920, 1080));
  assert(fabs(pose.positionX - 10) < 1e-9 && fabs(pose.positionY + 10) < 1e-9 && pose.scaleX == 100);
  OSCBoxPose start = Identity(); start.positionX = -30;
  pose = OSCBoxPoseMovedBy(start, CGPointMake(960, 0), CGSizeMake(1920, 1080));
  assert(fabs(pose.positionX - 20) < 1e-9);
}

static void scales(void) {
  CGSize hd = CGSizeMake(1920, 1080), square = CGSizeMake(1000, 1000);
  OSCBoxPose pose = OSCBoxPoseScaledByHandle(Identity(), 2, CGPointMake(960, 540), CGPointMake(1152, 648), hd, false);
  assert(fabs(pose.scaleX - 120) < 1e-9 && fabs(pose.scaleY - 120) < 1e-9);
  pose = OSCBoxPoseScaledByHandle(Identity(), 2, CGPointMake(960, 540), CGPointMake(1152, 540), hd, false);
  assert(fabs(pose.scaleX - 120) < 1e-9 && fabs(pose.scaleY - 100) < 1e-9);
  // Edges drive one axis; proportional couples the other.
  pose = OSCBoxPoseScaledByHandle(Identity(), 5, CGPointMake(960, 0), CGPointMake(1152, 300), hd, false);
  assert(fabs(pose.scaleX - 120) < 1e-9 && fabs(pose.scaleY - 100) < 1e-9);
  pose = OSCBoxPoseScaledByHandle(Identity(), 5, CGPointMake(960, 0), CGPointMake(1152, 300), hd, true);
  assert(fabs(pose.scaleX - 120) < 1e-9 && fabs(pose.scaleY - 120) < 1e-9);
  pose = OSCBoxPoseScaledByHandle(Identity(), 4, CGPointMake(0, -540), CGPointMake(0, -432), hd, false);
  assert(fabs(pose.scaleX - 100) < 1e-9 && fabs(pose.scaleY - 80) < 1e-9);
  // Proportional corner drag projects onto the pressed diagonal.
  pose = OSCBoxPoseScaledByHandle(Identity(), 2, CGPointMake(960, 540), CGPointMake(1152, 648), hd, true);
  assert(fabs(pose.scaleX - 120) < 1e-9 && fabs(pose.scaleY - 120) < 1e-9);
  OSCBoxPose wide = Identity(); wide.scaleX = 200; wide.scaleY = 50;
  pose = OSCBoxPoseScaledByHandle(wide, 5, CGPointMake(1920, 0), CGPointMake(2112, 0), hd, true);
  assert(fabs(pose.scaleX - 220) < 1e-9 && fabs(pose.scaleY - 55) < 1e-9);
  // The grab offset is preserved so the handle never jumps.
  pose = OSCBoxPoseScaledByHandle(Identity(), 2, CGPointMake(950, 530), CGPointMake(1142, 638), hd, false);
  assert(fabs(pose.scaleX - 120) < 1e-9 && fabs(pose.scaleY - 120) < 1e-9);
  // Rotated box: the right-mid handle sits at the top of the screen.
  OSCBoxPose turned = Identity(); turned.rotation = 90;
  pose = OSCBoxPoseScaledByHandle(turned, 5, CGPointMake(0, 500), CGPointMake(0, 600), square, false);
  assert(fabs(pose.scaleX - 120) < 1e-9 && fabs(pose.scaleY - 100) < 1e-9);
  // Tilted box: dragging the foreshortened top edge out to full screen height
  // scales the image's own Y axis, not the screen's.
  OSCBoxPose tiltX = Identity(); tiltX.rotationX = 45;
  pose = OSCBoxPoseScaledByHandle(tiltX, 6, CGPointMake(0, 353.55339), CGPointMake(0, 500), square, false);
  assert(fabs(pose.scaleX - 100) < 1e-6 && fabs(pose.scaleY - 141.421356) < 1e-6);
  // Anchor-relative: with the anchor on the right edge, the left edge drives twice the span.
  OSCBoxPose pivot = Identity(); pivot.anchorX = 500;
  pose = OSCBoxPoseScaledByHandle(pivot, 7, CGPointMake(-500, 0), CGPointMake(-700, 0), square, false);
  assert(fabs(pose.scaleX - 120) < 1e-9);
  // Clamping: crossing the anchor stops at zero, huge drags stop at 400%.
  pose = OSCBoxPoseScaledByHandle(Identity(), 5, CGPointMake(960, 0), CGPointMake(-500, 0), hd, false);
  assert(pose.scaleX == 0);
  pose = OSCBoxPoseScaledByHandle(Identity(), 5, CGPointMake(960, 0), CGPointMake(9600, 0), hd, true);
  assert(pose.scaleX == 400 && pose.scaleY == 400);
  pose = OSCBoxPoseScaledByHandle(wide, 5, CGPointMake(1920, 0), CGPointMake(9600, 0), hd, true);
  assert(pose.scaleX == 400 && fabs(pose.scaleY - 100) < 1e-9);
  // Unknown handles and offsets that do not touch a driven axis leave the pose alone.
  pose = OSCBoxPoseScaledByHandle(Identity(), 9, CGPointMake(0, 0), CGPointMake(100, 100), hd, false);
  assert(pose.scaleX == 100 && pose.scaleY == 100);
}

// One contiguous part range, classified into its four behaviours regardless of
// which header owns the boundary.
static void partKinds(void) {
  assert(OSCBoxPartKind(OSCBoxPartNone) == OSCBoxPartKindPosition);
  assert(OSCBoxPartKind(OSCBoxPartPosition) == OSCBoxPartKindPosition);
  assert(OSCBoxPartKind(OSCBoxPartHandleBase) == OSCBoxPartKindHandle);
  assert(OSCBoxPartKind(OSCBoxPartHandleBase + OSCBoxHandleCount - 1) == OSCBoxPartKindHandle);
  assert(OSCBoxPartKind(OSCBoxPartRingBase) == OSCBoxPartKindRing);
  assert(OSCBoxPartKind(OSCBoxPartRingBase + OSCRingCount - 1) == OSCBoxPartKindRing);
  assert(OSCBoxPartKind(OSCBoxPartAnchor) == OSCBoxPartKindAnchor);
  assert(OSCBoxPartKind(OSCBoxPartAnchor + 1) == OSCBoxPartKindAnchor);
}

int main(void) {
  corners();
  hits();
  moves();
  scales();
  partKinds();
  puts("OSC geometry: corners, handles, anywhere hit test, moves, handle scaling, rotation, anchor and clamping passed");
  return 0;
}
