/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Radio-style pill selector for line cap styles (butt, round, square).
/// Each pill renders a mini preview of the cap shape.
@interface KKCapStyleView : NSView

@property(nonatomic) NSInteger selectedIndex; // 0=butt, 1=round, 2=square
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;

@end

NS_ASSUME_NONNULL_END
