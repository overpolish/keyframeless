/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Base class for radio-style pill selectors. Subclasses override
/// -pillCount and -imageForIndex:active: to provide their own previews.
@interface KKPillStyleView : NSView

@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;

/// Number of pills. Subclasses must override.
- (NSInteger)pillCount;

/// Image for a given pill index. Subclasses must override.
- (NSImage *)imageForIndex:(NSInteger)index active:(BOOL)active;

/// Call when a property affecting images changes (e.g. isStart on markers).
- (void)rebuildImages;

@end

NS_ASSUME_NONNULL_END
