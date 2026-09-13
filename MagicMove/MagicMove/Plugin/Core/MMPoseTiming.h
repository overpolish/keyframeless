/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
// Immutable per-key settings. Duration belongs to IN; motion amount/speed to
// OUT.
@interface MMPoseTiming : NSObject <NSSecureCoding, NSCopying>
@property(nonatomic, readonly, copy) NSString *linkID;
- (MMPoseTiming *)timingByReplacingLinkID:(NSString *)linkID;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) double amount;
@property(nonatomic, readonly) double speed;
- (instancetype)initWithDuration:(double)duration
                       available:(BOOL)available
                          amount:(double)amount
                           speed:(double)speed;
@end
