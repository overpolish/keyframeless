/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKAnimatableProperty.h"

@implementation KKAnimatableProperty

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID {
  return [self propertyWithLabel:label
                            inID:inID
                          holdID:holdID
                           outID:outID
                        valueIDs:@[]];
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
                        valueIDs:@[ @(valueID) ]];
}

+ (instancetype)propertyWithLabel:(NSString *)label
                             inID:(UInt32)inID
                           holdID:(UInt32)holdID
                            outID:(UInt32)outID
                         valueIDs:(NSArray<NSNumber *> *)valueIDs {
  KKAnimatableProperty *p = [[KKAnimatableProperty alloc] initInternal];
  p->_label = [label copy];
  p->_inParamID = inID;
  p->_holdParamID = holdID;
  p->_outParamID = outID;
  p->_valueParamIDs = [valueIDs copy];
  return p;
}

- (instancetype)initInternal {
  return [super init];
}

@end
