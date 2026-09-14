/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared popover title row: an SF-symbol icon + a title (and optional smaller,
/// subscript-style detail such as a time), both dimmed well below the
/// full-brightness param labels so the header reads as a quiet section title
/// and the controls stay the focus. Used at the top-left of the motion-blur,
/// constants, keypose, curve and modulation popovers.
@interface KKPopoverHeaderView : NSView

- (instancetype)initWithTitle:(NSString *)title
                   symbolName:(nullable NSString *)symbolName;
- (instancetype)initWithTitle:(NSString *)title
                       detail:(nullable NSString *)detail
                   symbolName:(nullable NSString *)symbolName;
/// Designated - `icon` is a fully-prepared (template) leading glyph, for
/// callers that need a custom shape rather than an SF symbol.
- (instancetype)initWithTitle:(NSString *)title
                       detail:(nullable NSString *)detail
                         icon:(nullable NSImage *)icon
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Template image for an SF symbol at the standard header icon size, so
/// non-symbol callers can mix symbol + custom glyphs through the icon init.
+ (NSImage *)iconImageForSymbolName:(NSString *)symbolName;

@property(nonatomic, copy) NSString *title;
/// Smaller subscript-style segment after the title (e.g. the keypose time or a
/// curve's time range). Live-updatable. nil hides it.
@property(nonatomic, copy, nullable) NSString *detail;

/// Optional trailing accessory glyph after the detail (e.g. a "link" chain to
/// flag a linked keypose). Pass nil to hide it.
- (void)setTrailingSymbolName:(nullable NSString *)symbolName;

/// Standard header height, including the icon/title line.
+ (CGFloat)height;

@end

NS_ASSUME_NONNULL_END
