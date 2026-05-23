/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKHelpSection.h"
#import "KKHelpView+Guides.h"
#import "KKHelpView_Private.h"
#import "KKLocalized.h"

@implementation KKHelpView (Guides)

- (NSView *)_guidesBlockForGuides:(NSArray<KKHelpGuide *> *)guides {
  NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = KKHelpAfterTitleGap;

  [stack
      addArrangedSubview:
          [self _subheading:KKLoc(@"Interactive Guides",
                                  @"Help: interactive guides section title.")]];

  // Section-level warning: shown once under the subheading whenever ANY
  // guide is disabled. Text is sourced from the first disabled guide's
  // disabledSubtitle in -refreshGuideRows. Hidden by default; -refreshGuideRows
  // sets visibility on first pass.
  NSTextField *warn = [NSTextField labelWithString:@""];
  warn.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
  warn.textColor = [NSColor warning];
  warn.lineBreakMode = NSLineBreakByWordWrapping;
  warn.maximumNumberOfLines = 0;
  warn.hidden = YES;
  warn.translatesAutoresizingMaskIntoConstraints = NO;
  [stack addArrangedSubview:warn];
  [warn.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor].active = YES;
  [warn.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor].active =
      YES;
  _guidesWarningLabel = warn;

  NSStackView *links = [[NSStackView alloc] initWithFrame:NSZeroRect];
  links.orientation = NSUserInterfaceLayoutOrientationVertical;
  links.alignment = NSLayoutAttributeLeading;
  links.spacing = 6.0;
  links.edgeInsets = NSEdgeInsetsMake(0, 12.0, 0, 0);

  _guideRowRefs = [NSMutableArray array];
  for (KKHelpGuide *guide in guides) {
    NSView *row = [self _rowForGuide:guide];
    [links addArrangedSubview:row];
    // Stretch the row to the links content width so the trailing "Completed"
    // badge sits at the far right instead of hugging the text.
    [row.widthAnchor constraintEqualToAnchor:links.widthAnchor
                                    constant:-links.edgeInsets.left]
        .active = YES;
  }
  _guidesLinksStack = links;
  [stack addArrangedSubview:links];
  [links.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
  [self _refreshSectionWarning];

  return stack;
}

// Builds the 20×20 icon slot (play button + spinner, only one visible at a
// time) and wires the tap action. Populates refs.icon and refs.spinner.
- (NSView *)_makeIconSlotSettingRefs:(_KKGuideRowRefs *)refs
                               guide:(KKHelpGuide *)guide {
  NSView *iconSlot = [[NSView alloc] initWithFrame:NSZeroRect];
  iconSlot.translatesAutoresizingMaskIntoConstraints = NO;
  [iconSlot.widthAnchor constraintEqualToConstant:20.0].active = YES;
  [iconSlot.heightAnchor constraintEqualToConstant:20.0].active = YES;

  _KKGuideStartButton *iconBtn = [[_KKGuideStartButton alloc] init];
  [iconBtn setButtonType:NSButtonTypeMomentaryChange];
  iconBtn.bordered = NO;
  iconBtn.image = [NSImage imageWithSystemSymbolName:@"play.circle.fill"
                            accessibilityDescription:nil];
  iconBtn.symbolConfiguration = [NSImageSymbolConfiguration
      configurationWithPointSize:16.0
                          weight:NSFontWeightMedium];
  iconBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [iconSlot addSubview:iconBtn];

  NSProgressIndicator *spinner =
      [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
  spinner.style = NSProgressIndicatorStyleSpinning;
  spinner.controlSize = NSControlSizeSmall;
  spinner.displayedWhenStopped = NO;
  spinner.translatesAutoresizingMaskIntoConstraints = NO;
  [iconSlot addSubview:spinner];
  [NSLayoutConstraint activateConstraints:@[
    [iconBtn.leadingAnchor constraintEqualToAnchor:iconSlot.leadingAnchor],
    [iconBtn.trailingAnchor constraintEqualToAnchor:iconSlot.trailingAnchor],
    [iconBtn.centerYAnchor constraintEqualToAnchor:iconSlot.centerYAnchor],
    [spinner.centerXAnchor constraintEqualToAnchor:iconSlot.centerXAnchor],
    [spinner.centerYAnchor constraintEqualToAnchor:iconSlot.centerYAnchor],
  ]];

  refs.icon = iconBtn;
  refs.spinner = spinner;

  BOOL (^provider)(void) = guide.enabledProvider;
  void (^onStart)(void) = guide.onStart;
  __weak typeof(self) weakSelf = self;
  __weak _KKGuideRowRefs *weakRefs = refs;
  iconBtn.actionBlock = ^{
    BOOL nowEnabled = provider ? provider() : YES;
    if (!nowEnabled)
      return;
    if (guide.activeProvider)
      [weakSelf _startLoaderForRefs:weakRefs];
    if (onStart)
      onStart();
    // "Completed" is gated on real completion ([guide markCompleted], called
    // by the guide owner) - not on tap. The refresh poll picks up the badge.
  };
  return iconSlot;
}

// Builds the trailing "Completed" capsule - checkmark + label, capsule fill
// at 15% opacity. The capsule self-rounds via _KKCapsuleView.layout.
- (NSView *)_makeBadgeView {
  NSColor *badgeColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.6];
  _KKCapsuleView *badge = [[_KKCapsuleView alloc] initWithFrame:NSZeroRect];
  badge.translatesAutoresizingMaskIntoConstraints = NO;
  badge.wantsLayer = YES;
  badge.layer.backgroundColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.15].CGColor;
  [badge setContentHuggingPriority:NSLayoutPriorityRequired
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [badge setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                  forOrientation:
                                      NSLayoutConstraintOrientationHorizontal];

  NSImageView *tick = [NSImageView
      imageViewWithImage:[NSImage imageWithSystemSymbolName:@"checkmark"
                                   accessibilityDescription:nil]];
  tick.symbolConfiguration =
      [NSImageSymbolConfiguration configurationWithPointSize:8.0
                                                      weight:NSFontWeightBold];
  tick.contentTintColor = badgeColor;
  NSTextField *badgeLabel = [NSTextField
      labelWithString:KKLoc(@"Completed", @"Help: guide completed badge.")];
  badgeLabel.font = [NSFont systemFontOfSize:9.0 weight:NSFontWeightMedium];
  badgeLabel.textColor = badgeColor;

  NSStackView *content = [NSStackView stackViewWithViews:@[ tick, badgeLabel ]];
  content.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  content.alignment = NSLayoutAttributeCenterY;
  content.spacing = 3.0;
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [badge addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:badge.leadingAnchor
                                          constant:KKPaddingSM + 1.0],
    [content.trailingAnchor constraintEqualToAnchor:badge.trailingAnchor
                                           constant:-(KKPaddingSM + 1.0)],
    [content.topAnchor constraintEqualToAnchor:badge.topAnchor
                                      constant:KKPaddingXS],
    [content.bottomAnchor constraintEqualToAnchor:badge.bottomAnchor
                                         constant:-KKPaddingXS],
  ]];
  return badge;
}

- (NSView *)_rowForGuide:(KKHelpGuide *)guide {
  _KKGuideRowRefs *refs = [[_KKGuideRowRefs alloc] init];

  NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.spacing = 10.0;

  [row addArrangedSubview:[self _makeIconSlotSettingRefs:refs guide:guide]];

  NSStackView *textStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
  textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  textStack.alignment = NSLayoutAttributeLeading;
  textStack.spacing = 2.0;
  // Title hugs its content; a flexible spacer (added below) takes the slack
  // so the badge sits at the far right: [play][title][gap][badge].
  [textStack setContentHuggingPriority:NSLayoutPriorityDefaultHigh
                        forOrientation:NSLayoutConstraintOrientationHorizontal];

  NSTextField *titleLabel = [NSTextField labelWithString:guide.title];
  titleLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightMedium];
  [textStack addArrangedSubview:titleLabel];

  // Always create the subtitle label when either subtitle exists so its text
  // + colour can be swapped in place between the enabled/disabled states.
  NSTextField *subLabel = nil;
  if (guide.subtitle.length > 0 || guide.disabledSubtitle.length > 0) {
    subLabel = [NSTextField labelWithString:@""];
    subLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [textStack addArrangedSubview:subLabel];
  }
  [row addArrangedSubview:textStack];

  // Flexible spacer pushes the badge to the trailing edge.
  NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
  spacer.translatesAutoresizingMaskIntoConstraints = NO;
  [spacer setContentHuggingPriority:1
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
  [spacer setContentCompressionResistancePriority:1
                                   forOrientation:
                                       NSLayoutConstraintOrientationHorizontal];
  [row addArrangedSubview:spacer];

  NSView *badge = [self _makeBadgeView];
  [row addArrangedSubview:badge];

  refs.guide = guide;
  refs.title = titleLabel;
  refs.subtitle = subLabel;
  refs.badge = badge;
  [_guideRowRefs addObject:refs];
  [self _applyStateToRefs:refs];

  return row;
}

// Swap the play icon for a spinner until guide.activeProvider reports the
// guide is on screen (covers an async warm-up like the OSC zoom-to-fit), or
// a timeout elapses so the button can never get stuck spinning.
- (void)_startLoaderForRefs:(_KKGuideRowRefs *)r {
  if (!r || r.loaderTimer)
    return;
  r.loaderStart = CACurrentMediaTime();
  r.icon.hidden = YES;
  r.spinner.hidden = NO;
  [r.spinner startAnimation:nil];
  __weak typeof(self) weak = self;
  __weak _KKGuideRowRefs *wr = r;
  r.loaderTimer = [NSTimer
      scheduledTimerWithTimeInterval:0.15
                             repeats:YES
                               block:^(NSTimer *t) {
                                 __strong typeof(weak) s = weak;
                                 __strong _KKGuideRowRefs *rr = wr;
                                 if (!s || !rr) {
                                   [t invalidate];
                                   return;
                                 }
                                 BOOL active = rr.guide.activeProvider
                                                   ? rr.guide.activeProvider()
                                                   : YES;
                                 BOOL timedOut = (CACurrentMediaTime() -
                                                  rr.loaderStart) > 8.0;
                                 if (active || timedOut)
                                   [s _stopLoaderForRefs:rr];
                               }];
}

- (void)_stopLoaderForRefs:(_KKGuideRowRefs *)r {
  if (!r)
    return;
  [r.loaderTimer invalidate];
  r.loaderTimer = nil;
  [r.spinner stopAnimation:nil];
  r.spinner.hidden = YES;
  r.icon.hidden = NO;
}

// Mutates the existing controls - never rebuilds the row. Icon is accent
// when actionable & new, muted once the guide has been completed, dim when
// disabled. The "Completed" pill shows after a full run. The "select a clip"
// warning now lives section-wide via -_refreshSectionWarning; rows just dim
// when disabled so it's still visible per-row without per-row text.
- (void)_applyStateToRefs:(_KKGuideRowRefs *)r {
  KKHelpGuide *guide = r.guide;
  if (!guide)
    return;
  BOOL enabled = guide.enabledProvider ? guide.enabledProvider() : YES;
  BOOL viewed = guide.hasBeenCompleted;
  r.hasState = YES;
  r.lastEnabled = enabled;
  r.lastViewed = viewed;

  r.icon.contentTintColor =
      !enabled ? [[NSColor inspectorLabel] colorWithAlphaComponent:0.25]
      : viewed ? [[NSColor inspectorLabel] colorWithAlphaComponent:0.55]
               : [NSColor accentMatchingHost];
  r.title.textColor =
      enabled ? [NSColor inspectorLabel]
              : [[NSColor inspectorLabel] colorWithAlphaComponent:0.4];

  if (r.subtitle) {
    NSString *text = guide.subtitle;
    r.subtitle.stringValue = text ?: @"";
    r.subtitle.hidden = (text.length == 0);
    r.subtitle.textColor = [[NSColor inspectorLabel]
        colorWithAlphaComponent:(enabled ? 0.5 : 0.3)];
  }

  r.badge.hidden = !viewed;
}

// Walks the row state and toggles the section warning. Text comes from the
// first disabled guide's `disabledSubtitle` (Rounded's 4 guides all share the
// same "select a Rounded clip…" text - picking the first is fine; if a future
// plugin wants distinct per-guide reasons it can normalise them to one shared
// message).
- (void)_refreshSectionWarning {
  if (!_guidesWarningLabel)
    return;
  NSString *warningText = nil;
  for (_KKGuideRowRefs *r in _guideRowRefs) {
    KKHelpGuide *guide = r.guide;
    if (!guide)
      continue;
    BOOL enabled = guide.enabledProvider ? guide.enabledProvider() : YES;
    if (!enabled && guide.disabledSubtitle.length > 0) {
      warningText = guide.disabledSubtitle;
      break;
    }
  }
  if (warningText.length > 0) {
    _guidesWarningLabel.stringValue = warningText;
    _guidesWarningLabel.hidden = NO;
  } else {
    _guidesWarningLabel.hidden = YES;
  }
}

- (void)refreshGuideRows {
  if (_guideRowRefs.count == 0)
    return;
  for (_KKGuideRowRefs *r in _guideRowRefs) {
    KKHelpGuide *guide = r.guide;
    if (!guide)
      continue;
    BOOL enabled = guide.enabledProvider ? guide.enabledProvider() : YES;
    BOOL viewed = guide.hasBeenCompleted;
    if (r.hasState && r.lastEnabled == enabled && r.lastViewed == viewed)
      continue; // no change → no work, no flicker
    [self _applyStateToRefs:r];
  }
  [self _refreshSectionWarning];
}

- (void)observeGuideRefreshNotificationNamed:(NSNotificationName)name {
  __weak typeof(self) weak = self;
  // The notification (posted while the OSC is alive) catches the *enable*
  // edge promptly. The *disable* edge has no event - when the clip is
  // deselected the host just stops posting - so a periodic state check is
  // still required. refreshGuideRows is now a cheap diff that mutates a row
  // only when its enabled state actually flips, so this no longer churns.
  if (name.length) {
    _refreshObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:name
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *_) {
                  [weak refreshGuideRows];
                }];
  }
  _refreshTimer =
      [NSTimer scheduledTimerWithTimeInterval:1.0
                                       target:self
                                     selector:@selector(refreshGuideRows)
                                     userInfo:nil
                                      repeats:YES];
}

- (void)_teardownGuideRefresh {
  if (_refreshObserver) {
    [[NSNotificationCenter defaultCenter] removeObserver:_refreshObserver];
    _refreshObserver = nil;
  }
  [_refreshTimer invalidate];
  _refreshTimer = nil;
  for (_KKGuideRowRefs *r in _guideRowRefs) {
    [r.loaderTimer invalidate];
    r.loaderTimer = nil;
  }
}

@end
