/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KeyframelessKit.h>

@implementation MagicMovePlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  // No conditional visibility yet - multi-stage timing will own this later.
}

@end
