/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineMotionBlurSettingsView.h"

#import "KKConstants.h"
#import "KKLocalized.h"
#import "KKPillToggleRowView.h"
#import "KKPopoverHeaderView.h"
#import "KKShaderTypes.h"
#import "KKSliderView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTokens.h"
#import "KKValueTextField.h"
#import "NSColor+KKColors.h"

static NSTextField *_KKMBCaption(NSString *s) {
  NSTextField *l = [NSTextField labelWithString:s];
  l.translatesAutoresizingMaskIntoConstraints = NO;
  l.font = [NSFont systemFontOfSize:KKFontSizeSM];
  l.textColor = [NSColor inspectorLabel];
  return l;
}

static const double kMBDefaultShutter = 180.0;
static const KKMotionBlurTechnique kMBDefaultTechnique =
    KKMotionBlurTechniqueFast;
static const CGFloat kMBRowHeight = 24.0;
static const CGFloat kMBWidth = 252.0;

// Pill order maps 1:1 to KKMotionBlurTechnique (index 0 = Fast).
static NSArray<NSString *> *_KKMBTechniqueTitles(void) {
  return @[
    KKLoc(@"Fast", @"Motion blur technique: velocity reconstruction."),
    KKLoc(@"Accurate", @"Motion blur technique: sample accumulation.")
  ];
}

@implementation _KKMotionBlurSettingsView {
  KKSliderView *_shutterSlider;
  KKSliderView *_samplesSlider;
  KKValueTextField *_shutterField;
  KKValueTextField *_samplesField;
  NSButton *_shutterReset;
  NSButton *_samplesReset;
  KKPillToggleRowView *_techniquePill;
  NSButton *_techniqueReset;
  NSView *_samplesRow;
  NSLayoutConstraint *_samplesTopC;
  NSLayoutConstraint *_samplesHeightC;
  double _shutterAngle;
  NSInteger _samples;
  KKMotionBlurTechnique _technique;
  BOOL _supportsFast;
  NSInteger _defaultSamples;
}

- (instancetype)initWithShutterAngle:(double)shutterAngle
                             samples:(NSInteger)samples
                           technique:(KKMotionBlurTechnique)technique
                        supportsFast:(BOOL)supportsFast
                      defaultSamples:(NSInteger)defaultSamples {
  self = [super initWithFrame:NSMakeRect(0, 0, kMBWidth, 144)];
  if (!self)
    return nil;
  _shutterAngle = shutterAngle;
  _samples = samples;
  _supportsFast = supportsFast;
  _defaultSamples = defaultSamples;
  // A host that can't do Fast only ever runs Accurate, regardless of the blob.
  _technique = supportsFast ? technique : KKMotionBlurTechniqueAccurate;

  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Motion Blur", @"Section title: motion blur.")
         symbolName:@"figure.walk.motion"];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:header];

  // Quality pill row (Fast / Accurate) - only when the host supports Fast;
  // otherwise there's only one technique and a pill would be pointless.
  NSView *qualityRow = nil;
  if (_supportsFast)
    qualityRow = [self _buildTechniqueRow];

  KKSliderView *shSlider = nil, *spSlider = nil;
  KKValueTextField *shField = nil, *spField = nil;
  NSButton *shReset = nil, *spReset = nil;
  NSView *shutterRow =
      [self _buildRow:KKLoc(@"Shutter", @"Motion blur: shutter angle label.")
                         min:0.0
                         max:360.0
                       value:_shutterAngle
                defaultValue:kMBDefaultShutter
                      suffix:@"°"
             scaleBreakValue:0.0
          scaleBreakPosition:0.0
                      slider:&shSlider
                       field:&shField
                       reset:&shReset];
  // Samples slider: scale break so the useful low end (2–32) gets most of the
  // track, with 32–128 in the last quarter.
  _samplesRow =
      [self _buildRow:KKLoc(@"Samples", @"Motion blur: samples label.")
                         min:2.0
                         max:(double)KK_MOTION_BLUR_MAX_SAMPLES
                       value:(double)_samples
                defaultValue:(double)_defaultSamples
                      suffix:@""
             scaleBreakValue:32.0
          scaleBreakPosition:0.75
                      slider:&spSlider
                       field:&spField
                       reset:&spReset];
  _shutterSlider = shSlider;
  _shutterField = shField;
  _shutterReset = shReset;
  _samplesSlider = spSlider;
  _samplesField = spField;
  _samplesReset = spReset;
  [self addSubview:shutterRow];
  [self addSubview:_samplesRow];

  // The row above Shutter is the quality pill when present, else the header.
  NSLayoutYAxisAnchor *shutterTopAnchor =
      qualityRow ? qualityRow.bottomAnchor : header.bottomAnchor;

  NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray arrayWithArray:@[
    [self.widthAnchor constraintEqualToConstant:kMBWidth],

    [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                         constant:KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:self.topAnchor
                                     constant:KKPaddingMD],

    [shutterRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:KKPaddingMD],
    [shutterRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                              constant:-KKPaddingMD],
    [shutterRow.topAnchor constraintEqualToAnchor:shutterTopAnchor
                                         constant:KKSpacingSM],
    [shutterRow.heightAnchor constraintEqualToConstant:kMBRowHeight],

    [_samplesRow.leadingAnchor constraintEqualToAnchor:shutterRow.leadingAnchor],
    [_samplesRow.trailingAnchor
        constraintEqualToAnchor:shutterRow.trailingAnchor],
  ]];
  if (qualityRow) {
    [cs addObjectsFromArray:@[
      [qualityRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                               constant:KKPaddingMD],
      [qualityRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                constant:-KKPaddingMD],
      [qualityRow.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                           constant:KKSpacingSM],
      [qualityRow.heightAnchor constraintEqualToConstant:kMBRowHeight],
    ]];
  }
  // Samples sits last; its top gap + height collapse to 0 in Fast so the view
  // (and the popover) shrink to remove the row entirely.
  _samplesTopC = [_samplesRow.topAnchor constraintEqualToAnchor:shutterRow.bottomAnchor
                                                       constant:KKSpacingSM];
  _samplesHeightC = [_samplesRow.heightAnchor constraintEqualToConstant:kMBRowHeight];
  [cs addObjectsFromArray:@[
    _samplesTopC, _samplesHeightC,
    [_samplesRow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                             constant:-KKPaddingMD],
  ]];
  [NSLayoutConstraint activateConstraints:cs];

  [self _applySamplesVisibility];
  [self _updateResetVisibility];
  [self _resizeToFit];
  return self;
}

- (NSView *)_buildTechniqueRow {
  NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
  row.translatesAutoresizingMaskIntoConstraints = NO;

  NSTextField *caption =
      _KKMBCaption(KKLoc(@"Quality", @"Label: motion blur quality/technique."));

  KKPillToggleRowView *pill =
      [[KKPillToggleRowView alloc] initWithLabels:_KKMBTechniqueTitles()];
  pill.radioMode = YES;
  pill.grouped = YES;
  pill.hidesGroupTrack = YES; // inline selector, not a nav bar
  pill.translatesAutoresizingMaskIntoConstraints = NO;
  pill.states = @[
    @(_technique == KKMotionBlurTechniqueFast),
    @(_technique == KKMotionBlurTechniqueAccurate)
  ];
  __weak typeof(self) weak = self;
  pill.onToggled = ^(NSInteger index, BOOL isOn) {
    typeof(self) s = weak;
    if (!s || !isOn)
      return;
    s->_technique = (KKMotionBlurTechnique)index;
    [s _applySamplesVisibility];
    [s _updateResetVisibility];
    [s _resizeToFit];
    if (s.onChanged)
      s.onChanged(s->_shutterAngle, s->_samples, s->_technique);
  };
  _techniquePill = pill;

  NSButton *reset = KKResetToDefaultButton(self, @selector(_resetTapped:));
  _techniqueReset = reset;

  [row addSubview:caption];
  [row addSubview:pill];
  [row addSubview:reset];
  [NSLayoutConstraint activateConstraints:@[
    [caption.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
    [caption.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [caption.widthAnchor constraintEqualToConstant:54.0],

    // Right-aligned: the pill hugs the reset button (its trailing pinned), and
    // only grows leftward - matches the choice-pill rows (e.g. stroke markers).
    [pill.leadingAnchor
        constraintGreaterThanOrEqualToAnchor:caption.trailingAnchor
                                    constant:KKSpacingSM],
    [pill.trailingAnchor constraintEqualToAnchor:reset.leadingAnchor
                                        constant:-KKPaddingXS],
    [pill.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],

    [reset.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    [reset.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [reset.widthAnchor constraintEqualToConstant:15.0],
    [reset.heightAnchor constraintEqualToConstant:15.0],
  ]];
  [self addSubview:row];
  return row;
}

- (NSView *)_buildRow:(NSString *)title
                   min:(double)minValue
                   max:(double)maxValue
                 value:(double)value
          defaultValue:(double)defaultValue
                suffix:(NSString *)suffix
       scaleBreakValue:(double)sbValue
    scaleBreakPosition:(double)sbPosition
                slider:(KKSliderView **)outSlider
                 field:(KKValueTextField **)outField
                 reset:(NSButton **)outReset {
  (void)defaultValue; // visibility/reset use the shared default constants
  NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
  row.translatesAutoresizingMaskIntoConstraints = NO;

  NSTextField *caption = _KKMBCaption(title);

  KKSliderView *slider = [KKSliderView styledSlider];
  slider.translatesAutoresizingMaskIntoConstraints = NO;
  slider.minValue = minValue;
  slider.maxValue = maxValue;
  if (sbValue > 0.0) {
    slider.scaleBreakValue = sbValue;
    slider.scaleBreakPosition = sbPosition;
  }
  slider.doubleValue = value;
  slider.continuous = YES;
  slider.trackFillColor = [NSColor accentMatchingHost];
  slider.target = self;
  slider.action = @selector(_sliderMoved:);
  __weak typeof(self) weak = self;
  slider.onDragBegin = ^{
    if (weak.onDragBegin)
      weak.onDragBegin();
  };
  slider.onDragEnd = ^{
    if (weak.onDragEnd)
      weak.onDragEnd();
  };

  KKValueTextField *field = [KKValueTextField valueField];
  field.translatesAutoresizingMaskIntoConstraints = NO;
  field.stringValue = [NSString stringWithFormat:@"%.0f", value];
  field.target = self;
  field.action = @selector(_fieldChanged:);
  field.delegate = (id<NSTextFieldDelegate>)self;

  NSTextField *unit = _KKMBCaption(suffix ?: @"");
  unit.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.5];

  NSButton *reset = KKResetToDefaultButton(self, @selector(_resetTapped:));

  [row addSubview:caption];
  [row addSubview:slider];
  [row addSubview:field];
  [row addSubview:unit];
  [row addSubview:reset];

  [NSLayoutConstraint activateConstraints:@[
    [caption.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
    [caption.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [caption.widthAnchor constraintEqualToConstant:54.0],

    [slider.leadingAnchor constraintEqualToAnchor:caption.trailingAnchor
                                         constant:KKSpacingSM],
    [slider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [slider.trailingAnchor constraintEqualToAnchor:field.leadingAnchor
                                          constant:-KKSpacingSM],

    [field.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [field.widthAnchor constraintEqualToConstant:32.0],
    [field.trailingAnchor constraintEqualToAnchor:unit.leadingAnchor
                                         constant:-KKPaddingXS],

    [unit.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [unit.widthAnchor constraintEqualToConstant:12.0],
    [unit.trailingAnchor constraintEqualToAnchor:reset.leadingAnchor
                                        constant:-KKPaddingXS],

    [reset.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    [reset.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    [reset.widthAnchor constraintEqualToConstant:15.0],
    [reset.heightAnchor constraintEqualToConstant:15.0],
  ]];

  *outSlider = slider;
  *outField = field;
  *outReset = reset;
  return row;
}

// Samples only applies to Accurate (the accumulate path); in Fast the row is
// removed (collapsed to 0) rather than greyed.
- (void)_applySamplesVisibility {
  BOOL showSamples = (_technique == KKMotionBlurTechniqueAccurate);
  _samplesRow.hidden = !showSamples;
  _samplesTopC.constant = showSamples ? KKSpacingSM : 0.0;
  _samplesHeightC.constant = showSamples ? kMBRowHeight : 0.0;
}

- (void)_resizeToFit {
  [self layoutSubtreeIfNeeded];
  CGFloat h = [self fittingSize].height;
  if (h <= 0.0)
    return;
  NSRect f = self.frame;
  if (fabs(f.size.height - h) < 0.5)
    return;
  self.frame = NSMakeRect(f.origin.x, f.origin.y, kMBWidth, h);
  if (self.onLayoutChanged)
    self.onLayoutChanged();
}

- (void)_updateResetVisibility {
  _shutterReset.hidden = fabs(_shutterAngle - kMBDefaultShutter) < 1e-6;
  _samplesReset.hidden = (_samples == _defaultSamples);
  _techniqueReset.hidden = (_technique == kMBDefaultTechnique);
}

- (void)_sliderMoved:(id)sender {
  _shutterAngle = round(_shutterSlider.doubleValue);
  _samples = (NSInteger)round(_samplesSlider.doubleValue);
  if (!_shutterField.kkEditing)
    _shutterField.stringValue =
        [NSString stringWithFormat:@"%.0f", (double)_shutterAngle];
  if (!_samplesField.kkEditing)
    _samplesField.stringValue =
        [NSString stringWithFormat:@"%ld", (long)_samples];
  [self _updateResetVisibility];
  if (_onChanged)
    _onChanged(_shutterAngle, _samples, _technique);
}

- (void)_fieldChanged:(id)sender {
  _shutterAngle = MAX(0.0, MIN(360.0, _shutterField.doubleValue));
  _samples = MAX(2, MIN((NSInteger)KK_MOTION_BLUR_MAX_SAMPLES,
                        (NSInteger)round(_samplesField.doubleValue)));
  _shutterSlider.doubleValue = _shutterAngle;
  _samplesSlider.doubleValue = (double)_samples;
  _shutterField.stringValue =
      [NSString stringWithFormat:@"%.0f", (double)_shutterAngle];
  _samplesField.stringValue =
      [NSString stringWithFormat:@"%ld", (long)_samples];
  [self _updateResetVisibility];
  if (_onChanged)
    _onChanged(_shutterAngle, _samples, _technique);
}

- (void)_resetTapped:(id)sender {
  if (sender == _shutterReset)
    _shutterAngle = kMBDefaultShutter;
  else if (sender == _samplesReset)
    _samples = _defaultSamples;
  else if (sender == _techniqueReset)
    _technique = kMBDefaultTechnique;
  [self applyShutterAngle:_shutterAngle samples:_samples technique:_technique];
  if (_onChanged)
    _onChanged(_shutterAngle, _samples, _technique);
}

- (void)applyShutterAngle:(double)shutterAngle
                  samples:(NSInteger)samples
                technique:(KKMotionBlurTechnique)technique {
  _shutterAngle = shutterAngle;
  _samples = samples;
  _technique = _supportsFast ? technique : KKMotionBlurTechniqueAccurate;
  if (!_shutterField.kkEditing) {
    _shutterSlider.doubleValue = shutterAngle;
    _shutterField.stringValue =
        [NSString stringWithFormat:@"%.0f", shutterAngle];
  }
  if (!_samplesField.kkEditing) {
    _samplesSlider.doubleValue = (double)samples;
    _samplesField.stringValue =
        [NSString stringWithFormat:@"%ld", (long)samples];
  }
  _techniquePill.states = @[
    @(_technique == KKMotionBlurTechniqueFast),
    @(_technique == KKMotionBlurTechniqueAccurate)
  ];
  [self _applySamplesVisibility];
  [self _updateResetVisibility];
  [self _resizeToFit];
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (KKValueFieldHandleReturnCommand(self.window, commandSelector))
    return YES;
  return KKValueFieldHandleTabCommand((NSTextField *)control, commandSelector);
}

@end
