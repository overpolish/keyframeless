/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>
#import <CoreFoundation/CFCGTypes.h>

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kChevronWidth = 7.5;
static const CGFloat kChevronHeight = 9.0;

@interface KKChevronView : NSView

@property(nonatomic, assign) BOOL isExpanded;
@property(nonatomic, copy, nullable) void (^onToggle)(BOOL isExpanded);

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
