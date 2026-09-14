/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKLaneRowView.h>

NS_ASSUME_NONNULL_BEGIN

/// Slider + value field row. Caller supplies `min` / `max` (model range)
/// and an optional `unit` suffix (e.g. @"px", @"°") shown next to the
/// field. Slider drags coalesce via onDragBegin/onDragEnd; the field
/// commits on Return / focus loss.
@interface KKSliderRowView : KKLaneRowView

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(nullable NSString *)tooltip
                    laneColor:(nullable NSColor *)laneColor
                     minValue:(double)minValue
                     maxValue:(double)maxValue
                         unit:(nullable NSString *)unit
                      binding:(double (^)(void))binding
                      onValue:(void (^)(double value))onValue
                  onDragBegin:(nullable void (^)(void))onDragBegin
                    onDragEnd:(nullable void (^)(void))onDragEnd;

@end

NS_ASSUME_NONNULL_END
