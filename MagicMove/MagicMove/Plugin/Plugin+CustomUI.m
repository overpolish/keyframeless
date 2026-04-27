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
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *magicMove = [KKHelpSection
      sectionWithTitle:@"Magic Move"
             tipMarkup:@[
               (@"Create a Compound Clip <kbd>⌥ G</kbd> before applying to "
                @"avoid clipping"),
               (@"<symbol squareshape.fill color=white /> toggles scale "
                @"between 0\% and 100\%"),
               (@"<symbol circle.fill color=white /> toggles opacity "
                @"between 0\% and 100\%"),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag"
                               descMarkup:@"Constrain motion to X or Y axis"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + drag"
                               descMarkup:@"Disable snapping while dragging"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd>"
                               descMarkup:@"Show X and Y rotation rings"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + scale"
                               descMarkup:@"Lock scaling to X or Y axis"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"Double-click scale ring"
                               descMarkup:@"Reset scale to 1:1 ratio"],
             ]];
  return @[ magicMove ];
}

@end
