/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKLaneRowView.h>

NS_ASSUME_NONNULL_BEGIN

/// Random-seed value row. Wraps KKSeedView (the existing seed field +
/// reroll button) so it picks up the shared row chrome and auto-refresh
/// affordances. Use anywhere a 32-bit random seed is editable.
@interface KKRandomRowView : KKLaneRowView

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(nullable NSString *)tooltip
                    laneColor:(nullable NSColor *)laneColor
                      binding:(uint32_t (^)(void))binding
                       onSeed:(void (^)(uint32_t seed))onSeed;

@end

NS_ASSUME_NONNULL_END
