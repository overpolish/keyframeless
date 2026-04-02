/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKTimingGraphView.h"
#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCheckboxView.h"
#import "KKSliderView.h"
#import <AppKit/AppKit.h>

static const CGFloat kGraphHeight = 60.0;
static const CGFloat kLabelRowHeight = 20.0;
static const CGFloat kSliderRowHeight = 28.0;
static const CGFloat kTickHeight = 16.0;
static const CGFloat kTickWidth = 22.0;
static const CGFloat kCurvePadding = KKPaddingLG;
static const NSInteger kCurveSegments = 40;
static const NSInteger kTickSegments = 16;
static const NSInteger kGridRows = 4;
static const CGFloat kCheckboxSize = 12.0;

@implementation KKTimingGraphView {
  NSImageView *_graphImageView;
  KKCheckboxView *_inCheckbox;
  KKCheckboxView *_outCheckbox;
  KKSliderView *_curveSlider;
  NSImageView *_tickImageView;
  KKSliderView *_intensitySlider;
  NSImageView *_intensityTickImageView;
  KKSliderView *_frequencySlider;
  NSImageView *_frequencyTickImageView;
  NSStackView *_midSeedStack;
  NSButton *_seedButton;
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

    // --- Row 1: Curve type slider + ticks (top) ---

    _curveSlider = [KKSliderView styledSlider];
    _curveSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _curveSlider.minValue = 0;
    _curveSlider.maxValue = KKEasingCurveCount - 1;
    _curveSlider.doubleValue = KKEasingCurveEaseOut;
    _curveSlider.continuous = YES;
    _curveSlider.slider.allowsTickMarkValuesOnly = YES;
    _curveSlider.slider.numberOfTickMarks = KKEasingCurveCount;
    _curveSlider.hidden = YES;
    _curveSlider.target = self;
    _curveSlider.action = @selector(curveSliderChanged:);
    [self addSubview:_curveSlider];

    CGFloat curveSliderTop = 0;
    [NSLayoutConstraint activateConstraints:@[
      [_curveSlider.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset +
                                  kTickWidth / 2.0],
      [_curveSlider.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-(KKInspectorHorizontalInset +
                                    kTickWidth / 2.0)],
      [_curveSlider.topAnchor constraintEqualToAnchor:self.topAnchor
                                             constant:curveSliderTop],
      [_curveSlider.heightAnchor constraintEqualToConstant:kSliderRowHeight],
    ]];

    _tickImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _tickImageView.imageScaling = NSImageScaleNone;
    _tickImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _tickImageView.hidden = YES;
    [self addSubview:_tickImageView];

    CGFloat tickTop = curveSliderTop + kSliderRowHeight;
    [NSLayoutConstraint activateConstraints:@[
      [_tickImageView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_tickImageView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
      [_tickImageView.topAnchor constraintEqualToAnchor:self.topAnchor
                                               constant:tickTop],
      [_tickImageView.heightAnchor constraintEqualToConstant:kTickHeight],
    ]];

    // --- Row 2: Graph + labels ---

    CGFloat graphTop = tickTop + kTickHeight;

    _graphImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _graphImageView.imageScaling = NSImageScaleNone;
    _graphImageView.translatesAutoresizingMaskIntoConstraints = NO;
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

    // --- Row 3: Intensity slider + ticks ---

    CGFloat intensityTop = graphTop + kGraphHeight + kLabelRowHeight;

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

    [NSLayoutConstraint activateConstraints:@[
      [_intensitySlider.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset +
                                  kTickWidth / 2.0],
      [_intensitySlider.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-(KKInspectorHorizontalInset +
                                    kTickWidth / 2.0)],
      [_intensitySlider.topAnchor constraintEqualToAnchor:self.topAnchor
                                                 constant:intensityTop],
      [_intensitySlider.heightAnchor
          constraintEqualToConstant:kSliderRowHeight],
    ]];

    _intensityTickImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _intensityTickImageView.imageScaling = NSImageScaleNone;
    _intensityTickImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _intensityTickImageView.hidden = YES;
    [self addSubview:_intensityTickImageView];

    CGFloat intensityTickTop = intensityTop + kSliderRowHeight;
    [NSLayoutConstraint activateConstraints:@[
      [_intensityTickImageView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_intensityTickImageView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
      [_intensityTickImageView.topAnchor
          constraintEqualToAnchor:self.topAnchor
                         constant:intensityTickTop],
      [_intensityTickImageView.heightAnchor
          constraintEqualToConstant:kTickHeight],
    ]];

    // --- Row 4: Frequency slider + ticks ---

    CGFloat frequencyTop = intensityTickTop + kTickHeight;

    _frequencySlider = [KKSliderView styledSlider];
    _frequencySlider.translatesAutoresizingMaskIntoConstraints = NO;
    _frequencySlider.minValue = 0.0;
    _frequencySlider.maxValue = 1.0;
    _frequencySlider.doubleValue = 0.5;
    _frequencySlider.continuous = YES;
    _frequencySlider.trackFillColor = [NSColor accentMatchingHost];
    _frequencySlider.hidden = YES;
    _frequencySlider.target = self;
    _frequencySlider.action = @selector(frequencySliderChanged:);
    [self addSubview:_frequencySlider];

    [NSLayoutConstraint activateConstraints:@[
      [_frequencySlider.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset +
                                  kTickWidth / 2.0],
      [_frequencySlider.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-(KKInspectorHorizontalInset +
                                    kTickWidth / 2.0)],
      [_frequencySlider.topAnchor constraintEqualToAnchor:self.topAnchor
                                                 constant:frequencyTop],
      [_frequencySlider.heightAnchor
          constraintEqualToConstant:kSliderRowHeight],
    ]];

    _frequencyTickImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _frequencyTickImageView.imageScaling = NSImageScaleNone;
    _frequencyTickImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _frequencyTickImageView.hidden = YES;
    [self addSubview:_frequencyTickImageView];

    CGFloat frequencyTickTop = frequencyTop + kSliderRowHeight;
    [NSLayoutConstraint activateConstraints:@[
      [_frequencyTickImageView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_frequencyTickImageView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
      [_frequencyTickImageView.topAnchor
          constraintEqualToAnchor:self.topAnchor
                         constant:frequencyTickTop],
      [_frequencyTickImageView.heightAnchor
          constraintEqualToConstant:kTickHeight],
    ]];
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
  BOOL showIntensity = showIn || showOut || showMidIntensity;
  _intensitySlider.hidden = !showIntensity;
  _intensityTickImageView.hidden = !showIntensity;
  if (showIn)
    _intensitySlider.doubleValue = _inIntensity;
  else if (showOut)
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

// Section rects relative to the graph image (no outer inset — that's on the
// image view).
- (NSRect)sectionRectForSection:(KKTimingGraphSection)section
                          width:(CGFloat)totalWidth {
  CGFloat sectionWidth = floor(totalWidth / 3.0);
  CGFloat x = (CGFloat)section * sectionWidth;
  if (section == KKTimingGraphSectionOut)
    sectionWidth = totalWidth - x;
  return NSMakeRect(x, 0, sectionWidth, kGraphHeight);
}

// Section rects relative to self (includes inset offset for hit testing).
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
  CGFloat graphTop = kSliderRowHeight + kTickHeight;
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

- (void)renderGraph {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat graphWidth = NSWidth(self.bounds) - 2 * inset;
  if (graphWidth < 1)
    return;

  CGFloat totalHeight = kGraphHeight + kLabelRowHeight;
  // NSImage draws in non-flipped coordinates (y=0 at bottom).
  // Label row is at bottom (y=0..kLabelRowHeight), graph above it.
  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(graphWidth, totalHeight)];
  [image lockFocus];

  [[NSColor inspectorBackground] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, kLabelRowHeight,
                                                      graphWidth, kGraphHeight)
                                   xRadius:KKRadiusMD
                                   yRadius:KKRadiusMD] fill];

  // Offset grid and sections up by kLabelRowHeight for non-flipped coords
  NSAffineTransform *xform = [NSAffineTransform transform];
  [xform translateXBy:0 yBy:kLabelRowHeight];
  [xform concat];

  [self renderGridWithWidth:graphWidth];

  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    [self renderSection:s width:graphWidth];
  }

  // Reset transform for labels
  NSAffineTransform *reset = [NSAffineTransform transform];
  [reset translateXBy:0 yBy:-kLabelRowHeight];
  [reset concat];

  [self renderLabelsWithWidth:graphWidth];

  [image unlockFocus];
  _graphImageView.image = image;
}

- (void)renderGridWithWidth:(CGFloat)totalWidth {
  NSColor *gridColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.08];
  [gridColor setStroke];

  NSBezierPath *grid = [NSBezierPath bezierPath];
  grid.lineWidth = 0.5;

  CGFloat drawHeight = kGraphHeight - 2 * kCurvePadding;
  CGFloat drawWidth = totalWidth - 2 * kCurvePadding;
  CGFloat cellSize = drawHeight / (CGFloat)kGridRows;
  NSInteger cols = (NSInteger)floor(drawWidth / cellSize);
  CGFloat right = kCurvePadding + drawWidth;

  for (NSInteger i = 0; i <= kGridRows; i++) {
    CGFloat y = kCurvePadding + i * cellSize;
    [grid moveToPoint:NSMakePoint(kCurvePadding, y)];
    [grid lineToPoint:NSMakePoint(right, y)];
  }

  for (NSInteger i = 0; i <= cols; i++) {
    CGFloat x = kCurvePadding + i * cellSize;
    if (x > right)
      break;
    [grid moveToPoint:NSMakePoint(x, kCurvePadding)];
    [grid lineToPoint:NSMakePoint(x, kCurvePadding + drawHeight)];
  }

  [grid stroke];
}

- (void)globalCurveRangeMin:(CGFloat *)outMin max:(CGFloat *)outMax {
  CGFloat minVal = 0.0, maxVal = 1.0;
  KKEasingCurve curves[] = {_inCurve, _outCurve};
  BOOL enabled[] = {_inEnabled, _outEnabled};
  for (int c = 0; c < 2; c++) {
    if (!enabled[c])
      continue;
    for (NSInteger i = 0; i <= kCurveSegments; i++) {
      CGFloat t = (CGFloat)i / (CGFloat)kCurveSegments;
      double inten = (c == 0) ? _inIntensity : _outIntensity;
      double freq = (c == 0) ? _inFrequency : _outFrequency;
      CGFloat v = (c == 1) ? KKApplyEasing(1.0 - t, curves[c], inten, freq)
                           : KKApplyEasing(t, curves[c], inten, freq);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
  }
  if (_midHoldEffect != KKHoldEffectNone) {
    for (NSInteger i = 0; i <= kCurveSegments; i++) {
      CGFloat t = (CGFloat)i / (CGFloat)kCurveSegments;
      CGFloat v = KKApplyHoldEffect(t, _midHoldEffect, _midIntensity,
                                    _midFrequency, _midSeed);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
  }
  *outMin = minVal;
  *outMax = maxVal;
}

- (void)renderSection:(KKTimingGraphSection)section width:(CGFloat)totalWidth {
  NSRect rect = [self sectionRectForSection:section width:totalWidth];
  BOOL selected = (section == _selectedSection);

  if (selected) {
    NSColor *selColor =
        [[NSColor accentMatchingHost] colorWithAlphaComponent:0.1];
    [selColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect
                                     xRadius:KKRadiusMD
                                     yRadius:KKRadiusMD] fill];
  }

  BOOL enabled;
  switch (section) {
  case KKTimingGraphSectionIn:
    enabled = _inEnabled;
    break;
  case KKTimingGraphSectionOut:
    enabled = _outEnabled;
    break;
  default:
    enabled = YES;
    break;
  }

  NSColor *curveColor =
      enabled ? [NSColor accentMatchingHost]
              : [[NSColor inspectorLabel] colorWithAlphaComponent:0.3];
  [curveColor setStroke];

  NSBezierPath *curve = [NSBezierPath bezierPath];
  curve.lineWidth = enabled ? 2.0 : 1.0;

  if (!enabled) {
    CGFloat pattern[] = {4.0, 3.0};
    [curve setLineDash:pattern count:2 phase:0];
  }

  CGFloat curveLeft = NSMinX(rect);
  CGFloat curveRight = NSMaxX(rect);
  if (section == KKTimingGraphSectionIn)
    curveLeft = kCurvePadding;
  if (section == KKTimingGraphSectionOut)
    curveRight = totalWidth - kCurvePadding;
  CGFloat x0 = curveLeft;
  CGFloat w = curveRight - curveLeft;
  CGFloat yBottom = kCurvePadding;
  CGFloat yTop = kGraphHeight - kCurvePadding;

  // Use global range across both curves so all sections share the same scale
  CGFloat minVal = 0.0, maxVal = 1.0;
  [self globalCurveRangeMin:&minVal max:&maxVal];
  CGFloat range = maxVal - minVal;

  for (NSInteger i = 0; i <= kCurveSegments; i++) {
    CGFloat rawT = (CGFloat)i / (CGFloat)kCurveSegments;
    CGFloat easedT;

    switch (section) {
    case KKTimingGraphSectionIn:
      easedT = enabled
                   ? KKApplyEasing(rawT, _inCurve, _inIntensity, _inFrequency)
                   : 1.0;
      break;
    case KKTimingGraphSectionMid:
      easedT = KKApplyHoldEffect(rawT, _midHoldEffect, _midIntensity,
                                 _midFrequency, _midSeed);
      break;
    case KKTimingGraphSectionOut:
      easedT = enabled ? KKApplyEasing(1.0 - rawT, _outCurve, _outIntensity,
                                       _outFrequency)
                       : 1.0;
      break;
    }

    CGFloat normalized = (range > 0) ? (easedT - minVal) / range : easedT;
    CGFloat px = x0 + rawT * w;
    CGFloat py = yBottom + normalized * (yTop - yBottom);

    if (i == 0)
      [curve moveToPoint:NSMakePoint(px, py)];
    else
      [curve lineToPoint:NSMakePoint(px, py)];
  }

  [curve stroke];
}

- (void)renderLabelsWithWidth:(CGFloat)totalWidth {
  NSString *labels[] = {@"In", @"Mid", @"Out"};

  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    NSRect sRect = [self sectionRectForSection:s width:totalWidth];
    BOOL selected = (s == _selectedSection);

    NSDictionary *attrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : selected
          ? [NSColor inspectorLabel]
          : [[NSColor inspectorLabel] colorWithAlphaComponent:0.5],
    };
    NSSize labelSize = [labels[s] sizeWithAttributes:attrs];
    // Non-flipped: label row is at y=0..kLabelRowHeight
    CGFloat labelY = (kLabelRowHeight - labelSize.height) / 2.0;

    if (s == KKTimingGraphSectionMid && !_midSeedStack.hidden) {
      continue;
    }

    CGFloat labelX;
    if (s == KKTimingGraphSectionMid) {
      labelX = NSMidX(sRect) - labelSize.width / 2.0;
    } else {
      CGFloat groupWidth = labelSize.width + KKSpacingSM + kCheckboxSize;
      labelX = NSMidX(sRect) - groupWidth / 2.0;
    }
    [labels[s] drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:attrs];
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
}

- (void)renderTicksToImageView:(NSImageView *)imageView
                     tickCount:(NSInteger)tickCount
                   activeIndex:(NSInteger)activeIndex
                    valueBlock:
                        (CGFloat (^)(NSInteger tickIndex, CGFloat t))block {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat tickPad = kTickWidth / 2.0;
  CGFloat tickAreaWidth = NSWidth(self.bounds) - 2 * inset;
  if (tickAreaWidth < 1)
    return;

  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(tickAreaWidth, kTickHeight)];
  [image lockFocus];

  CGFloat sliderWidth = tickAreaWidth - 2 * tickPad;
  CGFloat knobInset = 9.5 / 2.0;
  CGFloat usableWidth = sliderWidth - 2 * knobInset;

  for (NSInteger i = 0; i < tickCount; i++) {
    CGFloat frac =
        (tickCount > 1) ? (CGFloat)i / (CGFloat)(tickCount - 1) : 0.5;
    CGFloat centerX = tickPad + knobInset + frac * usableWidth;
    NSRect tickRect =
        NSMakeRect(centerX - kTickWidth / 2.0, 0, kTickWidth, kTickHeight);
    [self renderTickInRect:tickRect
                    active:(i == activeIndex)
                     value:^CGFloat(CGFloat t) {
                       return block(i, t);
                     }];
  }

  [image unlockFocus];
  imageView.image = image;
}

- (void)renderTicks {
  BOOL isMid = _selectedSection == KKTimingGraphSectionMid;
  BOOL isOut = _selectedSection == KKTimingGraphSectionOut;
  NSInteger tickCount = isMid ? KKHoldEffectCount : KKEasingCurveCount;
  NSInteger activeVal = lround(_curveSlider.doubleValue);

  [self renderTicksToImageView:_tickImageView
                     tickCount:tickCount
                   activeIndex:activeVal
                    valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                      if (isMid)
                        return KKApplyHoldEffect(
                            t, (KKHoldEffect)idx, self->_midIntensity,
                            self->_midFrequency, self->_midSeed);
                      double inten =
                          isOut ? self->_outIntensity : self->_inIntensity;
                      double freq =
                          isOut ? self->_outFrequency : self->_inFrequency;
                      KKEasingCurve curve = (KKEasingCurve)idx;
                      return isOut ? KKApplyEasing(1.0 - t, curve, inten, freq)
                                   : KKApplyEasing(t, curve, inten, freq);
                    }];
}

static const NSInteger kIntensityTickCount = 5;

- (void)renderIntensityTicks {
  BOOL isOut = _selectedSection == KKTimingGraphSectionOut;
  BOOL isMid = _selectedSection == KKTimingGraphSectionMid;
  double currentIntensity;
  if (isMid)
    currentIntensity = _midIntensity;
  else if (isOut)
    currentIntensity = _outIntensity;
  else
    currentIntensity = _inIntensity;
  NSInteger nearest = lround(currentIntensity * (kIntensityTickCount - 1));

  if (isMid) {
    KKHoldEffect effect = _midHoldEffect;
    [self renderTicksToImageView:_intensityTickImageView
                       tickCount:kIntensityTickCount
                     activeIndex:nearest
                      valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                        double inten =
                            (double)idx / (double)(kIntensityTickCount - 1);
                        return KKApplyHoldEffect(t, effect, inten,
                                                 self->_midFrequency,
                                                 self->_midSeed);
                      }];
  } else {
    KKEasingCurve curve = isOut ? _outCurve : _inCurve;
    [self renderTicksToImageView:_intensityTickImageView
                       tickCount:kIntensityTickCount
                     activeIndex:nearest
                      valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                        double inten =
                            (double)idx / (double)(kIntensityTickCount - 1);
                        double freq =
                            isOut ? self->_outFrequency : self->_inFrequency;
                        return isOut
                                   ? KKApplyEasing(1.0 - t, curve, inten, freq)
                                   : KKApplyEasing(t, curve, inten, freq);
                      }];
  }
}

static const NSInteger kFrequencyTickCount = 5;

- (void)renderFrequencyTicks {
  BOOL isOut = _selectedSection == KKTimingGraphSectionOut;
  BOOL isMid = _selectedSection == KKTimingGraphSectionMid;
  double currentFrequency;
  if (isMid)
    currentFrequency = _midFrequency;
  else if (isOut)
    currentFrequency = _outFrequency;
  else
    currentFrequency = _inFrequency;
  NSInteger nearest = lround(currentFrequency * (kFrequencyTickCount - 1));

  if (isMid) {
    KKHoldEffect effect = _midHoldEffect;
    double inten = _midIntensity;
    [self renderTicksToImageView:_frequencyTickImageView
                       tickCount:kFrequencyTickCount
                     activeIndex:nearest
                      valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                        double freq =
                            (double)idx / (double)(kFrequencyTickCount - 1);
                        return KKApplyHoldEffect(t, effect, inten, freq,
                                                 self->_midSeed);
                      }];
  } else {
    KKEasingCurve curve = isOut ? _outCurve : _inCurve;
    double inten = isOut ? _outIntensity : _inIntensity;
    [self renderTicksToImageView:_frequencyTickImageView
                       tickCount:kFrequencyTickCount
                     activeIndex:nearest
                      valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                        double freq =
                            (double)idx / (double)(kFrequencyTickCount - 1);
                        return isOut
                                   ? KKApplyEasing(1.0 - t, curve, inten, freq)
                                   : KKApplyEasing(t, curve, inten, freq);
                      }];
  }
}

- (NSRect)tickHitRectForIndex:(NSInteger)index {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat tickPad = kTickWidth / 2.0;
  CGFloat sliderWidth = NSWidth(self.bounds) - 2 * inset - 2 * tickPad;
  CGFloat knobInset = 9.5 / 2.0;
  CGFloat usableWidth = sliderWidth - 2 * knobInset;
  CGFloat tickY = kSliderRowHeight;

  NSInteger tickCount = (_selectedSection == KKTimingGraphSectionMid)
                            ? KKHoldEffectCount
                            : KKEasingCurveCount;
  CGFloat frac =
      (tickCount > 1) ? (CGFloat)index / (CGFloat)(tickCount - 1) : 0.5;
  CGFloat centerX = inset + tickPad + knobInset + frac * usableWidth;
  return NSMakeRect(centerX - kTickWidth / 2.0, tickY, kTickWidth, kTickHeight);
}

- (NSRect)intensityTickHitRectForIndex:(NSInteger)index {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat tickPad = kTickWidth / 2.0;
  CGFloat sliderWidth = NSWidth(self.bounds) - 2 * inset - 2 * tickPad;
  CGFloat knobInset = 9.5 / 2.0;
  CGFloat usableWidth = sliderWidth - 2 * knobInset;
  CGFloat tickY = kSliderRowHeight + kTickHeight + kGraphHeight +
                  kLabelRowHeight + kSliderRowHeight;

  CGFloat frac = (kIntensityTickCount > 1)
                     ? (CGFloat)index / (CGFloat)(kIntensityTickCount - 1)
                     : 0.5;
  CGFloat centerX = inset + tickPad + knobInset + frac * usableWidth;
  return NSMakeRect(centerX - kTickWidth / 2.0, tickY, kTickWidth, kTickHeight);
}

- (NSRect)frequencyTickHitRectForIndex:(NSInteger)index {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat tickPad = kTickWidth / 2.0;
  CGFloat sliderWidth = NSWidth(self.bounds) - 2 * inset - 2 * tickPad;
  CGFloat knobInset = 9.5 / 2.0;
  CGFloat usableWidth = sliderWidth - 2 * knobInset;
  CGFloat tickY = kSliderRowHeight + kTickHeight + kGraphHeight +
                  kLabelRowHeight + kSliderRowHeight + kTickHeight +
                  kSliderRowHeight;

  CGFloat frac = (kFrequencyTickCount > 1)
                     ? (CGFloat)index / (CGFloat)(kFrequencyTickCount - 1)
                     : 0.5;
  CGFloat centerX = inset + tickPad + knobInset + frac * usableWidth;
  return NSMakeRect(centerX - kTickWidth / 2.0, tickY, kTickWidth, kTickHeight);
}

- (void)renderTickInRect:(NSRect)rect
                  active:(BOOL)active
                   value:(CGFloat (^)(CGFloat t))value {
  NSColor *color =
      active ? [NSColor accentMatchingHost]
             : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  [color setStroke];

  CGFloat pad = 2.0;
  CGFloat x0 = NSMinX(rect) + pad;
  CGFloat x1 = NSMaxX(rect) - pad;
  CGFloat yBot = NSMinY(rect) + pad;
  CGFloat yTop = NSMaxY(rect) - pad;
  CGFloat w = x1 - x0;

  CGFloat minVal = 0.0, maxVal = 1.0;
  for (NSInteger i = 0; i <= kTickSegments; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)kTickSegments;
    CGFloat v = value(t);
    if (v < minVal)
      minVal = v;
    if (v > maxVal)
      maxVal = v;
  }
  CGFloat range = maxVal - minVal;
  CGFloat h = yTop - yBot;

  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineWidth = active ? 1.5 : 1.0;

  for (NSInteger i = 0; i <= kTickSegments; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)kTickSegments;
    CGFloat v = value(t);
    CGFloat normalized = (range > 0) ? (v - minVal) / range : 0.5;
    CGFloat px = x0 + t * w;
    CGFloat py = yBot + normalized * h;

    if (i == 0)
      [path moveToPoint:NSMakePoint(px, py)];
    else
      [path lineToPoint:NSMakePoint(px, py)];
  }

  [path stroke];
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
