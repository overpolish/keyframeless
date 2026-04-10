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
  KKAnimatableProperty *p = [[KKAnimatableProperty alloc] initInternal];
  p->_label = [label copy];
  p->_inParamID = inID;
  p->_holdParamID = holdID;
  p->_outParamID = outID;
  return p;
}

- (instancetype)initInternal {
  return [super init];
}

@end
