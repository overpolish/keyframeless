/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

@implementation GlowPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  [self updateTimingParameterVisibility];

  NSArray<NSNumber *> *hideableParams = @[
    @(kParamHoldRadius),
    @(kParamHoldIntensity),
  ];

  if ([self forceShowAllParametersIfEnabled:kParamForceShow
                                   paramIDs:hideableParams
                                     atTime:time])
    return;
}

@end
