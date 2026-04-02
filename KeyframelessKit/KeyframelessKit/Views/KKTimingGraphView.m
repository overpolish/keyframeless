/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
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
  NSStackView *_globalSlotContainer;
  NSStackView *_sectionSlotContainer;
  NSLayoutConstraint *_intensityTrailingHalf;
  NSLayoutConstraint *_intensityTrailingFull;
}

#pragma clang diagnostic pop

@synthesize curvePillView = _curvePillView;
@synthesize durationSlider = _durationSlider;
@synthesize durationTickImageView = _durationTickImageView;
@synthesize graphImageView = _graphImageView;
@synthesize intensityTickImageView = _intensityTickImageView;
@synthesize frequencyTickImageView = _frequencyTickImageView;
@synthesize midSeedStack = _midSeedStack;

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _inEnabled = NO;
    _outEnabled = NO;
    _inDuration = 0.5;
    _outDuration = 0.5;
    _inCurve = KKEasingCurveEaseOut;
    _outCurve = KKEasingCurveEaseOut;
    _midHoldEffect = KKHoldEffectNone;
    _inIntensity = 0.5;
    _outIntensity = 0.5;
    _midIntensity = 0.5;
    _inFrequency = 0.5;
    _outFrequency = 0.5;
    _midFrequency = 0.5;
    _selectedSection = KKTimingGraphSectionMid;

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

    NSTextField *midLabel = [NSTextField labelWithString:@"Mid"];
    midLabel.font = [NSFont systemFontOfSize:9.0 weight:NSFontWeightMedium];
    midLabel.textColor = [NSColor inspectorLabel];

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

    _midSeedStack = [NSStackView stackViewWithViews:@[ midLabel, _seedButton ]];
    _midSeedStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _midSeedStack.spacing = KKSpacingMD;
    _midSeedStack.alignment = NSLayoutAttributeCenterY;
    _midSeedStack.translatesAutoresizingMaskIntoConstraints = NO;
    _midSeedStack.hidden = YES;
    [self addSubview:_midSeedStack];

    // Global slot container
    _globalSlotContainer = [NSStackView stackViewWithViews:@[]];
    _globalSlotContainer.orientation = NSUserInterfaceLayoutOrientationVertical;
    _globalSlotContainer.spacing = KKSpacingSM;
    _globalSlotContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _globalSlotContainer.hidden = YES;
    [self addSubview:_globalSlotContainer];

    [NSLayoutConstraint activateConstraints:@[
      [_globalSlotContainer.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_globalSlotContainer.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
    ]];

    // Section slot container
    _sectionSlotContainer = [NSStackView stackViewWithViews:@[]];
    _sectionSlotContainer.orientation =
        NSUserInterfaceLayoutOrientationVertical;
    _sectionSlotContainer.spacing = KKSpacingSM;
    _sectionSlotContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _sectionSlotContainer.hidden = YES;
    [self addSubview:_sectionSlotContainer];

    [NSLayoutConstraint activateConstraints:@[
      [_sectionSlotContainer.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_sectionSlotContainer.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
    ]];

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
  case KKTimingGraphSectionMid:
    _midHoldEffect = (KKHoldEffect)index;
    if (self.onMidHoldEffectChanged)
      self.onMidHoldEffectChanged(_midHoldEffect);
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
  } else if (_selectedSection == KKTimingGraphSectionMid) {
    _midIntensity = val;
    if (self.onMidIntensityChanged)
      self.onMidIntensityChanged(val);
  }
  [self renderGraph];
  [self renderCurvePills];
  [self renderIntensityTicks];
  [self renderFrequencyTicks];
}

- (void)seedButtonPressed:(id)sender {
  _midSeed = arc4random();
  if (self.onMidSeedChanged)
    self.onMidSeedChanged(_midSeed);
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
  } else if (_selectedSection == KKTimingGraphSectionMid) {
    _midFrequency = val;
    if (self.onMidFrequencyChanged)
      self.onMidFrequencyChanged(val);
  }
  [self renderGraph];
  [self renderCurvePills];
  [self renderFrequencyTicks];
}

- (void)updateControls {
  BOOL showIn = _selectedSection == KKTimingGraphSectionIn && _inEnabled;
  BOOL showOut = _selectedSection == KKTimingGraphSectionOut && _outEnabled;
  BOOL showMid = _selectedSection == KKTimingGraphSectionMid;
  BOOL show = showIn || showOut || showMid;

  // Pill selector
  _curvePillView.hidden = !show;
  if (showIn || showOut) {
    _curvePillView.pillCount = KKEasingCurveCount;
    _curvePillView.selectedIndex = showIn ? _inCurve : _outCurve;
  } else if (showMid) {
    _curvePillView.pillCount = KKHoldEffectCount;
    _curvePillView.selectedIndex = _midHoldEffect;
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

  BOOL showMidIntensity = showMid && _midHoldEffect != KKHoldEffectNone;
  _midSeedStack.hidden = !showMidIntensity;

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
    _intensitySlider.doubleValue = _midIntensity;

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
    _frequencySlider.doubleValue = _midFrequency;

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

- (void)setMidHoldEffect:(KKHoldEffect)midHoldEffect {
  _midHoldEffect = midHoldEffect;
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

- (void)_populateContainer:(NSStackView *)container
                 withSlots:(NSArray<KKTimingSlot *> *)slots {
  for (NSView *v in [container.arrangedSubviews copy])
    [container removeArrangedSubview:v];
  for (KKTimingSlot *slot in slots)
    [container addArrangedSubview:slot.view];
  container.hidden = (slots.count == 0);
}

- (void)setGlobalSlots:(NSArray<KKTimingSlot *> *)globalSlots {
  _globalSlots = [globalSlots copy];
  [self _populateContainer:_globalSlotContainer withSlots:_globalSlots];
}

- (void)setInSectionSlots:(NSArray<KKTimingSlot *> *)inSectionSlots {
  _inSectionSlots = [inSectionSlots copy];
  [self updateSectionSlots];
}

- (void)setMidSectionSlots:(NSArray<KKTimingSlot *> *)midSectionSlots {
  _midSectionSlots = [midSectionSlots copy];
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
  case KKTimingGraphSectionMid:
    slots = _midSectionSlots;
    break;
  case KKTimingGraphSectionOut:
    slots = _outSectionSlots;
    break;
  }
  [self _populateContainer:_sectionSlotContainer withSlots:slots];
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

  NSRect midRect = [self graphRectForSection:KKTimingGraphSectionMid];
  CGFloat stackWidth = _midSeedStack.fittingSize.width;
  CGFloat stackHeight = _midSeedStack.fittingSize.height;
  CGFloat stackX = NSMidX(midRect) - stackWidth / 2.0;
  CGFloat stackY =
      graphTop + kGraphHeight + (kLabelRowHeight - stackHeight) / 2.0;
  _midSeedStack.frame = NSMakeRect(stackX, stackY, stackWidth, stackHeight);

  CGFloat viewWidth = NSWidth(self.bounds) - 2 * KKInspectorHorizontalInset;

  CGFloat slotsY = graphTop + kGraphHeight + kLabelRowHeight +
                   kSliderRowHeight + kTickHeight;

  if (!_globalSlotContainer.hidden) {
    NSSize globalSize = _globalSlotContainer.fittingSize;
    _globalSlotContainer.frame = NSMakeRect(KKInspectorHorizontalInset, slotsY,
                                            viewWidth, globalSize.height);
    slotsY += globalSize.height + KKSpacingSM;
  }

  if (!_sectionSlotContainer.hidden) {
    NSSize sectionSize = _sectionSlotContainer.fittingSize;
    _sectionSlotContainer.frame = NSMakeRect(KKInspectorHorizontalInset, slotsY,
                                             viewWidth, sectionSize.height);
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
