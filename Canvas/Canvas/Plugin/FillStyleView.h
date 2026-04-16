/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Radio-style pill selector for fill styles (solid, hachure, cross-hatch,
/// zigzag, dots). Each pill renders a mini preview of the fill pattern.
@interface KKFillStyleView : NSView

@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;

@end

NS_ASSUME_NONNULL_END
