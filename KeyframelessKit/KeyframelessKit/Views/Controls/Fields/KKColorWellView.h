/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKColorWellView : NSView

@property(nonatomic, strong) NSColor *color;
@property(nonatomic, copy, nullable) void (^onColorChanged)(NSColor *color);

@end

NS_ASSUME_NONNULL_END
