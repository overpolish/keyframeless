/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Shows the current seed value with a re-roll button.
@interface KKSeedView : NSView

@property(nonatomic) uint32_t seed;
@property(nonatomic, copy, nullable) void (^onReroll)(void);
@property(nonatomic, copy, nullable) void (^onSeedChanged)(uint32_t newSeed);

@end

NS_ASSUME_NONNULL_END
