/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineMotionBlurSettingsView.h"

#import "KKConstants.h"
#import "KKLocalized.h"
#import "KKPopoverHeaderView.h"
#import "KKPopupSelectView.h"
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
static const NSInteger kMBDefaultSamples = 16;
static const KKMotionBlurMode kMBDefaultMode = KKMotionBlurModeTransitionsOnly;
// Dropdown order maps 1:1 to KKMotionBlurMode (index 0 = TransitionsOnly).
static NSArray<NSString *> *_KKMBModeTitles(void) {
  return @[
    KKLoc(@"Transitions only", @"Motion blur mode option."),
    KKLoc(@"Value changes", @"Motion blur mode option."),
    KKLoc(@"Always", @"Motion blur mode option.")
  ];
}

@implementation _KKMotionBlurSettingsView {
  KKSliderView *_shutterSlider;
  KKSliderView *_samplesSlider;
  KKValueTextField *_shutterField;
  KKValueTextField *_samplesField;
  NSButton *_shutterReset;
  NSButton *_samplesReset;
  KKPopupSelectView *_modePopup;
  NSButton *_modeReset;
  double _shutterAngle;
  NSInteger _samples;
  KKMotionBlurMode _mode;
}

- (instancetype)initWithShutterAngle:(double)shutterAngle
                             samples:(NSInteger)samples
                                mode:(KKMotionBlurMode)mode {
  self = [super initWithFrame:NSMakeRect(0, 0, 252, 144)];
  if (!self)
    return nil;
  _shutterAngle = shutterAngle;
  _samples = samples;
  _mode = mode;

  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Motion Blur", @"Section title: motion blur.")
         symbolName:@"figure.walk.motion"];
  [self addSubview:header];

  KKSliderView *shSlider = nil, *spSlider = nil;
  KKValueTextField *shField = nil, *spField = nil;
  NSButton *shReset = nil, *spReset = nil;
  // Samples slider: scale break so the useful low end (2–32) gets most of the
  // track, with 32–128 in the last quarter.
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
  NSView *samplesRow =
      [self _buildRow:KKLoc(@"Samples", @"Motion blur: samples label.")
                         min:2.0
                         max:(double)KK_MOTION_BLUR_MAX_SAMPLES
                       value:(double)_samples
                defaultValue:(double)kMBDefaultSamples
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
  [self addSubview:samplesRow];
  [self _updateResetVisibility];

  // "When" row: a styled dropdown picking the fire mode. Caption matches the
  // slider rows' gutter; the popup floats to the trailing edge.
  NSView *whenRow = [[NSView alloc] initWithFrame:NSZeroRect];
  whenRow.translatesAutoresizingMaskIntoConstraints = NO;
  NSTextField *whenCaption =
      _KKMBCaption(KKLoc(@"When", @"Label: when a setting applies."));
  KKPopupSelectView *modePopup =
      [[KKPopupSelectView alloc] initWithTitles:_KKMBModeTitles()];
  modePopup.translatesAutoresizingMaskIntoConstraints = NO;
  [modePopup selectIndex:(NSInteger)_mode];
  __weak typeof(self) weakSelf = self;
  modePopup.onSelectionChanged = ^(NSInteger idx) {
    typeof(self) s = weakSelf;
    if (!s)
      return;
    s->_mode = (KKMotionBlurMode)idx;
    [s _updateResetVisibility];
    if (s.onChanged)
      s.onChanged(s->_shutterAngle, s->_samples, s->_mode);
  };
  _modePopup = modePopup;
  NSButton *modeReset = KKResetToDefaultButton(self, @selector(_resetTapped:));
  _modeReset = modeReset;
  [whenRow addSubview:whenCaption];
  [whenRow addSubview:modePopup];
  [whenRow addSubview:modeReset];
  [self addSubview:whenRow];
  [self _updateResetVisibility];

  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                         constant:KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:self.topAnchor
                                     constant:KKPaddingMD],

    [shutterRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:KKPaddingMD],
    [shutterRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                              constant:-KKPaddingMD],
    [shutterRow.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                         constant:KKSpacingSM],

    [samplesRow.leadingAnchor constraintEqualToAnchor:shutterRow.leadingAnchor],
    [samplesRow.trailingAnchor
        constraintEqualToAnchor:shutterRow.trailingAnchor],
    [samplesRow.topAnchor constraintEqualToAnchor:shutterRow.bottomAnchor
                                         constant:KKSpacingSM],
    [samplesRow.heightAnchor constraintEqualToAnchor:shutterRow.heightAnchor],

    [whenRow.leadingAnchor constraintEqualToAnchor:shutterRow.leadingAnchor],
    [whenRow.trailingAnchor constraintEqualToAnchor:shutterRow.trailingAnchor],
    [whenRow.topAnchor constraintEqualToAnchor:samplesRow.bottomAnchor
                                      constant:KKSpacingSM],
    [whenRow.heightAnchor constraintEqualToAnchor:shutterRow.heightAnchor],
    [whenRow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                         constant:-KKPaddingMD],

    [whenCaption.leadingAnchor constraintEqualToAnchor:whenRow.leadingAnchor],
    [whenCaption.centerYAnchor constraintEqualToAnchor:whenRow.centerYAnchor],
    [whenCaption.widthAnchor constraintEqualToConstant:54.0],
    [modePopup.leadingAnchor constraintEqualToAnchor:whenCaption.trailingAnchor
                                            constant:KKSpacingSM],
    [modePopup.trailingAnchor constraintEqualToAnchor:modeReset.leadingAnchor
                                             constant:-KKPaddingXS],
    [modePopup.topAnchor constraintEqualToAnchor:whenRow.topAnchor],
    [modePopup.bottomAnchor constraintEqualToAnchor:whenRow.bottomAnchor],

    [modeReset.trailingAnchor constraintEqualToAnchor:whenRow.trailingAnchor],
    [modeReset.centerYAnchor constraintEqualToAnchor:whenRow.centerYAnchor],
    [modeReset.widthAnchor constraintEqualToConstant:15.0],
    [modeReset.heightAnchor constraintEqualToConstant:15.0],
  ]];
  return self;
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

    [row.heightAnchor constraintEqualToConstant:24.0],
  ]];

  *outSlider = slider;
  *outField = field;
  *outReset = reset;
  return row;
}

- (void)_updateResetVisibility {
  _shutterReset.hidden = fabs(_shutterAngle - kMBDefaultShutter) < 1e-6;
  _samplesReset.hidden = (_samples == kMBDefaultSamples);
  _modeReset.hidden = (_mode == kMBDefaultMode);
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
    _onChanged(_shutterAngle, _samples, _mode);
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
    _onChanged(_shutterAngle, _samples, _mode);
}

- (void)_resetTapped:(id)sender {
  if (sender == _shutterReset)
    _shutterAngle = kMBDefaultShutter;
  else if (sender == _samplesReset)
    _samples = kMBDefaultSamples;
  else if (sender == _modeReset)
    _mode = kMBDefaultMode;
  [self applyShutterAngle:_shutterAngle samples:_samples mode:_mode];
  if (_onChanged)
    _onChanged(_shutterAngle, _samples, _mode);
}

- (void)applyShutterAngle:(double)shutterAngle
                  samples:(NSInteger)samples
                     mode:(KKMotionBlurMode)mode {
  _shutterAngle = shutterAngle;
  _samples = samples;
  _mode = mode;
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
  [_modePopup selectIndex:(NSInteger)mode];
  [self _updateResetVisibility];
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (KKValueFieldHandleReturnCommand(self.window, commandSelector))
    return YES;
  return KKValueFieldHandleTabCommand((NSTextField *)control, commandSelector);
}

@end
