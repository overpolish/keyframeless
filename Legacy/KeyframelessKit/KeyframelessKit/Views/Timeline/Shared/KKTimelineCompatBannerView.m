/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineCompatBannerView.h"

#import "KKConstants.h"
#import "KKLocalized.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

@implementation _KKCompatBannerView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (!self)
    return nil;
  NSVisualEffectView *blur = [[NSVisualEffectView alloc] init];
  blur.translatesAutoresizingMaskIntoConstraints = NO;
  blur.material = NSVisualEffectMaterialHUDWindow;
  blur.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  blur.state = NSVisualEffectStateActive;
  [self addSubview:blur];

  NSTextField *msg = [NSTextField
      labelWithString:
          KKLoc(@"Your current sequence isn't compatible with Basic mode.",
                @"Alert: switching timeline to Basic mode.")];
  msg.translatesAutoresizingMaskIntoConstraints = NO;
  msg.font = [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightMedium];
  msg.textColor = [NSColor inspectorLabel];
  msg.alignment = NSTextAlignmentCenter;
  msg.maximumNumberOfLines = 2;
  msg.lineBreakMode = NSLineBreakByWordWrapping;
  // This banner is normally hidden, but a hidden subview's constraints still
  // feed the inspector's fittingSize. Without lowering compression resistance,
  // a long localized message (e.g. German) reports its full single-line
  // intrinsic width and forces the whole inspector to a wide minimum, which
  // FCP then refuses to shrink below, clipping the right edge when the panel
  // is narrowed. Yielding horizontally lets the label wrap instead of driving
  // the layout width.
  [msg setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1
                                forOrientation:
                                    NSLayoutConstraintOrientationHorizontal];
  [self addSubview:msg];

  NSTextField *sub = [NSTextField
      labelWithString:KKLoc(@"Switching will reset incompatible lanes.",
                            @"Alert detail: switching to Basic mode.")];
  sub.translatesAutoresizingMaskIntoConstraints = NO;
  sub.font = [NSFont systemFontOfSize:KKFontSizeSM - 1];
  sub.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
  sub.alignment = NSTextAlignmentCenter;
  [self addSubview:sub];

  NSFont *btnFont = [NSFont systemFontOfSize:KKFontSizeSM
                                      weight:NSFontWeightMedium];

  NSButton *cancel =
      [NSButton buttonWithTitle:KKLoc(@"Cancel", @"Button: cancel.")
                         target:self
                         action:@selector(_cancelTap:)];
  cancel.bordered = NO;
  cancel.bezelStyle = NSBezelStyleInline;
  cancel.controlSize = NSControlSizeSmall;
  cancel.font = btnFont;
  cancel.attributedTitle = [[NSAttributedString alloc]
      initWithString:KKLoc(@"Cancel", @"Button: cancel.")
          attributes:@{
            NSForegroundColorAttributeName :
                [[NSColor inspectorLabel] colorWithAlphaComponent:0.6],
            NSFontAttributeName : btnFont
          }];

  NSButton *confirm =
      [NSButton buttonWithTitle:KKLoc(@"Switch anyway",
                                      @"Alert button: switch despite warning.")
                         target:self
                         action:@selector(_confirmTap:)];
  confirm.bordered = NO;
  confirm.bezelStyle = NSBezelStyleInline;
  confirm.controlSize = NSControlSizeSmall;
  confirm.font = btnFont;
  confirm.attributedTitle = [[NSAttributedString alloc]
      initWithString:KKLoc(@"Switch anyway",
                           @"Alert button: switch despite warning.")
          attributes:@{
            NSForegroundColorAttributeName : [NSColor accentMatchingHost],
            NSFontAttributeName : btnFont
          }];

  NSStackView *btnRow = [NSStackView stackViewWithViews:@[ cancel, confirm ]];
  btnRow.translatesAutoresizingMaskIntoConstraints = NO;
  btnRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  btnRow.spacing = KKPaddingLG;
  btnRow.alignment = NSLayoutAttributeCenterY;
  [self addSubview:btnRow];

  [NSLayoutConstraint activateConstraints:@[
    [blur.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [blur.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [blur.topAnchor constraintEqualToAnchor:self.topAnchor],
    [blur.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

    [msg.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor
                                                   constant:KKPaddingLG],
    [msg.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                 constant:-KKPaddingLG],
    [msg.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [msg.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-22],

    [sub.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [sub.topAnchor constraintEqualToAnchor:msg.bottomAnchor
                                  constant:KKSpacingSM],

    [btnRow.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [btnRow.topAnchor constraintEqualToAnchor:sub.bottomAnchor
                                     constant:KKPaddingMD],
  ]];
  return self;
}

- (void)_cancelTap:(id)sender {
  if (_onCancel)
    _onCancel();
}
- (void)_confirmTap:(id)sender {
  if (_onConfirm)
    _onConfirm();
}

@end
