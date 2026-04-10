/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKAnimatableProperty : NSObject

@property(nonatomic, copy, readonly) NSString *label;
@property(nonatomic, readonly) UInt32 inParamID;
@property(nonatomic, readonly) UInt32 holdParamID;
@property(nonatomic, readonly) UInt32 outParamID;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
