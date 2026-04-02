/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCheckboxView.h"
#import "KKSliderView.h"
#import "KKTimingGraphView_Private.h"
#import <AppKit/AppKit.h>

static const CGFloat kGraphHeight = 60.0;
static const CGFloat kLabelRowHeight = 20.0;
static const CGFloat kSliderRowHeight = 28.0;
static const CGFloat kTickHeight = 16.0;
static const CGFloat kTickWidth = 22.0;
static const CGFloat kCheckboxSize = 12.0;
static const NSInteger kIntensityTickCount = 5;
static const NSInteger kFrequencyTickCount = 5;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation KKTimingGraphView {
  KKCheckboxView *_inCheckbox;
  KKCheckboxView *_outCheckbox;
  KKSliderView *_intensitySlider;
  KKSliderView *_frequencySlider;
  NSButton *_seedButton;
}

#pragma clang diagnostic pop

@synthesize graphImageView = _graphImageView;
@synthesize tickImageView = _tickImageView;
@synthesize intensityTickImageView = _intensityTickImageView;
@synthesize frequencyTickImageView = _frequencyTickImageView;
@synthesize curveSlider = _curveSlider;
@synthesize midSeedStack = _midSeedStack;

- (void)_addSliderRow:(KKSliderView *__strong *)outSlider
        tickImageView:(NSImageView *__strong *)outTicks
                  top:(CGFloat)top
             minValue:(double)min
             maxValue:(double)max
         defaultValue:(double)def
            fillColor:(NSColor *)fillColor
               action:(SEL)action {
  KKSliderView *slider = [KKSliderView styledSlider];
  slider.translatesAutoresizingMaskIntoConstraints = NO;
  slider.minValue = min;
  slider.maxValue = max;
  slider.doubleValue = def;
  slider.continuous = YES;
  if (fillColor)
    slider.trackFillColor = fillColor;
  slider.hidden = YES;
  slider.target = self;
  slider.action = action;
  [self addSubview:slider];

  [NSLayoutConstraint activateConstraints:@[
    [slider.leadingAnchor
        constraintEqualToAnchor:self.leadingAnchor
                       constant:KKInspectorHorizontalInset + kTickWidth / 2.0],
    [slider.trailingAnchor
        constraintEqualToAnchor:self.trailingAnchor
                       constant:-(KKInspectorHorizontalInset +
                                  kTickWidth / 2.0)],
    [slider.topAnchor constraintEqualToAnchor:self.topAnchor constant:top],
    [slider.heightAnchor constraintEqualToConstant:kSliderRowHeight],
  ]];

  NSImageView *ticks = [[NSImageView alloc] initWithFrame:NSZeroRect];
  ticks.imageScaling = NSImageScaleNone;
  ticks.translatesAutoresizingMaskIntoConstraints = NO;
  [ticks setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                  forOrientation:
                                      NSLayoutConstraintOrientationHorizontal];
  ticks.hidden = YES;
  [self addSubview:ticks];

  CGFloat tickTop = top + kSliderRowHeight;
  [NSLayoutConstraint activateConstraints:@[
    [ticks.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                        constant:KKInspectorHorizontalInset],
    [ticks.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                         constant:-KKInspectorHorizontalInset],
    [ticks.topAnchor constraintEqualToAnchor:self.topAnchor constant:tickTop],
    [ticks.heightAnchor constraintEqualToConstant:kTickHeight],
  ]];

  *outSlider = slider;
  *outTicks = ticks;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _inEnabled = NO;
    _outEnabled = NO;
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

    // Row 1: Curve type slider + ticks
    CGFloat curveTop = 0;
    [self _addSliderRow:&_curveSlider
          tickImageView:&_tickImageView
                    top:curveTop
               minValue:0
               maxValue:KKEasingCurveCount - 1
           defaultValue:KKEasingCurveEaseOut
              fillColor:nil
                 action:@selector(curveSliderChanged:)];
    _curveSlider.slider.allowsTickMarkValuesOnly = YES;
    _curveSlider.slider.numberOfTickMarks = KKEasingCurveCount;

    // Row 2: Graph + labels
    CGFloat graphTop = curveTop + kSliderRowHeight + kTickHeight + KKSpacingLG;

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

    __weak typeof(self) weakSelf = self;
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

    // Row 3: Intensity slider + ticks
    CGFloat intensityTop = graphTop + kGraphHeight + kLabelRowHeight;
    [self _addSliderRow:&_intensitySlider
          tickImageView:&_intensityTickImageView
                    top:intensityTop
               minValue:0.0
               maxValue:1.0
           defaultValue:0.5
              fillColor:[NSColor accentMatchingHost]
                 action:@selector(intensitySliderChanged:)];

    // Row 4: Frequency slider + ticks
    CGFloat frequencyTop = intensityTop + kSliderRowHeight + kTickHeight;
    [self _addSliderRow:&_frequencySlider
          tickImageView:&_frequencyTickImageView
                    top:frequencyTop
               minValue:0.0
               maxValue:1.0
           defaultValue:0.5
              fillColor:[NSColor accentMatchingHost]
                 action:@selector(frequencySliderChanged:)];
  }
  return self;
}

- (void)curveSliderChanged:(id)sender {
  NSInteger val = lround(_curveSlider.doubleValue);
  switch (_selectedSection) {
  case KKTimingGraphSectionIn:
    _inCurve = (KKEasingCurve)val;
    if (self.onInCurveChanged)
      self.onInCurveChanged(_inCurve);
    break;
  case KKTimingGraphSectionOut:
    _outCurve = (KKEasingCurve)val;
    if (self.onOutCurveChanged)
      self.onOutCurveChanged(_outCurve);
    break;
  case KKTimingGraphSectionMid:
    _midHoldEffect = (KKHoldEffect)val;
    if (self.onMidHoldEffectChanged)
      self.onMidHoldEffectChanged(_midHoldEffect);
    break;
  }
  [self renderGraph];
  [self renderTicks];
  [self renderIntensityTicks];
  [self renderFrequencyTicks];
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
  [self renderIntensityTicks];
  [self renderFrequencyTicks];
}

- (void)seedButtonPressed:(id)sender {
  _midSeed = arc4random();
  if (self.onMidSeedChanged)
    self.onMidSeedChanged(_midSeed);
  [self renderGraph];
  [self renderTicks];
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
  [self renderFrequencyTicks];
}

- (void)updateCurveSlider {
  BOOL showIn = _selectedSection == KKTimingGraphSectionIn && _inEnabled;
  BOOL showOut = _selectedSection == KKTimingGraphSectionOut && _outEnabled;
  BOOL showMid = _selectedSection == KKTimingGraphSectionMid;
  BOOL show = showIn || showOut || showMid;

  _curveSlider.hidden = !show;
  _tickImageView.hidden = !show;
  if (showIn || showOut) {
    _curveSlider.maxValue = KKEasingCurveCount - 1;
    _curveSlider.slider.numberOfTickMarks = KKEasingCurveCount;
    _curveSlider.doubleValue = showIn ? _inCurve : _outCurve;
  } else if (showMid) {
    _curveSlider.maxValue = KKHoldEffectCount - 1;
    _curveSlider.slider.numberOfTickMarks = KKHoldEffectCount;
    _curveSlider.doubleValue = _midHoldEffect;
  }

  BOOL showMidIntensity = showMid && _midHoldEffect != KKHoldEffectNone;
  _midSeedStack.hidden = !showMidIntensity;

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

  BOOL showInFreq = showIn && (_inCurve == KKEasingCurveBounce ||
                               _inCurve == KKEasingCurveElastic);
  BOOL showOutFreq = showOut && (_outCurve == KKEasingCurveBounce ||
                                 _outCurve == KKEasingCurveElastic);
  BOOL showFrequency = showInFreq || showOutFreq || showMidIntensity;
  _frequencySlider.hidden = !showFrequency;
  _frequencyTickImageView.hidden = !showFrequency;
  if (showInFreq)
    _frequencySlider.doubleValue = _inFrequency;
  else if (showOutFreq)
    _frequencySlider.doubleValue = _outFrequency;
  else if (showMidIntensity)
    _frequencySlider.doubleValue = _midFrequency;

  if (show)
    [self renderTicks];
  if (showIntensity)
    [self renderIntensityTicks];
  if (showFrequency)
    [self renderFrequencyTicks];
}

- (void)setInEnabled:(BOOL)inEnabled {
  _inEnabled = inEnabled;
  _inCheckbox.isChecked = inEnabled;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setOutEnabled:(BOOL)outEnabled {
  _outEnabled = outEnabled;
  _outCheckbox.isChecked = outEnabled;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setInCurve:(KKEasingCurve)inCurve {
  _inCurve = inCurve;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setOutCurve:(KKEasingCurve)outCurve {
  _outCurve = outCurve;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setMidHoldEffect:(KKHoldEffect)midHoldEffect {
  _midHoldEffect = midHoldEffect;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setInIntensity:(double)inIntensity {
  _inIntensity = inIntensity;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setOutIntensity:(double)outIntensity {
  _outIntensity = outIntensity;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setSelectedSection:(KKTimingGraphSection)selectedSection {
  _selectedSection = selectedSection;
  [self updateCurveSlider];
  [self renderGraph];
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
  r.origin.y += kSliderRowHeight + kTickHeight;
  return r;
}

- (void)layout {
  [super layout];

  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightMedium],
  };
  CGFloat graphTop = kSliderRowHeight + kTickHeight + KKSpacingLG;
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

  [self updateCurveSlider];
  [self renderGraph];
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
}

- (NSRect)_hitRectForTickIndex:(NSInteger)index
                     tickCount:(NSInteger)tickCount
                         tickY:(CGFloat)tickY {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat tickPad = kTickWidth / 2.0;
  CGFloat sliderWidth = NSWidth(self.bounds) - 2 * inset - 2 * tickPad;
  CGFloat knobInset = 9.5 / 2.0;
  CGFloat usableWidth = sliderWidth - 2 * knobInset;
  CGFloat frac =
      (tickCount > 1) ? (CGFloat)index / (CGFloat)(tickCount - 1) : 0.5;
  CGFloat centerX = inset + tickPad + knobInset + frac * usableWidth;
  return NSMakeRect(centerX - kTickWidth / 2.0, tickY, kTickWidth, kTickHeight);
}

- (NSRect)tickHitRectForIndex:(NSInteger)index {
  NSInteger tickCount = (_selectedSection == KKTimingGraphSectionMid)
                            ? KKHoldEffectCount
                            : KKEasingCurveCount;
  return [self _hitRectForTickIndex:index
                          tickCount:tickCount
                              tickY:kSliderRowHeight];
}

- (NSRect)intensityTickHitRectForIndex:(NSInteger)index {
  return [self
      _hitRectForTickIndex:index
                 tickCount:kIntensityTickCount
                     tickY:kSliderRowHeight + kTickHeight + KKSpacingLG +
                           kGraphHeight + kLabelRowHeight + kSliderRowHeight];
}

- (NSRect)frequencyTickHitRectForIndex:(NSInteger)index {
  return [self
      _hitRectForTickIndex:index
                 tickCount:kFrequencyTickCount
                     tickY:kSliderRowHeight + kTickHeight + KKSpacingLG +
                           kGraphHeight + kLabelRowHeight + kSliderRowHeight +
                           kTickHeight + kSliderRowHeight];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

  if (!_frequencySlider.hidden) {
    for (NSInteger i = 0; i < kFrequencyTickCount; i++) {
      if (NSPointInRect(loc, [self frequencyTickHitRectForIndex:i])) {
        double val = (double)i / (double)(kFrequencyTickCount - 1);
        _frequencySlider.doubleValue = val;
        [self frequencySliderChanged:_frequencySlider];
        return;
      }
    }
  }

  if (!_intensitySlider.hidden) {
    for (NSInteger i = 0; i < kIntensityTickCount; i++) {
      if (NSPointInRect(loc, [self intensityTickHitRectForIndex:i])) {
        double val = (double)i / (double)(kIntensityTickCount - 1);
        _intensitySlider.doubleValue = val;
        [self intensitySliderChanged:_intensitySlider];
        return;
      }
    }
  }

  if (!_curveSlider.hidden) {
    NSInteger tickCount = (_selectedSection == KKTimingGraphSectionMid)
                              ? KKHoldEffectCount
                              : KKEasingCurveCount;
    for (NSInteger i = 0; i < tickCount; i++) {
      if (NSPointInRect(loc, [self tickHitRectForIndex:i])) {
        _curveSlider.doubleValue = i;
        [self curveSliderChanged:_curveSlider];
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
