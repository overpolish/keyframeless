/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Design-token fonts. Size adapts to host context: systemFontSize in a
/// Workflow Extension, smallSystemFontSize in FxPlug / Motion.
@interface KKFonts : NSObject

/// Light-weight label font used in inspector parameter rows.
+ (NSFont *)inspectorLabelFont;

/// Icon size used in inspector parameter rows.
+ (CGFloat)inspectorIconSize;

@end

NS_ASSUME_NONNULL_END
