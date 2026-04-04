/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKAlertView.h"
#import "KKCheckboxView.h"
#import "KKCurvePillView.h"
#import "KKSliderView.h"
#import "KKTimingGraphView_Private.h"
#import "KKTimingSlot.h"
#import <AppKit/AppKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation KKTimingGraphView {
  KKCheckboxView *_inCheckbox;
  KKCheckboxView *_outCheckbox;
  KKSliderView *_intensitySlider;
  KKSliderView *_frequencySlider;
  NSButton *_seedButton;
  NSMutableArray<NSView *> *_globalSlotViews;
  NSMutableArray<NSView *> *_sectionSlotViews;
  NSLayoutConstraint *_intensityTrailingHalf;
  NSLayoutConstraint *_intensityTrailingFull;
  KKAlertView *_emptyPlaceholder;
}

#pragma clang diagnostic pop

@synthesize curvePillView = _curvePillView;
@synthesize durationSlider = _durationSlider;
@synthesize durationTickImageView = _durationTickImageView;
@synthesize graphImageView = _graphImageView;
@synthesize intensityTickImageView = _intensityTickImageView;
@synthesize frequencyTickImageView = _frequencyTickImageView;
@synthesize holdSeedStack = _holdSeedStack;

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _inEnabled = NO;
    _outEnabled = NO;
    _inDuration = 0.5;
    _outDuration = 0.5;
    _inCurve = KKEasingCurveEaseOut;
    _outCurve = KKEasingCurveEaseOut;
    _holdEffect = KKHoldEffectNone;
    _inIntensity = 0.5;
    _outIntensity = 0.5;
    _holdIntensity = 0.5;
    _inFrequency = 0.5;
    _outFrequency = 0.5;
    _holdFrequency = 0.5;
    _selectedSection = KKTimingGraphSectionHold;

    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;

    // Row 0: [Pill curve selector (left)] [Duration slider + ticks (right)]
    _curvePillView = [[KKCurvePillView alloc] initWithFrame:NSZeroRect];
    _curvePillView.translatesAutoresizingMaskIntoConstraints = NO;
    _curvePillView.pillCount = KKEasingCurveCount;
    _curvePillView.selectedIndex = KKEasingCurveEaseOut;
    _curvePillView.hidden = YES;
    [self addSubview:_curvePillView];

    __weak typeof(self) weakSelf = self;
    _curvePillView.onSelectionChanged = ^(NSInteger index) {
      [weakSelf pillSelectionChanged:index];
    };

    [NSLayoutConstraint activateConstraints:@[
      [_curvePillView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_curvePillView.topAnchor constraintEqualToAnchor:self.topAnchor
                                               constant:kTopPadding],
      [_curvePillView.heightAnchor constraintEqualToConstant:kPillRowHeight],
    ]];

    _durationSlider = [KKSliderView styledSlider];
    _durationSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _durationSlider.minValue = 0.1;
    _durationSlider.maxValue = 2.0;
    _durationSlider.doubleValue = 0.5;
    _durationSlider.continuous = YES;
    _durationSlider.trackFillColor = [NSColor accentMatchingHost];
    _durationSlider.hidden = YES;
    _durationSlider.target = self;
    _durationSlider.action = @selector(durationSliderChanged:);
    [self addSubview:_durationSlider];

    [NSLayoutConstraint activateConstraints:@[
      [_durationSlider.leadingAnchor
          constraintEqualToAnchor:_curvePillView.trailingAnchor
                         constant:KKSpacingLG],
      [_durationSlider.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
      [_durationSlider.centerYAnchor
          constraintEqualToAnchor:_curvePillView.centerYAnchor],
      [_durationSlider.heightAnchor constraintEqualToConstant:kSliderRowHeight],
    ]];

    // Pill takes ~half, duration takes ~half
    [_curvePillView.widthAnchor
        constraintEqualToAnchor:_durationSlider.widthAnchor]
        .active = YES;

    _durationTickImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _durationTickImageView.imageScaling = NSImageScaleNone;
    _durationTickImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [_durationTickImageView
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
    _durationTickImageView.hidden = YES;
    [self addSubview:_durationTickImageView];

    [NSLayoutConstraint activateConstraints:@[
      [_durationTickImageView.leadingAnchor
          constraintEqualToAnchor:_durationSlider.leadingAnchor],
      [_durationTickImageView.trailingAnchor
          constraintEqualToAnchor:_durationSlider.trailingAnchor],
      [_durationTickImageView.topAnchor
          constraintEqualToAnchor:_curvePillView.bottomAnchor],
      [_durationTickImageView.heightAnchor
          constraintEqualToConstant:kDurationTickHeight],
    ]];

    // Row 1: Graph + labels
    CGFloat graphTop =
        kTopPadding + kPillRowHeight + kDurationTickHeight + KKSpacingLG;

    _graphImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _graphImageView.imageScaling = NSImageScaleNone;
    _graphImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [_graphImageView
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_graphImageView];

    [NSLayoutConstraint activateConstraints:@[
      [_graphImageView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_graphImageView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
      [_graphImageView.topAnchor constraintEqualToAnchor:self.topAnchor
                                                constant:graphTop],
      [_graphImageView.heightAnchor
          constraintEqualToConstant:kGraphHeight + kLabelRowHeight],
    ]];

    _inCheckbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
    _inCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_inCheckbox];

    _outCheckbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
    _outCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_outCheckbox];

    [NSLayoutConstraint activateConstraints:@[
      [_inCheckbox.widthAnchor constraintEqualToConstant:kCheckboxSize],
      [_inCheckbox.heightAnchor constraintEqualToConstant:kCheckboxSize],
      [_outCheckbox.widthAnchor constraintEqualToConstant:kCheckboxSize],
      [_outCheckbox.heightAnchor constraintEqualToConstant:kCheckboxSize],
    ]];

    _inCheckbox.onToggle = ^(BOOL isChecked) {
      if (weakSelf.onInToggled)
        weakSelf.onInToggled(isChecked);
    };
    _outCheckbox.onToggle = ^(BOOL isChecked) {
      if (weakSelf.onOutToggled)
        weakSelf.onOutToggled(isChecked);
    };

    NSTextField *holdLabel = [NSTextField labelWithString:@"Hold"];
    holdLabel.font = [NSFont systemFontOfSize:9.0 weight:NSFontWeightMedium];
    holdLabel.textColor = [NSColor inspectorLabel];

    _seedButton = [NSButton
        buttonWithImage:[NSImage imageWithSystemSymbolName:@"shuffle"
                                  accessibilityDescription:@"Randomize"]
                 target:self
                 action:@selector(seedButtonPressed:)];
    _seedButton.bezelStyle = NSBezelStyleInline;
    _seedButton.bordered = NO;
    _seedButton.contentTintColor = [NSColor accentMatchingHost];
    [NSLayoutConstraint activateConstraints:@[
      [_seedButton.widthAnchor constraintEqualToConstant:kCheckboxSize],
      [_seedButton.heightAnchor constraintEqualToConstant:kCheckboxSize],
    ]];

    _holdSeedStack =
        [NSStackView stackViewWithViews:@[ holdLabel, _seedButton ]];
    _holdSeedStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _holdSeedStack.spacing = KKSpacingMD;
    _holdSeedStack.alignment = NSLayoutAttributeCenterY;
    _holdSeedStack.translatesAutoresizingMaskIntoConstraints = NO;
    _holdSeedStack.hidden = YES;
    [self addSubview:_holdSeedStack];

    _globalSlotViews = [NSMutableArray array];
    _sectionSlotViews = [NSMutableArray array];

    // Row 2: [Intensity slider+ticks] [Frequency slider+ticks]
    // Intensity can go full-width when frequency is hidden.
    CGFloat slidersTop = graphTop + kGraphHeight + kLabelRowHeight;
    CGFloat sliderInset = KKInspectorHorizontalInset + KKPaddingMD;

    _intensitySlider = [KKSliderView styledSlider];
    _intensitySlider.translatesAutoresizingMaskIntoConstraints = NO;
    _intensitySlider.minValue = 0.0;
    _intensitySlider.maxValue = 1.0;
    _intensitySlider.doubleValue = 0.5;
    _intensitySlider.continuous = YES;
    _intensitySlider.trackFillColor = [NSColor accentMatchingHost];
    _intensitySlider.hidden = YES;
    _intensitySlider.target = self;
    _intensitySlider.action = @selector(intensitySliderChanged:);
    [self addSubview:_intensitySlider];

    _frequencySlider = [KKSliderView styledSlider];
    _frequencySlider.translatesAutoresizingMaskIntoConstraints = NO;
    _frequencySlider.minValue = 0.0;
    _frequencySlider.maxValue = 1.0;
    _frequencySlider.doubleValue = 0.5;
    _frequencySlider.continuous = YES;
    _frequencySlider.trackFillColor = [NSColor warning];
    _frequencySlider.hidden = YES;
    _frequencySlider.target = self;
    _frequencySlider.action = @selector(frequencySliderChanged:);
    [self addSubview:_frequencySlider];

    _intensityTrailingHalf = [_intensitySlider.trailingAnchor
        constraintEqualToAnchor:self.centerXAnchor
                       constant:-KKSpacingMD];
    _intensityTrailingFull = [_intensitySlider.trailingAnchor
        constraintEqualToAnchor:self.trailingAnchor
                       constant:-sliderInset];
    _intensityTrailingHalf.active = YES;

    [NSLayoutConstraint activateConstraints:@[
      [_intensitySlider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                     constant:sliderInset],
      [_intensitySlider.topAnchor constraintEqualToAnchor:self.topAnchor
                                                 constant:slidersTop],
      [_intensitySlider.heightAnchor
          constraintEqualToConstant:kSliderRowHeight],

      [_frequencySlider.leadingAnchor constraintEqualToAnchor:self.centerXAnchor
                                                     constant:KKSpacingMD],
      [_frequencySlider.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-sliderInset],
      [_frequencySlider.topAnchor constraintEqualToAnchor:self.topAnchor
                                                 constant:slidersTop],
      [_frequencySlider.heightAnchor
          constraintEqualToConstant:kSliderRowHeight],
    ]];

    _intensityTickImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _intensityTickImageView.imageScaling = NSImageScaleNone;
    _intensityTickImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [_intensityTickImageView
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
    _intensityTickImageView.hidden = YES;
    [self addSubview:_intensityTickImageView];

    _frequencyTickImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _frequencyTickImageView.imageScaling = NSImageScaleNone;
    _frequencyTickImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [_frequencyTickImageView
        setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
    _frequencyTickImageView.hidden = YES;
    [self addSubview:_frequencyTickImageView];

    CGFloat ticksTop = slidersTop + kSliderRowHeight;
    [NSLayoutConstraint activateConstraints:@[
      [_intensityTickImageView.leadingAnchor
          constraintEqualToAnchor:_intensitySlider.leadingAnchor],
      [_intensityTickImageView.trailingAnchor
          constraintEqualToAnchor:_intensitySlider.trailingAnchor],
      [_intensityTickImageView.topAnchor constraintEqualToAnchor:self.topAnchor
                                                        constant:ticksTop],
      [_intensityTickImageView.heightAnchor
          constraintEqualToConstant:kTickHeight],

      [_frequencyTickImageView.leadingAnchor
          constraintEqualToAnchor:_frequencySlider.leadingAnchor],
      [_frequencyTickImageView.trailingAnchor
          constraintEqualToAnchor:_frequencySlider.trailingAnchor],
      [_frequencyTickImageView.topAnchor constraintEqualToAnchor:self.topAnchor
                                                        constant:ticksTop],
      [_frequencyTickImageView.heightAnchor
          constraintEqualToConstant:kTickHeight],
    ]];

    // Empty placeholder for when no bottom controls are visible
    _emptyPlaceholder = [[KKAlertView alloc]
        initWithText:@"No controls for current selection"
               color:[[NSColor inspectorLabel] colorWithAlphaComponent:0.3]];
    _emptyPlaceholder.icon =
        [NSImage imageWithSystemSymbolName:@"slider.horizontal.below.rectangle"
                  accessibilityDescription:nil];
    _emptyPlaceholder.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyPlaceholder.hidden = YES;
    [self addSubview:_emptyPlaceholder];

    [NSLayoutConstraint activateConstraints:@[
      [_emptyPlaceholder.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor],
      [_emptyPlaceholder.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor],
      [_emptyPlaceholder.topAnchor constraintEqualToAnchor:self.topAnchor
                                                  constant:slidersTop],
      [_emptyPlaceholder.heightAnchor
          constraintEqualToConstant:kSliderRowHeight + kTickHeight],
    ]];
  }
  return self;
}

- (void)durationSliderChanged:(id)sender {
  double val = _durationSlider.doubleValue;
  if (_selectedSection == KKTimingGraphSectionIn) {
    _inDuration = val;
    if (self.onInDurationChanged)
      self.onInDurationChanged(val);
  } else if (_selectedSection == KKTimingGraphSectionOut) {
    _outDuration = val;
    if (self.onOutDurationChanged)
      self.onOutDurationChanged(val);
  }
  [self renderDurationTicks];
}

- (void)pillSelectionChanged:(NSInteger)index {
  switch (_selectedSection) {
  case KKTimingGraphSectionIn:
    _inCurve = (KKEasingCurve)index;
    if (self.onInCurveChanged)
      self.onInCurveChanged(_inCurve);
    break;
  case KKTimingGraphSectionOut:
    _outCurve = (KKEasingCurve)index;
    if (self.onOutCurveChanged)
      self.onOutCurveChanged(_outCurve);
    break;
  case KKTimingGraphSectionHold:
    _holdEffect = (KKHoldEffect)index;
    if (self.onHoldEffectChanged)
      self.onHoldEffectChanged(_holdEffect);
    break;
  }
  [self updateControls];
  [self renderGraph];
}

- (void)intensitySliderChanged:(id)sender {
  double val = _intensitySlider.doubleValue;
  if (_selectedSection == KKTimingGraphSectionIn) {
    _inIntensity = val;
    if (self.onInIntensityChanged)
      self.onInIntensityChanged(val);
  } else if (_selectedSection == KKTimingGraphSectionOut) {
    _outIntensity = val;
    if (self.onOutIntensityChanged)
      self.onOutIntensityChanged(val);
  } else if (_selectedSection == KKTimingGraphSectionHold) {
    _holdIntensity = val;
    if (self.onHoldIntensityChanged)
      self.onHoldIntensityChanged(val);
  }
  [self renderGraph];
  [self renderCurvePills];
  [self renderIntensityTicks];
  [self renderFrequencyTicks];
}

- (void)seedButtonPressed:(id)sender {
  _holdSeed = arc4random();
  if (self.onHoldSeedChanged)
    self.onHoldSeedChanged(_holdSeed);
  [self renderGraph];
  [self renderCurvePills];
  [self renderIntensityTicks];
  [self renderFrequencyTicks];
}

- (void)frequencySliderChanged:(id)sender {
  double val = _frequencySlider.doubleValue;
  if (_selectedSection == KKTimingGraphSectionIn) {
    _inFrequency = val;
    if (self.onInFrequencyChanged)
      self.onInFrequencyChanged(val);
  } else if (_selectedSection == KKTimingGraphSectionOut) {
    _outFrequency = val;
    if (self.onOutFrequencyChanged)
      self.onOutFrequencyChanged(val);
  } else if (_selectedSection == KKTimingGraphSectionHold) {
    _holdFrequency = val;
    if (self.onHoldFrequencyChanged)
      self.onHoldFrequencyChanged(val);
  }
  [self renderGraph];
  [self renderCurvePills];
  [self renderFrequencyTicks];
}

- (void)updateControls {
  BOOL showIn = _selectedSection == KKTimingGraphSectionIn && _inEnabled;
  BOOL showOut = _selectedSection == KKTimingGraphSectionOut && _outEnabled;
  BOOL showMid = _selectedSection == KKTimingGraphSectionHold;
  BOOL show = showIn || showOut || showMid;

  // Pill selector
  _curvePillView.hidden = !show;
  if (showIn || showOut) {
    _curvePillView.pillCount = KKEasingCurveCount;
    _curvePillView.selectedIndex = showIn ? _inCurve : _outCurve;
  } else if (showMid) {
    _curvePillView.pillCount = KKHoldEffectCount;
    _curvePillView.selectedIndex = _holdEffect;
  }
  if (show)
    [self renderCurvePills];

  // Duration slider (only for In/Out)
  BOOL showDuration = showIn || showOut;
  _durationSlider.hidden = !showDuration;
  _durationTickImageView.hidden = !showDuration;
  if (showIn)
    _durationSlider.doubleValue = _inDuration;
  else if (showOut)
    _durationSlider.doubleValue = _outDuration;
  if (showDuration)
    [self renderDurationTicks];

  BOOL showMidIntensity = showMid && _holdEffect != KKHoldEffectNone;
  _holdSeedStack.hidden = !showMidIntensity;

  // Intensity
  BOOL showInIntensity = showIn && _inCurve != KKEasingCurveLinear;
  BOOL showOutIntensity = showOut && _outCurve != KKEasingCurveLinear;
  BOOL showIntensity = showInIntensity || showOutIntensity || showMidIntensity;
  _intensitySlider.hidden = !showIntensity;
  _intensityTickImageView.hidden = !showIntensity;
  if (showInIntensity)
    _intensitySlider.doubleValue = _inIntensity;
  else if (showOutIntensity)
    _intensitySlider.doubleValue = _outIntensity;
  else if (showMidIntensity)
    _intensitySlider.doubleValue = _holdIntensity;

  // Frequency
  BOOL showInFreq = showIn && (_inCurve == KKEasingCurveBounce ||
                               _inCurve == KKEasingCurveElastic);
  BOOL showOutFreq = showOut && (_outCurve == KKEasingCurveBounce ||
                                 _outCurve == KKEasingCurveElastic);
  BOOL showFrequency = showInFreq || showOutFreq || showMidIntensity;
  _frequencySlider.hidden = !showFrequency;
  _frequencyTickImageView.hidden = !showFrequency;

  // Intensity goes full-width when frequency is hidden
  _intensityTrailingHalf.active = showFrequency;
  _intensityTrailingFull.active = !showFrequency;
  if (showInFreq)
    _frequencySlider.doubleValue = _inFrequency;
  else if (showOutFreq)
    _frequencySlider.doubleValue = _outFrequency;
  else if (showMidIntensity)
    _frequencySlider.doubleValue = _holdFrequency;

  // Placeholder when no bottom controls
  _emptyPlaceholder.hidden = showIntensity || !show;

  if (showIntensity)
    [self renderIntensityTicks];
  if (showFrequency)
    [self renderFrequencyTicks];
}

- (void)setInEnabled:(BOOL)inEnabled {
  _inEnabled = inEnabled;
  _inCheckbox.isChecked = inEnabled;
  [self updateControls];
  [self renderGraph];
}

- (void)setOutEnabled:(BOOL)outEnabled {
  _outEnabled = outEnabled;
  _outCheckbox.isChecked = outEnabled;
  [self updateControls];
  [self renderGraph];
}

- (void)setInDuration:(double)inDuration {
  _inDuration = inDuration;
  [self updateControls];
}

- (void)setOutDuration:(double)outDuration {
  _outDuration = outDuration;
  [self updateControls];
}

- (void)setInCurve:(KKEasingCurve)inCurve {
  _inCurve = inCurve;
  [self updateControls];
  [self renderGraph];
}

- (void)setOutCurve:(KKEasingCurve)outCurve {
  _outCurve = outCurve;
  [self updateControls];
  [self renderGraph];
}

- (void)setHoldEffect:(KKHoldEffect)holdEffect {
  _holdEffect = holdEffect;
  [self updateControls];
  [self renderGraph];
}

- (void)setInIntensity:(double)inIntensity {
  _inIntensity = inIntensity;
  [self updateControls];
  [self renderGraph];
}

- (void)setOutIntensity:(double)outIntensity {
  _outIntensity = outIntensity;
  [self updateControls];
  [self renderGraph];
}

- (void)setSelectedSection:(KKTimingGraphSection)selectedSection {
  _selectedSection = selectedSection;
  [self updateControls];
  [self updateSectionSlots];
  [self renderGraph];
}

- (void)_populateSlotViews:(NSMutableArray<NSView *> *)viewArray
                 withSlots:(NSArray<KKTimingSlot *> *)slots {
  for (NSView *v in viewArray)
    [v removeFromSuperview];
  [viewArray removeAllObjects];
  for (KKTimingSlot *slot in slots) {
    slot.view.autoresizingMask = 0;
    [self addSubview:slot.view];
    [viewArray addObject:slot.view];
  }
  [self setNeedsLayout:YES];
}

- (void)setGlobalSlots:(NSArray<KKTimingSlot *> *)globalSlots {
  _globalSlots = [globalSlots copy];
  [self _populateSlotViews:_globalSlotViews withSlots:_globalSlots];
}

- (void)setInSectionSlots:(NSArray<KKTimingSlot *> *)inSectionSlots {
  _inSectionSlots = [inSectionSlots copy];
  [self updateSectionSlots];
}

- (void)setHoldSectionSlots:(NSArray<KKTimingSlot *> *)holdSectionSlots {
  _holdSectionSlots = [holdSectionSlots copy];
  [self updateSectionSlots];
}

- (void)setOutSectionSlots:(NSArray<KKTimingSlot *> *)outSectionSlots {
  _outSectionSlots = [outSectionSlots copy];
  [self updateSectionSlots];
}

- (void)updateSectionSlots {
  NSArray<KKTimingSlot *> *slots;
  switch (_selectedSection) {
  case KKTimingGraphSectionIn:
    slots = _inSectionSlots;
    break;
  case KKTimingGraphSectionHold:
    slots = _holdSectionSlots;
    break;
  case KKTimingGraphSectionOut:
    slots = _outSectionSlots;
    break;
  }
  [self _populateSlotViews:_sectionSlotViews withSlots:slots];
}

- (BOOL)isFlipped {
  return YES;
}

- (NSRect)sectionRectForSection:(KKTimingGraphSection)section
                          width:(CGFloat)totalWidth {
  CGFloat sectionWidth = floor(totalWidth / 3.0);
  CGFloat x = (CGFloat)section * sectionWidth;
  if (section == KKTimingGraphSectionOut)
    sectionWidth = totalWidth - x;
  return NSMakeRect(x, 0, sectionWidth, kGraphHeight);
}

- (NSRect)graphRectForSection:(KKTimingGraphSection)section {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat graphWidth = NSWidth(self.bounds) - 2 * inset;
  NSRect r = [self sectionRectForSection:section width:graphWidth];
  r.origin.x += inset;
  r.origin.y +=
      kTopPadding + kPillRowHeight + kDurationTickHeight + KKSpacingLG;
  return r;
}

- (void)layout {
  [super layout];

  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightMedium],
  };
  CGFloat graphTop =
      kTopPadding + kPillRowHeight + kDurationTickHeight + KKSpacingLG;
  CGFloat cbY =
      graphTop + kGraphHeight + (kLabelRowHeight - kCheckboxSize) / 2.0;

  NSSize inSize = [@"In" sizeWithAttributes:attrs];
  NSRect inRect = [self graphRectForSection:KKTimingGraphSectionIn];
  CGFloat inGroupX =
      NSMidX(inRect) - (inSize.width + KKSpacingSM + kCheckboxSize) / 2.0;
  _inCheckbox.frame = NSMakeRect(inGroupX + inSize.width + KKSpacingSM, cbY,
                                 kCheckboxSize, kCheckboxSize);

  NSSize outSize = [@"Out" sizeWithAttributes:attrs];
  NSRect outRect = [self graphRectForSection:KKTimingGraphSectionOut];
  CGFloat outGroupX =
      NSMidX(outRect) - (outSize.width + KKSpacingSM + kCheckboxSize) / 2.0;
  _outCheckbox.frame = NSMakeRect(outGroupX + outSize.width + KKSpacingSM, cbY,
                                  kCheckboxSize, kCheckboxSize);

  NSRect holdRect = [self graphRectForSection:KKTimingGraphSectionHold];
  CGFloat stackWidth = _holdSeedStack.fittingSize.width;
  CGFloat stackHeight = _holdSeedStack.fittingSize.height;
  CGFloat stackX = NSMidX(holdRect) - stackWidth / 2.0;
  CGFloat stackY =
      graphTop + kGraphHeight + (kLabelRowHeight - stackHeight) / 2.0;
  _holdSeedStack.frame = NSMakeRect(stackX, stackY, stackWidth, stackHeight);

  CGFloat viewWidth = NSWidth(self.bounds);

  CGFloat slotsY = graphTop + kGraphHeight + kLabelRowHeight +
                   kSliderRowHeight + kTickHeight + KKPaddingSM;

  for (NSUInteger i = 0; i < _globalSlots.count; i++) {
    NSView *v = _globalSlotViews[i];
    CGFloat h = _globalSlots[i].height;
    v.frame = NSMakeRect(0, slotsY, viewWidth, h);
    slotsY += h + KKSpacingSM;
  }

  NSArray<KKTimingSlot *> *sectionSlots;
  switch (_selectedSection) {
  case KKTimingGraphSectionIn:
    sectionSlots = _inSectionSlots;
    break;
  case KKTimingGraphSectionHold:
    sectionSlots = _holdSectionSlots;
    break;
  case KKTimingGraphSectionOut:
    sectionSlots = _outSectionSlots;
    break;
  }
  for (NSUInteger i = 0; i < sectionSlots.count; i++) {
    NSView *v = _sectionSlotViews[i];
    CGFloat h = sectionSlots[i].height;
    v.frame = NSMakeRect(0, slotsY, viewWidth, h);
    slotsY += h + KKSpacingSM;
  }

  [self updateControls];
  [self renderGraph];
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
}

- (NSRect)durationTickHitRectForIndex:(NSInteger)index {
  NSRect sliderFrame = _durationSlider.frame;
  CGFloat tickY = NSMaxY(_curvePillView.frame);
  CGFloat tickAreaWidth = NSWidth(sliderFrame);
  CGFloat tickW = tickAreaWidth / kDurationTickCount;
  CGFloat frac = (kDurationTickCount > 1)
                     ? (CGFloat)index / (CGFloat)(kDurationTickCount - 1)
                     : 0.5;
  CGFloat centerX = NSMinX(sliderFrame) + frac * tickAreaWidth;
  return NSMakeRect(centerX - tickW / 2.0, tickY, tickW, kDurationTickHeight);
}

- (NSRect)_tickHitRectForIndex:(NSInteger)index
                     tickCount:(NSInteger)tickCount
                     imageView:(NSImageView *)imageView {
  NSRect frame = imageView.frame;
  CGFloat tickW = NSWidth(frame) / tickCount;
  CGFloat frac =
      (tickCount > 1) ? (CGFloat)index / (CGFloat)(tickCount - 1) : 0.5;
  CGFloat centerX = NSMinX(frame) + frac * NSWidth(frame);
  return NSMakeRect(centerX - tickW / 2.0, NSMinY(frame), tickW,
                    NSHeight(frame));
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

  if (!_durationSlider.hidden) {
    for (NSInteger i = 0; i < kDurationTickCount; i++) {
      if (NSPointInRect(loc, [self durationTickHitRectForIndex:i])) {
        _durationSlider.doubleValue = kDurationTickValues[i];
        [self durationSliderChanged:_durationSlider];
        return;
      }
    }
  }

  if (!_intensityTickImageView.hidden) {
    for (NSInteger i = 0; i < kIntensityTickCount; i++) {
      NSRect r = [self _tickHitRectForIndex:i
                                  tickCount:kIntensityTickCount
                                  imageView:_intensityTickImageView];
      if (NSPointInRect(loc, r)) {
        double val = (double)i / (double)(kIntensityTickCount - 1);
        _intensitySlider.doubleValue = val;
        [self intensitySliderChanged:_intensitySlider];
        return;
      }
    }
  }

  if (!_frequencyTickImageView.hidden) {
    for (NSInteger i = 0; i < kFrequencyTickCount; i++) {
      NSRect r = [self _tickHitRectForIndex:i
                                  tickCount:kFrequencyTickCount
                                  imageView:_frequencyTickImageView];
      if (NSPointInRect(loc, r)) {
        double val = (double)i / (double)(kFrequencyTickCount - 1);
        _frequencySlider.doubleValue = val;
        [self frequencySliderChanged:_frequencySlider];
        return;
      }
    }
  }

  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    if (NSPointInRect(loc, [self graphRectForSection:s])) {
      if (self.onSectionSelected)
        self.onSectionSelected(s);
      return;
    }
  }
}

@end
