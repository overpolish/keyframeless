/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKLabelView : NSView

@property(nonatomic, strong, nullable) NSImage *icon;

- (instancetype)initWithText:(NSString *)text;
- (instancetype)initWithText:(NSString *)text icon:(nullable NSImage *)icon;

@end

NS_ASSUME_NONNULL_END
