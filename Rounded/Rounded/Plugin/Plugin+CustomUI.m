/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>

@implementation RoundedPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (NSArray<KKAnimatableProperty *> *)animatableProperties {
  return @[
    [KKAnimatableProperty propertyWithLabel:@"Radius" valueID:kParamRadius],
    [KKAnimatableProperty propertyWithLabel:@"Crop"
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

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *rounded = [KKHelpSection
      sectionWithTitle:@"Rounded"
             tipMarkup:@[
               (@"Round the corners of any clip with an animatable "
                @"<accent>Radius</accent>."),
               (@"<accent>Crop</accent> trims each side independently - "
                @"animate it to reveal or hide content over time."),
             ]
             shortcuts:nil];
  rounded.icon = [NSImage imageWithSystemSymbolName:@"square.dotted"
                           accessibilityDescription:nil];
  return @[ rounded ];
}

@end
