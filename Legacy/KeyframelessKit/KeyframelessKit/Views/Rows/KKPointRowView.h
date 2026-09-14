/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKLaneRowView.h>

NS_ASSUME_NONNULL_BEGIN

/// N-axis numeric value row. Component count is fixed at construction
/// (componentLabels.count). Use for any "point-like" property: 1D scalar,
/// 2D Position (X/Y), 3D etc. Bindings keep the displayed values in sync
/// with the live model on cmd-Z / external mutation.
///
/// Field focus: re-publishes from `binding` only when no field is currently
/// editing (relies on KKValueTextField.kkEditing) - prevents clobbering an
/// in-progress edit.
@interface KKPointRowView : KKLaneRowView

- (instancetype)initWithTitle:(NSString *)title
                      tooltip:(nullable NSString *)tooltip
                    laneColor:(nullable NSColor *)laneColor
              componentLabels:(NSArray<NSString *> *)componentLabels
                      binding:(NSArray<NSNumber *> *_Nonnull (^)(void))binding
                      onValue:(void (^)(NSArray<NSNumber *> *values))onValue
                  onDragBegin:(nullable void (^)(void))onDragBegin
                    onDragEnd:(nullable void (^)(void))onDragEnd;

@end

NS_ASSUME_NONNULL_END
