/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A KKPillToggleRowView inside a horizontal scroll view with fading edge
/// shadows when the pills overflow the available width. Multi-select with
/// click-and-drag sweep; onDragBegin/End bracket the whole gesture so the
/// consumer coalesces it to one undo entry. Plugin-agnostic and reusable
/// (e.g. a Canvas layer list with many lanes).
@interface KKPillBar : NSView

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels;

@property(nonatomic, copy) NSArray<NSNumber *> *states;
@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger index, BOOL isOn);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

- (void)setState:(BOOL)on atIndex:(NSInteger)index;

/// Row height (drives the bar's intrinsic height); set before adding.
@property(nonatomic) BOOL grouped;

@end

NS_ASSUME_NONNULL_END
