/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/NSView.h>
#import <KeyframelessKit/KeyframelessKit.h>

@implementation MagicMovePlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

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
               (@"<accent>Position</accent>, <accent>Scale</accent>, "
                @"<accent>Rotation</accent>, and <accent>Opacity</accent> "
                @"all animate from the clip's natural state to the values "
                @"set here - drive each one on canvas via the "
                @"<symbol arcade.stick.console.fill /> on-screen control."),
               (@"<accent>Anchor Point</accent> sets the pivot rotations "
                @"and scale swing around."),
               (@"Toggle <accent>Rotate with Motion</accent> to align the "
                @"clip's heading with its motion path."),
               (@"<symbol squareshape.fill color=white /> on the canvas "
                @"toggles Scale between 0% and 100%; "
                @"<symbol circle.fill color=white /> on the canvas "
                @"toggles Opacity between 0% and 100%."),
               (@"When the Position lane has multiple segments a bezier "
                @"<accent>path</accent> draws between them on canvas - "
                @"reshape it by dragging anchors or their handles."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag"
                               descMarkup:@"Constrain motion to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + drag"
                                           descMarkup:@"Disable snapping"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd>"
                               descMarkup:@"Reveal X and Y rotation rings"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + scale"
                               descMarkup:@"Lock scale to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"Double-click scale ring"
                                           descMarkup:@"Reset to 1:1"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"Double-click path anchor"
                               descMarkup:@"Toggle between smooth and corner"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"path anchor"
                                           descMarkup:@"Delete the anchor"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"path curve"
                                           descMarkup:@"Insert a new anchor "
                                                      @"at the nearest spot"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag "
                                                      @"handle"
                                           descMarkup:@"Break handle "
                                                      @"symmetry (move "
                                                      @"independently)"],
             ]];
  magicMove.icon =
      [NSImage imageWithSystemSymbolName:@"circle.dotted.and.circle"
                accessibilityDescription:nil];
  return @[ magicMove ];
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeCompound;
}

@end
