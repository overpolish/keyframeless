/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKDataBlob.h"
#import <FxPlug/FxPlugSDK.h>

// Private declaration of the FxCustom interpolation conformance — kept out
// of the public header so the framework module doesn't transitively import
// FxPlug's non-modular headers.
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

NSString *_Nullable KKReadCustomParamString(
    id<FxParameterRetrievalAPI_v6> getAPI, UInt32 parameterID) {
  if (!getAPI)
    return nil;
  NSObject<NSSecureCoding, NSCopying> *raw = nil;
  [getAPI getCustomParameterValue:&raw
                    fromParameter:parameterID
                           atTime:kCMTimeZero];
  if (![raw isKindOfClass:[KKDataBlob class]])
    return nil;
  NSString *s = [(KKDataBlob *)raw stringValue];
  return s.length ? s : nil;
}

void KKWriteCustomParamString(id<FxParameterSettingAPI_v5> setAPI,
                              NSString *string, UInt32 parameterID) {
  if (!setAPI)
    return;
  KKDataBlob *blob = [KKDataBlob blobWithString:string ?: @""];
  [setAPI setCustomParameterValue:blob
                      toParameter:parameterID
                           atTime:kCMTimeZero];
}
