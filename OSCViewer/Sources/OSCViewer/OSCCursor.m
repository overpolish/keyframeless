/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "OSCCursor.h"
#import <AppKit/AppKit.h>
#import <math.h>

// Anchors bundleForClass: to whichever binary this package was linked into.
@interface OSCCursorArt : NSObject
@end
@implementation OSCCursorArt
@end

// SwiftPM ships the art as OSCViewer_OSCViewer.bundle beside the plugin's own
// resources. A plugin that carries the PNGs itself, or a test binary built
// without SwiftPM, resolves against its own bundle instead.
static NSBundle *OSCCursorBundle(void) {
  NSBundle *host = [NSBundle bundleForClass:OSCCursorArt.class];
  NSURL *packaged = [host URLForResource:@"OSCViewer_OSCViewer" withExtension:@"bundle"];
  return (packaged ? [NSBundle bundleWithURL:packaged] : nil) ?: host;
}

// Hotspots are FCP's own (LunaKit SRCursor.plist, top-left origin): the resize
// arrows aim at (15,14), MoveCurve at (16,16). The glyph sits up-left of the
// 32x32 frame because the drop shadow fills the lower-right.
static NSCursor *OSCBundledCursor(NSString *asset, NSPoint hotSpot) {
  static NSMutableDictionary<NSString *, NSCursor *> *cache;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; lock = [NSLock new]; });
  [lock lock];
  @try {
    NSCursor *cached = cache[asset];
    if (cached) return cached;
    // Name.png + Name@2x.png resolve as one multi-rep image by base name.
    NSImage *image = [OSCCursorBundle() imageForResource:asset];
    if (!image.isValid) return nil;
    NSCursor *cursor = [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
    cache[asset] = cursor;
    return cursor;
  } @finally {
    [lock unlock];
  }
}

static NSCursor *OSCPrivateCursor(NSString *name) {
  SEL selector = NSSelectorFromString(name);
  if (![NSCursor respondsToSelector:selector]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  return [NSCursor performSelector:selector];
#pragma clang diagnostic pop
}

static NSCursor *OSCResizeCursor(NSString *asset, NSPoint hotSpot, NSString *privateName, NSCursor *fallback) {
  return OSCBundledCursor(asset, hotSpot) ?: OSCPrivateCursor(privateName) ?: fallback;
}

NSCursor *OSCCursorOfKind(OSCCursorKind kind) {
  switch (kind) {
  case OSCCursorResizeHorizontal:
    return OSCResizeCursor(@"ResizeLeftRightCursor", NSMakePoint(15, 14), @"_windowResizeEastWestCursor",
                           [NSCursor resizeLeftRightCursor]);
  case OSCCursorResizeVertical:
    return OSCResizeCursor(@"MoveCurve", NSMakePoint(16, 16), @"_windowResizeNorthSouthCursor",
                           [NSCursor resizeUpDownCursor]);
  case OSCCursorResizeDiagonalNESW:
    return OSCResizeCursor(@"ResizeTopRightCursor", NSMakePoint(15, 14), @"_windowResizeNorthEastSouthWestCursor",
                           [NSCursor resizeLeftRightCursor]);
  case OSCCursorResizeDiagonalNWSE:
    return OSCResizeCursor(@"ResizeTopLeftCursor", NSMakePoint(15, 14), @"_windowResizeNorthWestSouthEastCursor",
                           [NSCursor resizeUpDownCursor]);
  // The four rotate renditions are not keyed in SRCursor.plist, so the hotspot
  // is the measured centre of the curved arrow.
  case OSCCursorRotateTopRight:
    return OSCBundledCursor(@"RotateTopRightCursor", NSMakePoint(14, 16)) ?: [NSCursor arrowCursor];
  case OSCCursorRotateTopLeft:
    return OSCBundledCursor(@"RotateTopLeftCursor", NSMakePoint(17, 16)) ?: [NSCursor arrowCursor];
  case OSCCursorRotateBottomLeft:
    return OSCBundledCursor(@"RotateBottomLeftCursor", NSMakePoint(17, 13)) ?: [NSCursor arrowCursor];
  case OSCCursorRotateBottomRight:
    return OSCBundledCursor(@"RotateBottomRightCursor", NSMakePoint(14, 13)) ?: [NSCursor arrowCursor];
  case OSCCursorArrow:
    break;
  }
  return [NSCursor arrowCursor];
}

OSCCursorKind OSCResizeCursorKindForBoxHandle(NSInteger handleIndex) {
  switch (handleIndex) {
  case 0: // bottom-left and top-right share the "/" diagonal
  case 2: return OSCCursorResizeDiagonalNESW;
  case 1: // bottom-right and top-left share the "\" diagonal
  case 3: return OSCCursorResizeDiagonalNWSE;
  case 4:
  case 6: return OSCCursorResizeVertical;
  case 5:
  case 7: return OSCCursorResizeHorizontal;
  default: return OSCCursorArrow;
  }
}

static double OSCCursorDegrees(double radians) {
  double degrees = fmod(radians * 180 / M_PI, 360);
  return degrees < 0 ? degrees + 360 : degrees;
}

OSCCursorKind OSCResizeCursorKindForAngle(double radians) {
  switch (((int)round(OSCCursorDegrees(radians) / 45)) % 8) {
  case 1: // NE
  case 5: return OSCCursorResizeDiagonalNESW;
  case 2: // N
  case 6: return OSCCursorResizeVertical;
  case 3: // NW
  case 7: return OSCCursorResizeDiagonalNWSE;
  default: return OSCCursorResizeHorizontal; // E and W
  }
}

OSCCursorKind OSCRotateCursorKindForAngle(double radians) {
  double degrees = OSCCursorDegrees(radians);
  if (degrees < 90) return OSCCursorRotateTopRight;
  if (degrees < 180) return OSCCursorRotateTopLeft;
  if (degrees < 270) return OSCCursorRotateBottomLeft;
  return OSCCursorRotateBottomRight;
}
