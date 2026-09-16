/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
@class NSCursor;

// FCP's own cursor art (extracted from LunaKit, bundled in Resources). The
// kinds are the distinct cursors the viewer shows, so callers can compare what
// they are about to display and only talk to the host when it changes.
typedef NS_ENUM(NSInteger, MMOSCCursorKind) {
  MMOSCCursorArrow = 0,
  MMOSCCursorResizeHorizontal,
  MMOSCCursorResizeVertical,
  MMOSCCursorResizeDiagonalNESW, // the "/" diagonal
  MMOSCCursorResizeDiagonalNWSE, // the "\" diagonal
  MMOSCCursorRotateTopRight,
  MMOSCCursorRotateTopLeft,
  MMOSCCursorRotateBottomLeft,
  MMOSCCursorRotateBottomRight,
};

// Falls back to a private AppKit window-resize cursor, then a public cursor,
// when the bundled art is missing.
NSCursor *MMCursorOfKind(MMOSCCursorKind kind);
// Box handles: 0-3 corners bottom-left, bottom-right, top-right, top-left map
// to the two diagonals; 4-7 edges bottom, right, top, left map to
// vertical/horizontal. Anything else is the arrow.
MMOSCCursorKind MMResizeCursorKindForBoxHandle(NSInteger handleIndex);
// Resize cursor aligned with a direction, for dragging along a curve: eight
// sectors of the canvas angle (Y up) collapse onto the four resize kinds.
MMOSCCursorKind MMResizeCursorKindForAngle(double radians);
// Rotate cursor for an in-plane spin, chosen by the quadrant of the canvas
// angle (Y up) the pointer sits in.
MMOSCCursorKind MMRotateCursorKindForAngle(double radians);
