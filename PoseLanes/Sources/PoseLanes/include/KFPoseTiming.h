/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>
// Immutable per-key settings. Duration belongs to IN; motion amount/speed to
// OUT.
@interface KFPoseTiming : NSObject <NSSecureCoding, NSCopying>
@property(nonatomic, readonly, copy) NSString *linkID;
@property(nonatomic, readonly, copy)
    NSDictionary<NSString *, NSDictionary *> *motionSettings;
- (KFPoseTiming *)timingByReplacingMotionSettings:
    (NSDictionary<NSString *, NSDictionary *> *)settings;
- (KFPoseTiming *)timingByReplacingMotionSeed:(uint32_t)motionSeed
                                       linked:(BOOL)motionLinked
                                componentMask:(uint32_t)motionComponentMask;
- (KFPoseTiming *)timingByCopyingMotionOptionsFrom:(KFPoseTiming *)other;
- (KFPoseTiming *)timingByReplacingLinkID:(NSString *)linkID;
@property(nonatomic, readonly) uint32_t motionSeed;
@property(nonatomic, readonly) BOOL motionLinked;
@property(nonatomic, readonly) uint32_t motionComponentMask;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) double amount;
@property(nonatomic, readonly) double speed;
- (instancetype)initWithDuration:(double)duration
                       available:(BOOL)available
                          amount:(double)amount
                           speed:(double)speed;
@end
