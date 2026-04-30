/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>
#import <CoreFoundation/CFCGTypes.h>

NS_ASSUME_NONNULL_BEGIN

extern const CGFloat kChevronWidth;
extern const CGFloat kChevronHeight;

@interface KKChevronView : NSView

@property(nonatomic, assign) BOOL isExpanded;
@property(nonatomic, assign) BOOL isInteractive;
@property(nonatomic, copy, nullable) void (^onToggle)(BOOL isExpanded);

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
