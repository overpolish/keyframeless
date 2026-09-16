/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
@class NSCursor;

// FCP's own cursor art (extracted from LunaKit, shipped in this package's
// resource bundle). The kinds are the distinct cursors the viewer shows, so
// callers can compare what they are about to display and only talk to the
// host when it changes.
typedef NS_ENUM(NSInteger, OSCCursorKind) {
  OSCCursorArrow = 0,
  OSCCursorResizeHorizontal,
  OSCCursorResizeVertical,
  OSCCursorResizeDiagonalNESW, // the "/" diagonal
  OSCCursorResizeDiagonalNWSE, // the "\" diagonal
  OSCCursorRotateTopRight,
  OSCCursorRotateTopLeft,
  OSCCursorRotateBottomLeft,
  OSCCursorRotateBottomRight,
};

// Falls back to a private AppKit window-resize cursor, then a public cursor,
// when the bundled art is missing.
FOUNDATION_EXPORT NSCursor *OSCCursorOfKind(OSCCursorKind kind);
// Box handles: 0-3 corners bottom-left, bottom-right, top-right, top-left map
// to the two diagonals; 4-7 edges bottom, right, top, left map to
// vertical/horizontal. Anything else is the arrow.
FOUNDATION_EXPORT OSCCursorKind OSCResizeCursorKindForBoxHandle(NSInteger handleIndex);
// Resize cursor aligned with a direction, for dragging along a curve: eight
// sectors of the canvas angle (Y up) collapse onto the four resize kinds.
FOUNDATION_EXPORT OSCCursorKind OSCResizeCursorKindForAngle(double radians);
// Rotate cursor for an in-plane spin, chosen by the quadrant of the canvas
// angle (Y up) the pointer sits in.
FOUNDATION_EXPORT OSCCursorKind OSCRotateCursorKindForAngle(double radians);
