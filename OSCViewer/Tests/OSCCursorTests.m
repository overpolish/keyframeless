/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "OSCCursor.h"
#import <AppKit/AppKit.h>
#import <assert.h>
#import <math.h>

// Handles map to the two diagonals and the two axes; anything else is the arrow.
static void handleCursors(void) {
  assert(OSCResizeCursorKindForBoxHandle(0) == OSCCursorResizeDiagonalNESW);
  assert(OSCResizeCursorKindForBoxHandle(2) == OSCCursorResizeDiagonalNESW);
  assert(OSCResizeCursorKindForBoxHandle(1) == OSCCursorResizeDiagonalNWSE);
  assert(OSCResizeCursorKindForBoxHandle(3) == OSCCursorResizeDiagonalNWSE);
  assert(OSCResizeCursorKindForBoxHandle(4) == OSCCursorResizeVertical);
  assert(OSCResizeCursorKindForBoxHandle(6) == OSCCursorResizeVertical);
  assert(OSCResizeCursorKindForBoxHandle(5) == OSCCursorResizeHorizontal);
  assert(OSCResizeCursorKindForBoxHandle(7) == OSCCursorResizeHorizontal);
  assert(OSCResizeCursorKindForBoxHandle(8) == OSCCursorArrow);
  assert(OSCResizeCursorKindForBoxHandle(-1) == OSCCursorArrow);
}

// Angles are canvas Y up; opposite directions share a cursor, sector edges
// round to the nearest, and negative or wrapped angles normalise.
static void angleCursors(void) {
  assert(OSCResizeCursorKindForAngle(0) == OSCCursorResizeHorizontal);
  assert(OSCResizeCursorKindForAngle(M_PI) == OSCCursorResizeHorizontal);
  assert(OSCResizeCursorKindForAngle(M_PI_2) == OSCCursorResizeVertical);
  assert(OSCResizeCursorKindForAngle(-M_PI_2) == OSCCursorResizeVertical);
  assert(OSCResizeCursorKindForAngle(M_PI_4) == OSCCursorResizeDiagonalNESW);
  assert(OSCResizeCursorKindForAngle(5 * M_PI_4) == OSCCursorResizeDiagonalNESW);
  assert(OSCResizeCursorKindForAngle(3 * M_PI_4) == OSCCursorResizeDiagonalNWSE);
  assert(OSCResizeCursorKindForAngle(-M_PI_4) == OSCCursorResizeDiagonalNWSE);
  assert(OSCResizeCursorKindForAngle(4 * M_PI + 0.1) == OSCCursorResizeHorizontal);
  assert(OSCRotateCursorKindForAngle(0.1) == OSCCursorRotateTopRight);
  assert(OSCRotateCursorKindForAngle(M_PI_2 + 0.1) == OSCCursorRotateTopLeft);
  assert(OSCRotateCursorKindForAngle(M_PI + 0.1) == OSCCursorRotateBottomLeft);
  assert(OSCRotateCursorKindForAngle(-0.1) == OSCCursorRotateBottomRight);
}

// The art resolves through the SwiftPM resource bundle beside the binary,
// with FCP's hotspots; every kind still yields a cursor when the art is gone.
static void cursorArt(BOOL packaged) {
  assert(OSCCursorOfKind(OSCCursorArrow) == NSCursor.arrowCursor);
  for (OSCCursorKind kind = OSCCursorArrow; kind <= OSCCursorRotateBottomRight; ++kind) assert(OSCCursorOfKind(kind));
  if (!packaged) return;
  NSCursor *rotate = OSCCursorOfKind(OSCCursorRotateTopRight);
  assert(NSEqualPoints(rotate.hotSpot, NSMakePoint(14, 16)) && NSEqualSizes(rotate.image.size, NSMakeSize(32, 32)));
  assert(rotate.image.representations.count == 2);
  NSCursor *resize = OSCCursorOfKind(OSCCursorResizeHorizontal);
  assert(NSEqualPoints(resize.hotSpot, NSMakePoint(15, 14)));
  assert(OSCCursorOfKind(OSCCursorRotateTopRight) == rotate);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    handleCursors();
    angleCursors();
    cursorArt(argc > 1 && strcmp(argv[1], "--packaged") == 0);
    puts("OSC cursors: handle and angle mapping, packaged art and fallbacks passed");
  }
  return 0;
}
