/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKHelpSection;

NS_ASSUME_NONNULL_BEGIN

/// Renders an array of `KKHelpSection`s as a documentation-style page:
/// each section has a title, a bullet list of tips, and a 2-column
/// keyboard-shortcuts table. A faded rotated logo sits behind the
/// content in the bottom-left corner.
@interface KKHelpView : NSView

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections;

- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
