/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Constants.h"
#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKSquarePointOSC.h>

NS_ASSUME_NONNULL_BEGIN

@interface MagicMoveOSC ()
@property(nonatomic, strong) KKCompoundPointOSC *point;
@property(nonatomic, strong) KKSnapEngine *pointSnap;
@property(nonatomic, strong) KKSquarePointOSC *anchorOSC;
@property(nonatomic, strong) KKSnapEngine *anchorSnap;
@property(nonatomic) BOOL anchorHovered;
@property(nonatomic) BOOL anchorDragging;
@end

@interface MagicMoveOSC (Helpers)
- (BOOL)boolParam:(UInt32)paramID atTime:(CMTime)time;
@end

NS_ASSUME_NONNULL_END
