/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MMParameterData.h"
#import <FxPlug/FxPlugSDK.h>

@interface KKDataBlob () <FxCustomParameterInterpolation_v2>
@end

@implementation KKDataBlob

+ (BOOL)supportsSecureCoding {
  return YES;
}

+ (instancetype)blobWithData:(NSData *)data {
  KKDataBlob *b = [[KKDataBlob alloc] init];
  b->_data = [data copy] ?: [NSData data];
  return b;
}

+ (instancetype)blobWithString:(NSString *)string {
  return [self blobWithData:[string dataUsingEncoding:NSUTF8StringEncoding]];
}

- (instancetype)init {
  if ((self = [super init]))
    _data = [NSData data];
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  if ((self = [super init])) {
    NSData *d = [coder decodeObjectOfClass:[NSData class] forKey:@"data"];
    _data = [d copy] ?: [NSData data];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeObject:_data forKey:@"data"];
}

- (id)copyWithZone:(NSZone *)zone {
  return [KKDataBlob blobWithData:_data];
}

- (NSString *)stringValue {
  if (_data.length == 0)
    return @"";
  NSString *s = [[NSString alloc] initWithData:_data
                                      encoding:NSUTF8StringEncoding];
  return s ?: @"";
}

- (BOOL)isEqual:(id)other {
  if (other == self)
    return YES;
  if (![other isKindOfClass:[KKDataBlob class]])
    return NO;
  return [_data isEqualToData:((KKDataBlob *)other)->_data];
}

- (NSUInteger)hash {
  return _data.hash;
}

- (NSObject<NSSecureCoding, NSCopying> *)
    interpolateBetween:(NSObject<NSSecureCoding, NSCopying> *)rightValue
            withWeight:(float)weight {
  return weight < 0.5f ? (id)self : rightValue;
}

@end
