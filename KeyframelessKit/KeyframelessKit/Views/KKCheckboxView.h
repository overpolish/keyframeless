/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
