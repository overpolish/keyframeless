/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A full-width read-only label displayed in the inspector for informational
/// custom parameters added via -[KKPlugin addInfoParameterWithName:text:…].
@interface KKInfoParameterView : NSView

- (instancetype)initWithText:(NSString *)text;
- (instancetype)initWithText:(NSString *)text
                       color:(NSColor *)color NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) NSColor *color;
@property(nonatomic, strong, nullable) NSBezierPath *icon;

@end

NS_ASSUME_NONNULL_END
