/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One row in a help section's keyboard-shortcuts table. Both `keysMarkup`
/// and `descMarkup` are rendered through KKMarkup, so callers can embed
/// `<kbd>` badges or inline SF Symbols.
@interface KKHelpShortcut : NSObject

+ (instancetype)shortcutWithKeysMarkup:(NSString *)keysMarkup
                            descMarkup:(NSString *)descMarkup;

@property(nonatomic, readonly) NSAttributedString *keys;
@property(nonatomic, readonly) NSAttributedString *desc;

@end

/// A single section of help content. Renders as: title, optional bullet
/// list of tips, optional 2-column shortcuts table. Plugins return an
/// array of these from `-[KKPlugin helpSections]`.
@interface KKHelpSection : NSObject

+ (instancetype)sectionWithTitle:(NSString *)title
                       tipMarkup:(nullable NSArray<NSString *> *)tipMarkup
                       shortcuts:
                           (nullable NSArray<KKHelpShortcut *> *)shortcuts;

@property(nonatomic, readonly) NSString *title;
@property(nonatomic, readonly) NSArray<NSAttributedString *> *tips;
@property(nonatomic, readonly) NSArray<KKHelpShortcut *> *shortcuts;

/// Optional SF Symbol or other image rendered to the left of the title.
@property(nonatomic, nullable, strong) NSImage *icon;

@end

NS_ASSUME_NONNULL_END
