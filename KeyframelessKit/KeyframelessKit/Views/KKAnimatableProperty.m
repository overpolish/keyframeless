/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKAnimatableProperty.h"
#import <FxPlug/FxPlugSDK.h>

static NSUInteger KKKindValueCount(KKAnimatableParamKind kind) {
  switch (kind) {
  case KKAnimatableParamKindColor:
    return 3;
  case KKAnimatableParamKindFloat:
  default:
    return 1;
  }
}

@implementation KKAnimatableProperty

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID {
  return [self propertyWithLabel:label
                            inID:inID
                          holdID:holdID
                           outID:outID
                        valueIDs:@[]
                           kinds:@[]];
}

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                          valueID:(UInt32)valueID {
  return [self propertyWithLabel:label
                            inID:inID
                          holdID:holdID
                           outID:outID
                        valueIDs:@[ @(valueID) ]
                           kinds:@[ @(KKAnimatableParamKindFloat) ]];
}

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                         valueIDs:(NSArray<NSNumber *> *)valueIDs {
  NSMutableArray<NSNumber *> *kinds =
      [NSMutableArray arrayWithCapacity:valueIDs.count];
  for (NSUInteger i = 0; i < valueIDs.count; i++)
    [kinds addObject:@(KKAnimatableParamKindFloat)];
  return [self propertyWithLabel:label
                            inID:inID
                          holdID:holdID
                           outID:outID
                        valueIDs:valueIDs
                           kinds:kinds];
}

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                          valueID:(UInt32)valueID
                             kind:(KKAnimatableParamKind)kind {
  return [self propertyWithLabel:label
                            inID:inID
                          holdID:holdID
                           outID:outID
                        valueIDs:@[ @(valueID) ]
                           kinds:@[ @(kind) ]];
}

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                         valueIDs:(NSArray<NSNumber *> *)valueIDs
                            kinds:(NSArray<NSNumber *> *)kinds {
  NSAssert(valueIDs.count == kinds.count,
           @"valueIDs/kinds length mismatch for %@", label);
  KKAnimatableProperty *p = [[KKAnimatableProperty alloc] initInternal];
  p->_label = [label copy];
  p->_inParamID = inID;
  p->_holdParamID = holdID;
  p->_outParamID = outID;
  p->_valueParamIDs = [valueIDs copy];
  p->_valueParamKinds = [kinds copy];
  return p;
}

- (instancetype)initInternal {
  return [super init];
}

- (NSUInteger)valueCount {
  NSUInteger n = 0;
  for (NSNumber *k in _valueParamKinds)
    n += KKKindValueCount((KKAnimatableParamKind)k.integerValue);
  return n;
}

- (NSArray<NSNumber *> *)readValuesWithGetAPI:
                             (id<FxParameterRetrievalAPI_v6>)getAPI
                                       atTime:(CMTime)time {
  if (!getAPI)
    return nil;
  NSMutableArray<NSNumber *> *out =
      [NSMutableArray arrayWithCapacity:self.valueCount];
  for (NSUInteger i = 0; i < _valueParamIDs.count; i++) {
    UInt32 pid = _valueParamIDs[i].unsignedIntValue;
    KKAnimatableParamKind kind =
        (KKAnimatableParamKind)_valueParamKinds[i].integerValue;
    switch (kind) {
    case KKAnimatableParamKindColor: {
      double r = 0, g = 0, b = 0;
      [getAPI getRedValue:&r
               greenValue:&g
                blueValue:&b
            fromParameter:pid
                   atTime:time];
      [out addObject:@(r)];
      [out addObject:@(g)];
      [out addObject:@(b)];
      break;
    }
    case KKAnimatableParamKindFloat:
    default: {
      double v = 0;
      [getAPI getFloatValue:&v fromParameter:pid atTime:time];
      [out addObject:@(v)];
      break;
    }
    }
  }
  return out;
}

- (void)writeValues:(NSArray<NSNumber *> *)values
         withSetAPI:(id<FxParameterSettingAPI_v5>)setAPI
             atTime:(CMTime)time {
  if (!setAPI || !values.count)
    return;
  NSUInteger cursor = 0;
  for (NSUInteger i = 0; i < _valueParamIDs.count; i++) {
    UInt32 pid = _valueParamIDs[i].unsignedIntValue;
    KKAnimatableParamKind kind =
        (KKAnimatableParamKind)_valueParamKinds[i].integerValue;
    NSUInteger need = KKKindValueCount(kind);
    if (cursor + need > values.count)
      return;
    switch (kind) {
    case KKAnimatableParamKindColor:
      [setAPI setRedValue:values[cursor].doubleValue
               greenValue:values[cursor + 1].doubleValue
                blueValue:values[cursor + 2].doubleValue
              toParameter:pid
                   atTime:time];
      break;
    case KKAnimatableParamKindFloat:
    default:
      [setAPI setFloatValue:values[cursor].doubleValue
                toParameter:pid
                     atTime:time];
      break;
    }
    cursor += need;
  }
}

@end
