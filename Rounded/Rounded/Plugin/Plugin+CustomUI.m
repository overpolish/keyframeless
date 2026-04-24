/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>

@implementation RoundedPlugin (CustomUI)

- (NSArray<KKAnimatableProperty *> *)animatableProperties {
  return @[
    [KKAnimatableProperty propertyWithLabel:@"Radius"
                                       inID:kParamInRadius
                                     holdID:kParamHoldRadius
                                      outID:kParamOutRadius
                                    valueID:kParamRadius],
    [KKAnimatableProperty propertyWithLabel:@"Crop"
                                       inID:kParamInCrop
                                     holdID:kParamHoldCrop
                                      outID:kParamOutCrop
                                   valueIDs:@[
                                     @(kParamCropTop), @(kParamCropBottom),
                                     @(kParamCropLeft), @(kParamCropRight)
                                   ]],
  ];
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return [NSSet setWithObjects:@"Radius", @"Crop", nil];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamCropGroup) {
    return [self
        createGroupHeaderWithTitle:@"Crop"
                              icon:[NSImage imageWithSystemSymbolName:@"crop"
                                             accessibilityDescription:nil]
                       parameterID:parameterID
                   expandedParamID:kParamCropExpanded];
  }

  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

@end
