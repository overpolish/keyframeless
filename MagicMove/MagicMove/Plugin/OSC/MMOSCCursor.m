/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMOSCCursor.h"
#import "MagicMoveOSC.h"
#import <AppKit/AppKit.h>

// Hotspots are FCP's own (LunaKit SRCursor.plist, top-left origin): the resize
// arrows aim at (15,14), MoveCurve at (16,16). The glyph sits up-left of the
// 32x32 frame because the drop shadow fills the lower-right.
static NSCursor *MMBundledCursor(NSString *asset, NSPoint hotSpot) {
  static NSMutableDictionary<NSString *, NSCursor *> *cache;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; lock = [NSLock new]; });
  [lock lock];
  @try {
    NSCursor *cached = cache[asset];
    if (cached) return cached;
    // Xcode folds Name.png + Name@2x.png into one multi-rep image; resolve by base name.
    NSImage *image = [[NSBundle bundleForClass:MagicMoveOSC.class] imageForResource:asset];
    if (!image.isValid) return nil;
    NSCursor *cursor = [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
    cache[asset] = cursor;
    return cursor;
  } @finally {
    [lock unlock];
  }
}

static NSCursor *MMPrivateCursor(NSString *name) {
  SEL selector = NSSelectorFromString(name);
  if (![NSCursor respondsToSelector:selector]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  return [NSCursor performSelector:selector];
#pragma clang diagnostic pop
}

static NSCursor *MMResizeCursor(NSString *asset, NSPoint hotSpot, NSString *privateName, NSCursor *fallback) {
  return MMBundledCursor(asset, hotSpot) ?: MMPrivateCursor(privateName) ?: fallback;
}

NSCursor *MMResizeCursorForBoxHandle(NSInteger handleIndex) {
  switch (handleIndex) {
  case 0: // bottom-left and top-right share the "/" diagonal
  case 2:
    return MMResizeCursor(@"ResizeTopRightCursor", NSMakePoint(15, 14), @"_windowResizeNorthEastSouthWestCursor",
                          [NSCursor resizeLeftRightCursor]);
  case 1: // bottom-right and top-left share the "\" diagonal
  case 3:
    return MMResizeCursor(@"ResizeTopLeftCursor", NSMakePoint(15, 14), @"_windowResizeNorthWestSouthEastCursor",
                          [NSCursor resizeUpDownCursor]);
  case 4:
  case 6:
    return MMResizeCursor(@"MoveCurve", NSMakePoint(16, 16), @"_windowResizeNorthSouthCursor",
                          [NSCursor resizeUpDownCursor]);
  case 5:
  case 7:
    return MMResizeCursor(@"ResizeLeftRightCursor", NSMakePoint(15, 14), @"_windowResizeEastWestCursor",
                          [NSCursor resizeLeftRightCursor]);
  default:
    return nil;
  }
}
