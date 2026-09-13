/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMPoseTiming.h"
#import <math.h>
#include <stdint.h>
#include <limits.h>
@implementation MMPoseTiming
+ (BOOL)supportsSecureCoding {
  return YES;
}
- (instancetype)init {
  return [self initWithDuration:1.2 available:NO amount:1 speed:1];
}
- (instancetype)initWithDuration:(double)d
                       available:(BOOL)a
                          amount:(double)m
                           speed:(double)s {
  if (!isfinite(d) || d < 0 || !isfinite(m) || m < 0 || !isfinite(s) || s <= 0)
    return nil;
  if ((self = [super init])) {
    _linkID = @"";
    _duration = d;
    _available = a;
    _amount = m;
    _speed = s;
    _motionSeed = 0;
    _motionLinked = YES;
    _motionComponentMask = UINT32_MAX;
  }
  return self;
}
- (MMPoseTiming *)timingByReplacingLinkID:(NSString *)linkID {
  MMPoseTiming *copy = [[MMPoseTiming alloc] initWithDuration:self.duration
                                                    available:self.available
                                                       amount:self.amount
                                                        speed:self.speed];
  copy->_linkID = [linkID copy] ?: @"";
  copy->_motionSeed = self.motionSeed;
  copy->_motionLinked = self.motionLinked;
  copy->_motionComponentMask = self.motionComponentMask;
  return copy;
}
- (MMPoseTiming *)timingByReplacingMotionSeed:(uint32_t)seed
                                       linked:(BOOL)linked
                                componentMask:(uint32_t)mask {
  MMPoseTiming *copy = [self timingByReplacingLinkID:self.linkID];
  copy->_motionSeed = seed;
  copy->_motionLinked = linked;
  copy->_motionComponentMask = mask;
  return copy;
}
- (MMPoseTiming *)timingByCopyingMotionOptionsFrom:(MMPoseTiming *)other {
  if (![other isKindOfClass:MMPoseTiming.class]) return self;
  return [self timingByReplacingMotionSeed:other.motionSeed
                                    linked:other.motionLinked
                             componentMask:other.motionComponentMask];
}
- (instancetype)initWithCoder:(NSCoder *)c {
  self = [self initWithDuration:[c decodeDoubleForKey:@"duration"]
                      available:[c decodeBoolForKey:@"available"]
                         amount:[c decodeDoubleForKey:@"amount"]
                          speed:[c decodeDoubleForKey:@"speed"]];
  if (self && [c containsValueForKey:@"linkID"]) {
    NSString *link = [c decodeObjectOfClass:NSString.class forKey:@"linkID"];
    if (!link)
      return nil;
    _linkID = link;
  }
  if (self) {
    BOOL hasSeed = [c containsValueForKey:@"motionSeed"];
    BOOL hasLinked = [c containsValueForKey:@"motionLinked"];
    BOOL hasMask = [c containsValueForKey:@"motionComponentMask"];
    if (hasSeed != hasLinked || hasSeed != hasMask) return nil;
    if (hasSeed) {
      int64_t seed = [c decodeInt64ForKey:@"motionSeed"];
      int64_t mask = [c decodeInt64ForKey:@"motionComponentMask"];
      if (seed < 0 || mask < 0 || (uint64_t)seed > UINT32_MAX ||
          (uint64_t)mask > UINT32_MAX) return nil;
      _motionSeed = (uint32_t)seed;
      _motionLinked = [c decodeBoolForKey:@"motionLinked"];
      _motionComponentMask = (uint32_t)mask;
    } else {
      // Archives predating deterministic motion had independent components.
      _motionSeed = 0;
      _motionLinked = NO;
      _motionComponentMask = UINT32_MAX;
    }
  }
  return self;
}
- (void)encodeWithCoder:(NSCoder *)c {
  [c encodeObject:_linkID forKey:@"linkID"];
  [c encodeDouble:_duration forKey:@"duration"];
  [c encodeBool:_available forKey:@"available"];
  [c encodeDouble:_amount forKey:@"amount"];
  [c encodeDouble:_speed forKey:@"speed"];
  [c encodeInt64:_motionSeed forKey:@"motionSeed"];
  [c encodeBool:_motionLinked forKey:@"motionLinked"];
  [c encodeInt64:_motionComponentMask forKey:@"motionComponentMask"];
}
- (id)copyWithZone:(NSZone *)zone {
  return self;
}
- (BOOL)isEqual:(id)obj {
  if (![obj isKindOfClass:MMPoseTiming.class])
    return NO;
  MMPoseTiming *other = obj;
  return [_linkID isEqualToString:other.linkID] &&
         _duration == other.duration && _available == other.available &&
         _amount == other.amount && _speed == other.speed &&
         _motionSeed == other.motionSeed &&
         _motionLinked == other.motionLinked &&
         _motionComponentMask == other.motionComponentMask;
}
- (NSUInteger)hash {
  return _linkID.hash ^ @(_duration).hash ^ @(_amount).hash ^ @(_speed).hash ^
         _available ^ @(_motionSeed).hash ^ @(_motionLinked).hash ^
         @(_motionComponentMask).hash;
}
@end
