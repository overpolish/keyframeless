/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Radio-style pill selector for line join styles (miter, round, bevel).
/// Each pill renders a mini preview of the join shape.
@interface KKJoinStyleView : NSView

@property(nonatomic) NSInteger selectedIndex; // 0=miter, 1=round, 2=bevel
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;

@end

NS_ASSUME_NONNULL_END
