/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKPillToggleRowView : NSView

@property(nonatomic, copy) NSArray<NSNumber *> *states;
@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger index, BOOL isOn);

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels;
- (instancetype)initWithIcons:(NSArray<NSImage *> *)icons;

- (void)setState:(BOOL)on atIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
