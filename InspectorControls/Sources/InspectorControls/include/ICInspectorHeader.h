/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// AppKit-only inspector chrome with a leading logo and trailing controls.
@interface ICInspectorHeader : NSView
- (instancetype)initWithLogo:(nullable NSImage *)logo;
- (instancetype)initWithLogo:(nullable NSImage *)logo
             accessoryButtons:(nullable NSArray<NSButton *> *)buttons
                 menuProvider:(nullable NSMenu *(^)(void))menuProvider;

@property(nonatomic, copy, nullable) NSArray<NSButton *> *accessoryButtons;
@property(nonatomic, copy, nullable) NSMenu *(^menuProvider)(void);
/// The trailing settings button, exposed for integration and standalone tests.
@property(nonatomic, readonly) NSButton *settingsButton;
@end

NS_ASSUME_NONNULL_END
