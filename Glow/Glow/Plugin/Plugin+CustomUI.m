/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKMarkup.h>
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
    [KKAnimatableProperty
        propertyWithLabel:@"Radius"
                     inID:kParamInRadius
                   holdID:kParamHoldRadius
                    outID:kParamOutRadius
                 valueIDs:@[ @(kParamRadiusX), @(kParamRadiusY) ]],
    [KKAnimatableProperty propertyWithLabel:@"Intensity"
                                       inID:kParamInIntensity
                                     holdID:kParamHoldIntensity
                                      outID:kParamOutIntensity
                                    valueID:kParamIntensity],
    [KKAnimatableProperty propertyWithLabel:@"Falloff"
                                       inID:kParamInFalloff
                                     holdID:kParamHoldFalloff
                                      outID:kParamOutFalloff
                                    valueID:kParamFalloff],
    [KKAnimatableProperty propertyWithLabel:@"Noise"
                                       inID:kParamInNoise
                                     holdID:kParamHoldNoise
                                      outID:kParamOutNoise
                                    valueID:kParamNoise],
    [KKAnimatableProperty
        propertyWithLabel:@"Offset"
                     inID:kParamInOffset
                   holdID:kParamHoldOffset
                    outID:kParamOutOffset
                 valueIDs:@[ @(kParamOffsetX), @(kParamOffsetY) ]],
    [KKAnimatableProperty propertyWithLabel:@"Color"
                                       inID:kParamInColor
                                     holdID:kParamHoldColor
                                      outID:kParamOutColor],
    [KKAnimatableProperty propertyWithLabel:@"N. Offset"
                                       inID:kParamInNoiseOffset
                                     holdID:kParamHoldNoiseOffset
                                      outID:kParamOutNoiseOffset
                                    valueID:kParamNoiseOffset],
  ];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInfoUsage) {
    NSAttributedString *text = [KKMarkup
        attributedStringFromMarkup:
            @"Use on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound Clip "
            @"<kbd>⌥ G</kbd>"];
    KKAlertView *alert = [[KKAlertView alloc] initWithAttributedText:text];
    alert.icon = [NSImage imageWithSystemSymbolName:@"info.circle"
                           accessibilityDescription:nil];
    return alert;
  }

  if (parameterID == kParamNoiseGroup)
    return [self
        createGroupHeaderWithTitle:@"Noise"
                              icon:[NSImage
                                       imageWithSystemSymbolName:
                                           @"circle.bottomrighthalf.pattern"
                                           @".checkered"
                                        accessibilityDescription:nil]
                       parameterID:parameterID
                   expandedParamID:kParamNoiseExpanded];

  if (parameterID == kParamOffsetGroup)
    return [self
        createGroupHeaderWithTitle:@"Offset"
                              icon:[NSImage
                                       imageWithSystemSymbolName:
                                           @"arrow.down.left.arrow.up.right"
                                           @".circle"
                                        accessibilityDescription:nil]
                       parameterID:parameterID
                   expandedParamID:kParamOffsetExpanded];

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
