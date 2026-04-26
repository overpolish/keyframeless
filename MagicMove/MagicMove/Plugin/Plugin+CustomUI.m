/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/NSView.h>
#import <KeyframelessKit/KeyframelessKit.h>

@implementation MagicMovePlugin (CustomUI)

- (NSArray<KKAnimatableProperty *> *)animatableProperties {
  return @[
    [KKAnimatableProperty
        propertyWithLabel:@"Position"
                 valueIDs:@[ @(kParamPoint), @(kParamRotateWithMotion) ]
                    kinds:@[
                      @(KKAnimatableParamKindPoint),
                      @(KKAnimatableParamKindBool)
                    ]],
    [KKAnimatableProperty
        propertyWithLabel:@"Scale"
                 valueIDs:@[ @(kParamScale), @(kParamScaleY) ]],
    [KKAnimatableProperty propertyWithLabel:@"Rot Z" valueID:kParamRotation],
    [KKAnimatableProperty propertyWithLabel:@"Rot X" valueID:kParamRotationX],
    [KKAnimatableProperty propertyWithLabel:@"Rot Y" valueID:kParamRotationY],
    [KKAnimatableProperty propertyWithLabel:@"Opacity" valueID:kParamOpacity],
  ];
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return [NSSet setWithObjects:@"Position", @"Scale", @"Rot Z", @"Rot X",
                               @"Rot Y", @"Opacity", nil];
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSCDefaultOff {
  return [NSSet setWithObjects:@"Rot X", @"Rot Y", nil];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInfoCompound) {
    NSArray<NSAttributedString *> *pages = @[
      [KKMarkup attributedStringFromMarkup:
                    @"Create a Compound Clip <kbd>⌥ G</kbd> before applying "
                    @"to avoid clipping"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>Shift</kbd> while dragging to constrain to "
                    @"X or Y axis"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>⌃</kbd> while dragging to disable snapping"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>⌥</kbd> to show X and Y rotation rings"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>Shift</kbd> while scaling to lock to X or Y"],
      [KKMarkup attributedStringFromMarkup:
                    @"Double-click the scale ring to reset to 1:1 ratio"],
      [KKMarkup attributedStringFromMarkup:
                    @"<symbol squareshape.fill color=white /> toggles scale "
                    @"between 0\% and 100\%"],
      [KKMarkup attributedStringFromMarkup:
                    @"<symbol circle.fill color=white /> toggles opacity "
                    @"between 0\% and 100\%"],
    ];
    KKAlertView *infoAlert =
        [[KKAlertView alloc] initWithAttributedText:pages.firstObject];
    infoAlert.icon = [NSImage imageWithSystemSymbolName:@"info.circle"
                               accessibilityDescription:nil];
    infoAlert.attributedPages = pages;

    KKAlertStackView *stack = [[KKAlertStackView alloc]
        initWithDefaultAlert:infoAlert
                  apiManager:self.apiManager
          persistParameterID:kParamAlertStackSelected];

    self.alertStackView = stack;
    return stack;
  }

  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

@end
