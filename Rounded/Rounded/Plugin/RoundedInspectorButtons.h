/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface _RoundedLoopButton : NSView
@property(nonatomic) BOOL on;
@property(nonatomic, copy, nullable) void (^onToggled)(BOOL isOn);
@end

@interface _RoundedConstantsButton : NSView
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

NS_ASSUME_NONNULL_END
