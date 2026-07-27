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
@class KKPillToggleRowView;

@interface KKPillBar : NSView

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels;
/// Wrap an already-configured pill row (e.g. the category nav pill from
/// KKMakeLaneCategoryPill, with its own onToggled) in the scroll + edge-fade.
/// The row keeps its callbacks; the bar only adds overflow scrolling.
- (instancetype)initWithPillRow:(KKPillToggleRowView *)row;

@property(nonatomic, copy) NSArray<NSNumber *> *states;
@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger index, BOOL isOn);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

- (void)setState:(BOOL)on atIndex:(NSInteger)index;

/// Row height (drives the bar's intrinsic height); set before adding.
@property(nonatomic) BOOL grouped;

/// Ceiling on the bar's intrinsic WIDTH (0 = unlimited, the default).
///
/// Without it a long pill run reports its full content width as the intrinsic
/// size, which propagates into the host's fitting width: a fixed-size host
/// (e.g. a popover pinned to a set content width) gets its content VIEW
/// stretched past the window, and the bar visibly overhangs the edge instead
/// of scrolling. Set this to the width actually available and the inner
/// scroll takes over, which is the point of the bar.
@property(nonatomic) CGFloat maxIntrinsicWidth;

@end

NS_ASSUME_NONNULL_END
