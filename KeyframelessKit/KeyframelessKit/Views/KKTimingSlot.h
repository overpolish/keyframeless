/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>

@protocol FxParameterRetrievalAPI_v6;

NS_ASSUME_NONNULL_BEGIN

typedef void (^KKTimingSlotApplyState)(id<FxParameterRetrievalAPI_v6> paramAPI,
                                       CMTime time);

@interface KKTimingSlot : NSObject

@property(nonatomic, strong, readonly) NSView *view;
@property(nonatomic, readonly) CGFloat height;
@property(nonatomic, copy, readonly) KKTimingSlotApplyState applyState;

+ (instancetype)slotWithView:(NSView *)view
                      height:(CGFloat)height
                  applyState:(KKTimingSlotApplyState)applyState;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
