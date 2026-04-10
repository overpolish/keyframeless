/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <objc/message.h>

@interface KKPlugin (TimingGraph)
- (void)timingGraphApplyState;
@end

@implementation GlowPlugin (CustomUI)

- (NSArray<KKTimingSlot *> *)timingSlotsForSection:(NSInteger)section {
  return @[];
}

- (NSArray<KKAnimatableProperty *> *)animatableProperties {
  return @[
    [KKAnimatableProperty propertyWithLabel:@"Radius"
                                       inID:kParamInRadius
                                     holdID:kParamHoldRadius
                                      outID:kParamOutRadius],
    [KKAnimatableProperty propertyWithLabel:@"Intensity"
                                       inID:kParamInIntensity
                                     holdID:kParamHoldIntensity
                                      outID:kParamOutIntensity],
    [KKAnimatableProperty propertyWithLabel:@"Falloff"
                                       inID:kParamInFalloff
                                     holdID:kParamHoldFalloff
                                      outID:kParamOutFalloff],
    [KKAnimatableProperty propertyWithLabel:@"Noise"
                                       inID:kParamInNoise
                                     holdID:kParamHoldNoise
                                      outID:kParamOutNoise],
    [KKAnimatableProperty propertyWithLabel:@"Offset"
                                       inID:kParamInOffset
                                     holdID:kParamHoldOffset
                                      outID:kParamOutOffset],
    [KKAnimatableProperty propertyWithLabel:@"Color"
                                       inID:kParamInColor
                                     holdID:kParamHoldColor
                                      outID:kParamOutColor],
  ];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamOffsetGroup)
    return [self createGroupHeaderWithTitle:@"Offset"
                                       icon:nil
                                parameterID:parameterID
                            expandedParamID:kParamOffsetExpanded];

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
