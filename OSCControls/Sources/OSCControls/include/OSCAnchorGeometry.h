/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#include "OSCBoxGeometry.h"
#include "OSCRotationGeometry.h"
#include <CoreGraphics/CoreGraphics.h>

// The anchor square: the handle on the pivot every rotation and scale turns
// about, which is the position offset plus the anchor (OSCBoxPivotPixels).
// Its part number continues the rotation gizmo's, so one hit test still covers
// the whole control.
enum { OSCBoxPartAnchor = OSCBoxPartRingBase + OSCRingCount };

// The four behaviours a part number selects, so a control can dispatch on the
// kind instead of the numeric ranges that box, ring and anchor split between
// three headers.
enum {
  OSCBoxPartKindPosition = 0,
  OSCBoxPartKindHandle = 1,
  OSCBoxPartKindRing = 2,
  OSCBoxPartKindAnchor = 3,
};
static inline int OSCBoxPartKind(long part) {
  if (part >= OSCBoxPartAnchor) return OSCBoxPartKindAnchor;
  if (part >= OSCBoxPartRingBase) return OSCBoxPartKindRing;
  if (part >= OSCBoxPartHandleBase) return OSCBoxPartKindHandle;
  return OSCBoxPartKindPosition;
}

// Glyph metrics in canvas pixels. A rounded square the size of the round scale
// handles, with its outline inset from the edge and a drop shadow below it, so
// the pivot reads over both the image and the other controls.
#define OSCAnchorHalfExtent 9.0
#define OSCAnchorCornerRadius 2.0
#define OSCAnchorOutlineWidth 1.5
#define OSCAnchorShadowOffset 1.5
#define OSCAnchorShadowRadius 2.5
#define OSCAnchorHitRadius 11.5

// The anchor after a drag of `deltaPixels` away from the press point. Pixel
// space is the anchor's own unit, so the pivot follows the pointer one to one
// and grabbing the square off-centre never jumps it.
static inline OSCBoxPose OSCBoxPoseWithAnchorMovedBy(OSCBoxPose press, CGPoint deltaPixels) {
  OSCBoxPose pose = press;
  pose.anchorX = press.anchorX + deltaPixels.x;
  pose.anchorY = press.anchorY + deltaPixels.y;
  return pose;
}
