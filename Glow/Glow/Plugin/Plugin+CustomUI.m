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
                 valueIDs:@[ @(kParamRadiusX), @(kParamRadiusY) ]],
    [KKAnimatableProperty propertyWithLabel:@"Intensity"
                                    valueID:kParamIntensity],
    [KKAnimatableProperty propertyWithLabel:@"Falloff" valueID:kParamFalloff],
    [KKAnimatableProperty propertyWithLabel:@"Noise" valueID:kParamNoise],
    [KKAnimatableProperty propertyWithLabel:@"Position"
                                    valueID:kParamPosition
                                       kind:KKAnimatableParamKindPoint],
    [KKAnimatableProperty propertyWithLabel:@"Color"
                                    valueID:kKKParamColorSolid
                                       kind:KKAnimatableParamKindColor],
    [KKAnimatableProperty propertyWithLabel:@"Gradient"
                                    valueID:kKKParamGradientData
                                       kind:KKAnimatableParamKindGradient],
    [KKAnimatableProperty propertyWithLabel:@"N. Offset"
                                    valueID:kParamNoiseOffset],
  ];
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return [NSSet setWithObjects:@"Radius", @"Position", nil];
}

- (NSSet<NSString *> *)hiddenAnimatablePropertyLabels {
  KKColorMode mode = [self colorModeAtTime:kCMTimeZero];
  NSMutableSet<NSString *> *hidden = [NSMutableSet set];
  // Color lane only makes sense in Solid mode; Gradient lane only in
  // Gradient mode. Dynamic mode hides both.
  if (mode != KKColorModeSolid)
    [hidden addObject:@"Color"];
  if (mode != KKColorModeGradient)
    [hidden addObject:@"Gradient"];
  return hidden;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
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

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *glow = [KKHelpSection
      sectionWithTitle:@"Glow"
             tipMarkup:@[
               (@"<accent>Radius X / Y</accent> control how far the glow "
                @"spreads. Hold <kbd>⌘</kbd> while dragging inspector slider "
                @"to keep "
                @"X and Y in sync."),
               (@"<accent>Position</accent> moves where the glow appears - "
                @"move it via the "
                @"<symbol arcade.stick.console.fill /> on-screen control."),
               (@"<accent>Intensity</accent> is overall brightness; "
                @"<accent>Falloff</accent> shapes how sharply it fades to "
                @"the edge; <accent>Threshold</accent> makes the underlying "
                @"objects brighter."),
               (@"<accent>Color</accent> mode tints the glow: supports "
                @"Dynamic, Solid, and Gradient."),
               (@"The <accent>Noise</accent> group adds a flickering, "
                @"organic shimmer. <accent>Amount</accent> controls "
                @"strength; <accent>Speed</accent> animates it over time; "
                @"<accent>Offset</accent> shifts the noise field "
                @"(animatable for parallax-like motion)."),
             ]
             shortcuts:nil];
  glow.icon = [NSImage imageWithSystemSymbolName:@"app.background.dotted"
                        accessibilityDescription:nil];
  return @[ glow ];
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeAdjustmentOrCompound;
}

@end
