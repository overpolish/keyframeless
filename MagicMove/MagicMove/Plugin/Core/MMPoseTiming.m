/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMPoseTiming.h"
#import <math.h>
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
  }
  return self;
}
- (MMPoseTiming *)timingByReplacingLinkID:(NSString *)linkID {
  MMPoseTiming *copy = [[MMPoseTiming alloc] initWithDuration:self.duration
                                                    available:self.available
                                                       amount:self.amount
                                                        speed:self.speed];
  copy->_linkID = [linkID copy] ?: @"";
  return copy;
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
  return self;
}
- (void)encodeWithCoder:(NSCoder *)c {
  [c encodeObject:_linkID forKey:@"linkID"];
  [c encodeDouble:_duration forKey:@"duration"];
  [c encodeBool:_available forKey:@"available"];
  [c encodeDouble:_amount forKey:@"amount"];
  [c encodeDouble:_speed forKey:@"speed"];
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
         _amount == other.amount && _speed == other.speed;
}
- (NSUInteger)hash {
  return _linkID.hash ^ @(_duration).hash ^ @(_amount).hash ^ @(_speed).hash ^
         _available;
}
@end
