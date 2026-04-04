/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKTimingSlot.h"

@implementation KKTimingSlot

+ (instancetype)slotWithView:(NSView *)view
                      height:(CGFloat)height
                  applyState:(KKTimingSlotApplyState)applyState {
  KKTimingSlot *slot = [[KKTimingSlot alloc] initInternal];
  slot->_view = view;
  slot->_height = height;
  slot->_applyState = [applyState copy];
  return slot;
}

- (instancetype)initInternal {
  return [super init];
}

@end
