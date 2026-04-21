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
/// Native parameter IDs whose sliders show the absolute values for this
/// property in multi-stage mode. Empty array = no sync.
/// Each entry maps 1:1 to a value in the segment's values array.
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *valueParamIDs;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                          valueID:(UInt32)valueID;

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                         valueIDs:(NSArray<NSNumber *> *)valueIDs;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
