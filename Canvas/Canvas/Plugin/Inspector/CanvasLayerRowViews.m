/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRowViews.h"

NSSet<NSString *> *CanvasLayerImageExtensions(void) {
  static NSSet *exts;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    exts = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", @"heic",
                                 @"tiff", @"tif", @"gif", @"bmp", nil];
  });
  return exts;
}
