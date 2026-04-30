/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKAnimatableProperty.h"
#import "../Math/KKGradientSampling.h"
#import "KKGradientBarView.h"
#import <FxPlug/FxPlugSDK.h>

static NSUInteger KKKindFixedValueCount(KKAnimatableParamKind kind) {
  switch (kind) {
  case KKAnimatableParamKindColor:
    return 3;
  case KKAnimatableParamKindPoint:
    return 2;
  case KKAnimatableParamKindGradient:
    return 0; // variable (5 * N)
  case KKAnimatableParamKindBool:
    return 1;
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

+ (instancetype)propertyWithLabel:(NSString *)label valueID:(UInt32)valueID {
  return [self propertyWithLabel:label inID:0 holdID:0 outID:0 valueID:valueID];
}

+ (instancetype)propertyWithLabel:(NSString *)label
                          valueID:(UInt32)valueID
                             kind:(KKAnimatableParamKind)kind {
  return [self propertyWithLabel:label
                            inID:0
                          holdID:0
                           outID:0
                         valueID:valueID
                            kind:kind];
}

+ (instancetype)propertyWithLabel:(NSString *)label
                         valueIDs:(NSArray<NSNumber *> *)valueIDs {
  return [self propertyWithLabel:label
                            inID:0
                          holdID:0
                           outID:0
                        valueIDs:valueIDs];
}

+ (instancetype)propertyWithLabel:(NSString *)label
                         valueIDs:(NSArray<NSNumber *> *)valueIDs
                            kinds:(NSArray<NSNumber *> *)kinds {
  return [self propertyWithLabel:label
                            inID:0
                          holdID:0
                           outID:0
                        valueIDs:valueIDs
                           kinds:kinds];
}

- (instancetype)initInternal {
  return [super init];
}

- (NSUInteger)valueCount {
  NSUInteger n = 0;
  for (NSNumber *k in _valueParamKinds) {
    KKAnimatableParamKind kind = (KKAnimatableParamKind)k.integerValue;
    NSUInteger fixed = KKKindFixedValueCount(kind);
    // Gradient is variable; caller should not rely on valueCount for it.
    if (fixed > 0)
      n += fixed;
  }
  return n;
}

- (NSArray<NSNumber *> *)readValuesWithGetAPI:
                             (id<FxParameterRetrievalAPI_v6>)getAPI
                                       atTime:(CMTime)time {
  if (!getAPI)
    return nil;
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
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
    case KKAnimatableParamKindGradient: {
      NSString *json = nil;
      [getAPI getStringParameterValue:&json fromParameter:pid];
      NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
      if (stops)
        [out addObjectsFromArray:KKGradientFlatFromStops(stops)];
      break;
    }
    case KKAnimatableParamKindPoint: {
      double x = 0, y = 0;
      [getAPI getXValue:&x YValue:&y fromParameter:pid atTime:time];
      [out addObject:@(x)];
      [out addObject:@(y)];
      break;
    }
    case KKAnimatableParamKindBool: {
      BOOL b = NO;
      [getAPI getBoolValue:&b fromParameter:pid atTime:time];
      [out addObject:@(b ? 1.0 : 0.0)];
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
    switch (kind) {
    case KKAnimatableParamKindColor: {
      if (cursor + 3 > values.count)
        return;
      [setAPI setRedValue:values[cursor].doubleValue
               greenValue:values[cursor + 1].doubleValue
                blueValue:values[cursor + 2].doubleValue
              toParameter:pid
                   atTime:time];
      cursor += 3;
      break;
    }
    case KKAnimatableParamKindPoint: {
      if (cursor + 2 > values.count)
        return;
      [setAPI setXValue:values[cursor].doubleValue
                 YValue:values[cursor + 1].doubleValue
            toParameter:pid
                 atTime:time];
      cursor += 2;
      break;
    }
    case KKAnimatableParamKindBool: {
      if (cursor + 1 > values.count)
        return;
      BOOL b = values[cursor].doubleValue >= 0.5;
      [setAPI setBoolValue:b toParameter:pid atTime:time];
      cursor += 1;
      break;
    }
    case KKAnimatableParamKindGradient: {
      // Gradient consumes ALL remaining values — it must be the only kind
      // in the property's valueIDs list for this reason.
      NSArray<NSNumber *> *flat =
          (cursor == 0)
              ? values
              : [values subarrayWithRange:NSMakeRange(cursor,
                                                      values.count - cursor)];
      NSArray<KKGradientStop *> *stops = KKGradientStopsFromFlat(flat);
      NSString *json = KKGradientJSONFromStops(stops ?: @[]);
      if (json)
        [setAPI setStringParameterValue:json toParameter:pid];
      cursor = values.count;
      break;
    }
    case KKAnimatableParamKindFloat:
    default: {
      if (cursor + 1 > values.count)
        return;
      [setAPI setFloatValue:values[cursor].doubleValue
                toParameter:pid
                     atTime:time];
      cursor += 1;
      break;
    }
    }
  }
}

@end
