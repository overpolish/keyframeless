/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKCheckboxView : NSView

@property(nonatomic, assign) BOOL isChecked;
@property(nonatomic, copy, nullable) void (^onToggle)(BOOL isChecked);

- (instancetype)initWithFrame:(NSRect)frameRect;

@end

NS_ASSUME_NONNULL_END
