/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../KKLog.h"
#import "../../Views/KKHelpSection.h"
#import "../../Views/KKHelpView.h"
#import "../../Views/KKMarkup.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation KKPlugin (Help)

- (NSArray<KKHelpSection *> *)helpSections {
  return @[];
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeNone;
}

+ (nullable NSString *)_clipWrappingTipForMode:(KKClipWrappingMode)mode {
  switch (mode) {
  case KKClipWrappingModeAdjustmentOrCompound:
    return @"Apply on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound Clip "
           @"<kbd>⌥ G</kbd> to avoid unexpected behavior and clipping.";
  case KKClipWrappingModeCompound:
    return @"Wrap your clip in a Compound Clip <kbd>⌥ G</kbd> before applying "
           @"to avoid the animation being clipped at the edges.";
  case KKClipWrappingModeNone:
    return nil;
  }
}

+ (void)_prependClipWrappingTip:(NSString *)tipMarkup
                      toSection:(KKHelpSection *)section {
  NSAttributedString *wrap = [KKMarkup attributedStringFromMarkup:tipMarkup];
  NSMutableArray<NSAttributedString *> *tips = [NSMutableArray array];
  [tips addObject:wrap];
  [tips addObjectsFromArray:section.tips];
  section.tips = tips;
}

+ (KKHelpSection *)_builtInTimingHelpSection {
  NSArray<NSString *> *tips = @[
    (@"Think in <accent>sections</accent>, not keyframes - each lane is a "
     @"chain of <accent>holds</accent> (locked values) and "
     @"<warn>transitions</warn> (interpolations between adjacent holds)."),
    (@"<symbol arcade.stick.console.fill /> on a lane label toggles that "
     @"lane's on-screen control on the canvas."),
    (@"Click <symbol macwindow.on.rectangle /> on the Timing header to pop "
     @"the sequencer out into its own window for more room."),
    (@"Drag the timeline ruler to scrub the playhead; press "
     @"<kbd>Space</kbd> to play and pause. Toggle "
     @"<symbol repeat color=accent /> on the ruler to loop playback."),
    (@"A transition between two holds with the "
     @"same value won't visibly animate - change one side first."),
    (@"Hover a segment to reveal a <symbol graph.2d /> button. Click it "
     @"to change the easing curve (or hold effect) - or "
     @"<kbd>Shift</kbd> + click to apply the same curve to every selected "
     @"segment in all lane."),
    (@"On a multi-component hold (like Radius X/Y), the edit popover has "
     @"a <accent>Linked</accent> toggle - keeps the components' "
     @"proportions locked through the effect, so X/Y stay aspect-locked "
     @"through a wobble."),
    (@"The pill row above the sequencer filters which lanes are visible."),
  ];

  NSArray<KKHelpShortcut *> *shortcuts = @[
    [KKHelpShortcut shortcutWithKeysMarkup:@"Click lane label"
                                descMarkup:@"Disable / enable that lane's "
                                           @"animation"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click pill"
                                descMarkup:@"Solo a lane (or unsolo when "
                                           @"already the only visible lane)"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"Click"
                                descMarkup:@"Select a segment"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"Double-click"
                                descMarkup:@"Split a segment at the cursor"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"Right-click"
                    descMarkup:@"Convert between <accent>hold</accent> "
                               @"and <warn>transition</warn>"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌘</kbd> + click"
                                descMarkup:@"Delete the segment"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"Drag edge"
                    descMarkup:@"Resize a segment (snaps to other edges, "
                               @"playhead, and ends)"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> while dragging"
                                descMarkup:@"Disable snapping"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag segment"
                                descMarkup:@"Copy this segment's value onto "
                                           @"another segment"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + click"
                                descMarkup:@"Lock / unlock the segment's "
                                           @"duration"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + drag"
                                descMarkup:@"Slide the entire lane in time"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + click"
                                descMarkup:@"Select segments in "
                                           @"every lane"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + double-click"
                                descMarkup:@"Split every lane at this point"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + right-click"
                                descMarkup:@"Toggle hold/transition across "
                                           @"every lane"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag edge"
                    descMarkup:@"Move the matching boundary in every lane"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift ⌘</kbd> + click"
                                descMarkup:@"Delete the segment in every lane"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + <symbol graph.2d />"
                    descMarkup:@"Open curve editor for every lane at once"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"<kbd>Shift ⌃</kbd> + click"
                    descMarkup:@"Toggle duration lock across every lane"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"Pinch"
                                descMarkup:@"Zoom the timeline horizontally"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"Two-finger scroll"
                                descMarkup:@"Pan the timeline horizontally"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Space</kbd>"
                                descMarkup:@"Play / pause (in the popped-out "
                                           @"window)"],
  ];

  KKHelpSection *timing = [KKHelpSection sectionWithTitle:@"Timing"
                                                tipMarkup:tips
                                                shortcuts:shortcuts];
  timing.icon = [NSImage imageWithSystemSymbolName:@"timer"
                          accessibilityDescription:nil];
  return timing;
}

+ (KKHelpSection *)_builtInMotionBlurHelpSection {
  NSArray<NSString *> *tips = @[
    (@"<accent>Length</accent> is the shutter angle: 0% freezes each "
     @"frame, 50% (default) is a 180° shutter (half a frame of trail), "
     @"100% smears across the full frame."),
    (@"<accent>Quality</accent> controls the sample count - more samples "
     @"means smoother blur but slower renders. Default ~16 samples; the "
     @"slider scales exponentially up to 128."),
    (@"<accent>Transitions only?</accent> skips the blur work on "
     @"<accent>hold</accent> segments, where nothing is moving anyway. "
     @"Big performance win on segments which don't need motion blur."),
    (@"<accent>Adaptive Quality</accent> drops sub-frame resolution "
     @"automatically when playback can't keep up, then restores full "
     @"quality the moment you pause. Probes back to full once a second "
     @"so you don't get stuck in low quality if performance recovers. "
     @"Off during export. Recommended to leave this option on."),
    (@"<warn>Tip:</warn> high Length with low Quality will band visibly. "
     @"If you increase Length, its recommended to increase Quality too."),
  ];

  KKHelpSection *mb = [KKHelpSection sectionWithTitle:@"Motion Blur"
                                            tipMarkup:tips
                                            shortcuts:nil];
  mb.icon = [NSImage imageWithSystemSymbolName:@"figure.walk.motion"
                      accessibilityDescription:nil];
  return mb;
}

- (void)openHelpRemoteWindow {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI) {
    KKLogError(@"FxCustomParameterActionAPI_v4 unavailable");
    return;
  }
  [actionAPI startAction:self];

  id<FxRemoteWindowAPI> windowAPI =
      [self.apiManager apiForProtocol:@protocol(FxRemoteWindowAPI)];
  if (!windowAPI) {
    KKLogError(@"FxRemoteWindowAPI unavailable");
    [actionAPI endAction:self];
    return;
  }

  NSMutableArray<KKHelpSection *> *sections =
      [[self helpSections] mutableCopy] ?: [NSMutableArray array];
  NSString *wrapTip =
      [KKPlugin _clipWrappingTipForMode:[self clipWrappingMode]];
  if (wrapTip.length > 0 && sections.count > 0)
    [KKPlugin _prependClipWrappingTip:wrapTip toSection:sections.firstObject];
  if ([self animatableProperties].count > 0)
    [sections addObject:[KKPlugin _builtInTimingHelpSection]];
  if ([self usesMotionBlur])
    [sections addObject:[KKPlugin _builtInMotionBlurHelpSection]];
  CGSize contentSize = CGSizeMake(500.0, 420.0);
  [windowAPI remoteWindowOfSize:contentSize
                          reply:^(FxXPView *parentView, NSError *error) {
                            if (!parentView) {
                              if (error)
                                KKLogError(@"remoteWindow error: %@", error);
                              return;
                            }
                            NSView *host = parentView.superview ?: parentView;
                            for (NSView *sub in [host.subviews copy])
                              if ([sub.identifier
                                      isEqualToString:KKRemoteWindowContentID])
                                [sub removeFromSuperview];
                            KKHelpView *helpView =
                                [[KKHelpView alloc] initWithSections:sections];
                            helpView.identifier = KKRemoteWindowContentID;
                            helpView.translatesAutoresizingMaskIntoConstraints =
                                NO;
                            [host addSubview:helpView];
                            [NSLayoutConstraint activateConstraints:@[
                              [helpView.leadingAnchor
                                  constraintEqualToAnchor:host.leadingAnchor],
                              [helpView.trailingAnchor
                                  constraintEqualToAnchor:host.trailingAnchor],
                              [helpView.topAnchor
                                  constraintEqualToAnchor:host.topAnchor],
                              [helpView.bottomAnchor
                                  constraintEqualToAnchor:host.bottomAnchor],
                            ]];
                          }];

  [actionAPI endAction:self];
}

@end

#pragma clang diagnostic pop
