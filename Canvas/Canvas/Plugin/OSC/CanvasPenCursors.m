/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPenCursors.h"

// Anchors -bundleForClass: on the plugin bundle, where the cursor images live.
@interface _CanvasPenCursorsBundle : NSObject
@end
@implementation _CanvasPenCursorsBundle
@end

static NSCursor *MakeCursor(NSString *name, NSPoint hot) {
  NSBundle *bundle = [NSBundle bundleForClass:[_CanvasPenCursorsBundle class]];
  NSImage *image = [bundle imageForResource:name];
  return image ? [[NSCursor alloc] initWithImage:image hotSpot:hot]
               : [NSCursor crosshairCursor];
}

NSCursor *CanvasPenCursorForRole(CanvasPenCursorRole role) {
  static NSCursor *pen, *close, *add, *del;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pen = MakeCursor(@"Pen", NSMakePoint(15, 5));
    close = MakeCursor(@"PenCloseShape", NSMakePoint(10, 5));
    add = MakeCursor(@"PenAddControlPoint", NSMakePoint(10, 5));
    del = MakeCursor(@"PenX", NSMakePoint(15, 5));
  });
  switch (role) {
  case CanvasPenCursorRoleClose:
    return close;
  case CanvasPenCursorRoleAdd:
    return add;
  case CanvasPenCursorRoleDelete:
    return del;
  case CanvasPenCursorRolePen:
  default:
    return pen;
  }
}
