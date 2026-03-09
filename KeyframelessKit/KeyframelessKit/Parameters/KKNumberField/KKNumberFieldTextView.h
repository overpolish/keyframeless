/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class KKNumberField;

@interface KKNumberFieldTextView : NSTextView

@property(nonatomic, weak, nullable) KKNumberField *parentField;

@end

NS_ASSUME_NONNULL_END
