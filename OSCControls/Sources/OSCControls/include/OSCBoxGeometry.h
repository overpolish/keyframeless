/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

// The rendered footprint of the source image: position and scale in percent,
// Euler rotation in degrees, anchor in full-resolution pixels from the centre.
typedef struct {
  double positionX, positionY;
  double scaleX, scaleY;
  double rotation, rotationX, rotationY;
  double anchorX, anchorY;
} OSCBoxPose;

enum { OSCBoxPartNone = 0, OSCBoxPartPosition = 1, OSCBoxPartHandleBase = 2 };
#define OSCBoxHandleCount 8
#define OSCBoxHandleHitRadius 10.0
// Glyph metrics in canvas pixels: corners are points, edges are pills whose
// long axis follows the edge.
#define OSCBoxHandleRadius 8.5
#define OSCBoxPillHalfLength 10.0
#define OSCBoxMaxScale 400.0

// Pixel space is the image plane in full-resolution pixels, origin at the
// image centre, Y up. It matches the render shader's pivot and offset math.
CGPoint OSCBoxPixelFromObject(CGPoint object, CGSize imageSize);
CGPoint OSCBoxObjectFromPixel(CGPoint pixel, CGSize imageSize);

// Object-space (0..1, Y up) corners: bottom-left, bottom-right, top-right,
// top-left of the transformed image. Returns false when the plane is edge-on,
// where the render draws nothing and no handle is reachable.
bool OSCBoxCorners(OSCBoxPose pose, CGSize imageSize, CGPoint corners[4]);
// 0-3 corners in the order above, 4-7 edge midpoints: bottom, right, top, left.
CGPoint OSCBoxHandlePoint(const CGPoint corners[4], long index);
// Unit direction of the edge an edge handle sits on (zero for corners).
CGPoint OSCBoxHandleAxis(const CGPoint corners[4], long index);
// Nearest handle within `radius` of its glyph wins (pills measure to their
// segment); anywhere else is the position part, so the image can be dragged
// even when the box lies outside the viewer.
long OSCBoxHitTest(const CGPoint corners[4], CGPoint point, double radius);

OSCBoxPose OSCBoxPoseMovedBy(OSCBoxPose press, CGPoint deltaPixels, CGSize imageSize);
// Scales about the anchor so the grabbed handle follows the pointer. Corners
// drive both axes, edges one; `proportional` keeps the pressed ratio.
OSCBoxPose OSCBoxPoseScaledByHandle(OSCBoxPose press, long handle, CGPoint pressPixels,
                                  CGPoint currentPixels, CGSize imageSize, bool proportional);
