/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneFilterBar.h"
#import "KKCompoundPillBar.h"
#import "KKLaneFilterModel.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

static const CGFloat kLaneFilterBarH = 30.0;
static const CGFloat kLaneFilterPillH = 22.0;

@implementation KKLaneFilterBar {
  KKLaneFilterModel *_model;
  KKCompoundPillBar *_bar;
  NSButton *_clearButton; // sits at the right; resets to show-all
  // The pill bar shrinks to make room for the clear button when it's shown, and
  // reclaims the full width when it's hidden (nothing filtered).
  NSLayoutConstraint *_barTrailingFull;
  NSLayoutConstraint *_barTrailingInset;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  _model = [[KKLaneFilterModel alloc] initWithLanes:lanes];
  [self _buildClearButton];
  [self _rebuildBar];
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kLaneFilterBarH);
}

#pragma mark - Public API (delegates to the model)

- (void)applyLanes:(NSArray<KKLane *> *)lanes {
  if ([_model applyLanes:lanes])
    [self _rebuildBar];
}

- (NSSet<NSString *> *)hiddenLabels {
  return [_model hiddenLabels];
}

- (void)showAllLanes {
  [_model showAll];
  [self _emitVisibilityChange];
}

- (void)applyHiddenLabels:(NSSet<NSString *> *)hidden {
  [_model applyHidden:hidden];
  [self _emitVisibilityChange];
}

#pragma mark - Clear button

// Reset-filter affordance: a small glyph at the right edge (matching the
// inspector's clear-selection button - xmark.circle in the host accent tint).
// Shown only while a filter is active; clicking it shows every lane again.
- (void)_buildClearButton {
  NSImage *img = [[NSImage imageWithSystemSymbolName:@"xmark.circle"
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:[NSImageSymbolConfiguration
                                       configurationWithPointSize:11.0
                                                           weight:
                                                               NSFontWeightRegular]];
  NSButton *b = [NSButton buttonWithImage:img
                                   target:self
                                   action:@selector(_clearTapped:)];
  b.bordered = NO;
  b.imagePosition = NSImageOnly;
  b.contentTintColor = [NSColor accentMatchingHost];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.hidden = YES;
  [self addSubview:b];
  [NSLayoutConstraint activateConstraints:@[
    [b.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                     constant:-KKPaddingMD],
    [b.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [b.widthAnchor constraintEqualToConstant:16.0],
    [b.heightAnchor constraintEqualToConstant:16.0],
  ]];
  _clearButton = b;
}

- (void)_clearTapped:(id)sender {
  [self showAllLanes];
  if (self.onUserToggled)
    self.onUserToggled();
}

// Show the clear button (and shrink the bar to make room) only while a filter
// is active; otherwise hide it and let the bar reclaim the full width.
- (void)_updateClearButtonState {
  BOOL active = _model.filterActive;
  _clearButton.hidden = !active;
  _barTrailingInset.active = active;
  _barTrailingFull.active = !active;
}

#pragma mark - Pill bar

- (void)_rebuildBar {
  [_bar removeFromSuperview];

  _bar = [[KKCompoundPillBar alloc] initWithCompounds:_model.displayLabels];
  _bar.translatesAutoresizingMaskIntoConstraints = NO;
  _bar.crossCapsuleSweep = YES;
  _bar.dragExcludedIndices = _model.masterExcludedIndices;
  // The bar scrolls horizontally; its (potentially wide, e.g. long localized
  // labels) intrinsic content width must NOT inflate the inspector's
  // fittingSize and push the timeline off the right edge. Yield to the
  // available width instead of driving it.
  [_bar setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
  [_bar setContentHuggingPriority:NSLayoutPriorityDefaultLow
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  __weak typeof(self) weak = self;
  _bar.onToggled = ^(NSInteger ci, NSInteger seg, BOOL on) {
    [weak _toggleCompound:ci segment:seg on:on];
  };
  _bar.onOptionToggled = ^(NSInteger ci, NSInteger seg) {
    [weak _soloCompound:ci segment:seg];
  };
  [self addSubview:_bar positioned:NSWindowBelow relativeTo:_clearButton];
  [NSLayoutConstraint activateConstraints:@[
    [_bar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                       constant:KKPaddingMD],
    [_bar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    // The compound bar wraps an internal scroll view, so give it a definite
    // height (its natural grouped-pill height) rather than rely on intrinsic.
    [_bar.heightAnchor constraintEqualToConstant:kLaneFilterPillH],
  ]];
  // Two trailing constraints, toggled by _updateClearButtonState: full width
  // when nothing is filtered, inset to the clear button's leading otherwise.
  _barTrailingFull =
      [_bar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                          constant:-KKPaddingMD];
  _barTrailingInset =
      [_bar.trailingAnchor constraintEqualToAnchor:_clearButton.leadingAnchor
                                          constant:-KKSpacingSM];
  [self _syncBar];
}

- (void)_syncBar {
  _bar.states = _model.segmentStates;
  _bar.warningStates = _model.segmentWarnings;
  [self _updateClearButtonState];
}

- (void)_emitVisibilityChange {
  [self _syncBar];
  if (self.onVisibilityChanged)
    self.onVisibilityChanged([_model hiddenLabels]);
}

#pragma mark - Click forwarding

- (void)_toggleCompound:(NSInteger)ci segment:(NSInteger)seg on:(BOOL)on {
  [_model toggleCompound:ci segment:seg on:on];
  [self _emitVisibilityChange];
  if (self.onUserToggled)
    self.onUserToggled();
}

- (void)_soloCompound:(NSInteger)ci segment:(NSInteger)seg {
  [_model soloCompound:ci segment:seg];
  [self _emitVisibilityChange];
  if (self.onUserToggled)
    self.onUserToggled();
}

@end
