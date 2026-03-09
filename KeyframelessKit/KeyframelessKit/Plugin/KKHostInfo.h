/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared store for the FxPlug host bundle identifier.
/// Set once from the principal delegate, then read from anywhere in
/// KeyframelessKit.
@interface KKHostInfo : NSObject

@property(nonatomic, copy, nullable) NSString *hostID;

+ (BOOL)isRunningInFinalCut;
+ (instancetype)shared;

@end

NS_ASSUME_NONNULL_END
