/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Radio-style pill selector for stroke styles (solid, dashed, dotted).
/// Each pill renders a mini preview of the stroke pattern.
@interface KKStrokeStyleView : NSView

@property(nonatomic) NSInteger selectedIndex; // 0=solid, 1=dashed, 2=dotted
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;

@end

NS_ASSUME_NONNULL_END
