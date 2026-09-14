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
/// Fires YES when the shared colour panel is opened from this swatch and NO
/// when it closes. A swatch hosted inside a transient NSPopover uses this to
/// flip the popover to ApplicationDefined while the panel is up, so clicking
/// into the panel (a separate window) doesn't dismiss the popover mid-edit.
@property(nonatomic, copy, nullable) void (^onColorEditingChanged)(BOOL editing)
    ;

@end

NS_ASSUME_NONNULL_END
