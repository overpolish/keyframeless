/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineInspectorView.h"
#import "KKLocalized.h"
#import "KKTimelineInspectorView_Private.h"

#import "KKCheckboxView.h"
#import "KKCompoundPillBar.h"
#import "KKConstants.h"
#import "KKLabelView.h"
#import "KKMiniCanvasView.h"
#import "KKParameterRowView.h"
#import "KKPillToggleRowView.h"
#import "KKPopoverHeaderView.h"
#import "KKPopupSelectView.h"
#import "KKReorderListView.h"
#import "KKShaderTypes.h"
#import "KKSliderView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTokens.h"
#import "KKValueTextField.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKTimingCompat.h>

static const CGFloat kInspectorHeight = 220.0;
static const CGFloat kHeaderRowHeight = 28.0;
// The motion-blur parameter row sits in its own section below the box. The
// custom-UI height is fixed at init, so we reserve this once up front.
static const CGFloat kMotionBlurRowHeight = 28.0;
// The on-screen-control visibility row mirrors the motion-blur row's section
// below the box; same fixed height reserved up front.
static const CGFloat kOSCVisibilityRowHeight = 28.0;
// The property-order row mirrors the same section; gear-only (no checkbox).
static const CGFloat kParamOrderRowHeight = 28.0;
// Trailing margin that lands the checkbox on the native control gutter, same
// value KKCustomGroupHeaderView uses.
static const CGFloat kMBCheckboxTrailing = 23.0;

// Frosted overlay shown when the user tries to switch Advanced → Basic
// while the timeline has Advanced-only structure. Confirms "Switch anyway"
// (reseeds incompatible lanes to flat hold) or Cancel.
@interface _KKCompatBannerView : NSView
@property(nonatomic, copy, nullable) void (^onCancel)(void);
@property(nonatomic, copy, nullable) void (^onConfirm)(void);
@end

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

static NSTextField *_KKMBCaption(NSString *s) {
  NSTextField *l = [NSTextField labelWithString:s];
  l.translatesAutoresizingMaskIntoConstraints = NO;
  l.font = [NSFont systemFontOfSize:KKFontSizeSM];
  l.textColor = [NSColor inspectorLabel];
  return l;
}

// Motion-blur settings popover content: a "Motion Blur" header, then Shutter
// (degrees, 0–360) and Samples (count, 2–128), each a slider (accent track,
// like Radius) + a value field, then a "When" dropdown picking the fire mode.
// Real units so the numbers are meaningful - 180° is the natural shutter, and
// the sample count is explicit (a percentage just invites people to crank it to
// the max).
@interface _KKMotionBlurSettingsView : NSView <NSTextFieldDelegate>
@property(nonatomic, copy, nullable) void (^onChanged)
    (double shutterAngle, NSInteger samples, KKMotionBlurMode mode);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
- (instancetype)initWithShutterAngle:(double)shutterAngle
                             samples:(NSInteger)samples
                                mode:(KKMotionBlurMode)mode;
- (void)applyShutterAngle:(double)shutterAngle
                  samples:(NSInteger)samples
                     mode:(KKMotionBlurMode)mode;
@end

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
  return KKValueFieldHandleReturnCommand(self.window, commandSelector);
}

@end

@implementation KKTimelineInspectorView {
  id<PROAPIAccessing> _apiManager;
  KKTimelineTab _selectedTab;
  KKPillToggleRowView *_tabBar;
  KKPlayButton *_playButton;
  KKResetZoomButton *_resetButton;
  NSStackView *_accessoryStack;
  KKLoopButton *_loopButton;
  KKConstantsButton *_constantsButton;
  KKDetachButton *_detachButton;
  NSView *_contentView;
  _KKCompatBannerView *_compatBanner;
  KKTimelineLanesView *_basicView;
  KKParameterRowView *_mbRow;
  KKCheckboxView *_mbCheckbox;
  NSButton *_mbSettingsButton;
  NSPopover *_mbPopover;
  __weak _KKMotionBlurSettingsView *_mbSettingsView;
  BOOL _showsMotionBlurRow;
  KKParameterRowView *_oscRow;
  KKCheckboxView *_oscCheckbox;
  NSButton *_oscSettingsButton;
  NSPopover *_oscPopover;
  BOOL _showsOSCVisibilityRow;
  KKParameterRowView *_paramOrderRow;
  NSButton *_paramOrderButton;
  NSPopover *_paramOrderPopover;
  BOOL _showsParamOrderRow;
  double _mbShutterAngle;
  NSInteger _mbSamples;
  KKMotionBlurMode _mbMode;
  NSArray<KKLane *> *_availableLanes;
  BOOL _isDetachedCopy;
  BOOL _detachedAttached;
  __weak KKTimelineInspectorView *_detachedOwner;
  KKTimelineInspectorView *_detachedView;
  // Cached so the compat reseed can ask for Basic's frame-aligned end
  // (`outEndFrac = (clipDur - frameDur) / clipDur`) without round-tripping
  // through the basicView.
  double _clipDurationSeconds;
  double _frameDurationSeconds;
}

@synthesize basicLanesView = _basicView;
@synthesize constantsButton = _constantsButton;
@synthesize isDetachedCopy = _isDetachedCopy;

- (void)setGapPopoverExtraRows:
    (NSArray<NSView *> * (^)(KKGapPopoverPhase, NSString *, KKInterval *,
                             KKGapIntervalReader, KKGapIntervalMutator))block {
  _gapPopoverExtraRows = [block copy];
  _basicView.gapPopoverExtraRows = block;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSMakeRect(0, 0, 0, kInspectorHeight)];
  if (!self)
    return nil;
  _apiManager = apiManager;
  _availableLanes = [availableLanes copy];
  _selectedTab = (KKTimelineTab)activeTab;
  _constantsButtonTitle =
      KKLoc(@"Constants", @"Constants editor tab/section header.");
  // Read the subclass hooks once; the custom-UI height can't change after init.
  _showsMotionBlurRow = [self showsMotionBlurRow];
  _showsOSCVisibilityRow = [self showsOSCVisibilityRow];
  // Reordering is moot with 0/1 properties.
  _showsParamOrderRow = (_availableLanes.count >= 2);
  _mbShutterAngle = 180.0; // the natural shutter
  _mbSamples = 16;
  _mbMode = KKMotionBlurModeTransitionsOnly; // default; cheapest
  [self setFrameSize:NSMakeSize(0, [self _totalHeight])];
  self.autoresizingMask =
      NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

  NSView *box = [self _buildBox];
  [self _buildTabBar];
  [self _buildHeaderButtons:loopEnabled];
  NSView *headerRow = [self _buildHeaderRow:box];
  [self _buildContentArea:box availableLanes:availableLanes timeline:timeline];
  if (_showsMotionBlurRow)
    [self _buildMotionBlurRow];
  if (_showsOSCVisibilityRow)
    [self _buildOSCVisibilityRow];
  if (_showsParamOrderRow)
    [self _buildParamOrderRow];
  [self _installConstraints:box headerRow:headerRow];
  return self;
}

#pragma mark - Construction

- (NSView *)_buildBox {
  NSView *box = [[NSView alloc] init];
  box.translatesAutoresizingMaskIntoConstraints = NO;
  box.wantsLayer = YES;
  box.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.08].CGColor;
  box.layer.borderColor = NSColor.separatorColor.CGColor;
  box.layer.borderWidth = 1.0;
  box.layer.cornerRadius = 8.0;
  [self addSubview:box];
  return box;
}

- (void)_buildTabBar {
  NSArray<NSImage *> *tabIcons = @[
    [NSImage imageWithSystemSymbolName:@"sparkles"
              accessibilityDescription:nil],
    [NSImage imageWithSystemSymbolName:@"timeline.selection"
              accessibilityDescription:nil],
  ];
  _tabBar = [[KKPillToggleRowView alloc] initWithLabels:@[
    KKLoc(@"Basic", @"Timeline mode tab: basic."),
    KKLoc(@"Advanced", @"Timeline mode tab: advanced.")
  ]
                                                  icons:tabIcons];
  _tabBar.translatesAutoresizingMaskIntoConstraints = NO;
  _tabBar.radioMode = YES;
  _tabBar.grouped = YES;
  [_tabBar setState:(_selectedTab == KKTimelineTabBasic)
            atIndex:KKTimelineTabBasic];
  [_tabBar setState:(_selectedTab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  [self addSubview:_tabBar];

  __weak typeof(self) weak = self;
  _tabBar.onToggled = ^(NSInteger index, BOOL isOn) {
    if (!isOn)
      return;
    [weak _selectTab:(KKTimelineTab)index];
  };
}

- (void)_buildHeaderButtons:(BOOL)loopEnabled {
  __weak typeof(self) weak = self;

  _constantsButton = [[KKConstantsButton alloc] init];
  _constantsButton.translatesAutoresizingMaskIntoConstraints = NO;
  // Authoritative visibility is set from `_basicView.hasUnoptedLanes` once
  // it exists - a count-based check would wrongly hide this on reboot when
  // the persisted blob already has the (constant) lanes.
  _constantsButton.hidden = YES;
  [self addSubview:_constantsButton];

  _detachButton = [[KKDetachButton alloc] init];
  _detachButton.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_detachButton];
  _detachButton.onTapped = ^{
    if (weak.onToggleDetached)
      weak.onToggleDetached();
  };

  _playButton = [[KKPlayButton alloc] init];
  _playButton.translatesAutoresizingMaskIntoConstraints = NO;
  _playButton.onTapped = ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    // During a guide the inspector owns the play accent: each tap is a
    // deterministic toggle, so flip it locally instead of waiting on the
    // poll-inferred `setPlaying:` (which flickers under FCP's bursty
    // currentTime). The tap hook lets a Joyride step advance on the click.
    if (s->_guideOwnsPlayState)
      s->_playButton.playing = !s->_playButton.playing;
    if (s->_onPlaybackToggleTapped)
      s->_onPlaybackToggleTapped();
    if (s.onTogglePlayback)
      s.onTogglePlayback();
  };

  _loopButton = [[KKLoopButton alloc] init];
  _loopButton.translatesAutoresizingMaskIntoConstraints = NO;
  _loopButton.on = loopEnabled;
  _loopButton.onToggled = ^(BOOL isOn) {
    if (weak.onLoopToggled)
      weak.onLoopToggled(isOn);
  };

  _resetButton = [[KKResetZoomButton alloc] init];
  _resetButton.translatesAutoresizingMaskIntoConstraints = NO;
  _resetButton.onTapped = ^{
    [weak.basicLanesView resetZoom];
  };

  _accessoryStack = [[NSStackView alloc] init];
  _accessoryStack.translatesAutoresizingMaskIntoConstraints = NO;
  _accessoryStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _accessoryStack.spacing = KKSpacingSM;
  _accessoryStack.alignment = NSLayoutAttributeCenterY;
}

- (void)_remountAccessoryButtons {
  for (NSView *v in [_accessoryStack.arrangedSubviews copy]) {
    [_accessoryStack removeArrangedSubview:v];
    [v removeFromSuperview];
  }
  for (NSView *v in _basicView.accessoryButtons)
    [_accessoryStack addArrangedSubview:v];
}

- (NSView *)_buildHeaderRow:(NSView *)box {
  NSView *headerRow = [[NSView alloc] init];
  headerRow.translatesAutoresizingMaskIntoConstraints = NO;
  [box addSubview:headerRow];
  [headerRow addSubview:_playButton];
  [headerRow addSubview:_loopButton];
  [headerRow addSubview:_accessoryStack];
  [headerRow addSubview:_resetButton];
  return headerRow;
}

- (void)_buildContentArea:(NSView *)box
           availableLanes:(NSArray<KKLane *> *)availableLanes
                 timeline:(KKTimeline *)timeline {
  _contentView = [[NSView alloc] init];
  _contentView.translatesAutoresizingMaskIntoConstraints = NO;
  [box addSubview:_contentView];

  _basicView =
      [[KKTimelineLanesView alloc] initWithAvailableLanes:availableLanes
                                                 timeline:timeline];
  _basicView.translatesAutoresizingMaskIntoConstraints = NO;
  [_basicView setActiveTab:_selectedTab];
  [_contentView addSubview:_basicView];

  _constantsButton.hidden = !_basicView.hasUnoptedLanes;

  __weak typeof(self) weak = self;
  __weak KKConstantsButton *weakConstants = _constantsButton;
  __weak KKTimelineLanesView *weakBasic = _basicView;
  _constantsButton.onTapped = ^{
    KKTimelineLanesView *basic = weakBasic;
    KKConstantsButton *btn = weakConstants;
    if (basic && btn)
      [basic showStaticValuesPopoverFromView:btn];
  };
  _basicView.onTimelineMutated = ^(KKTimeline *updated) {
    KKTimelineInspectorView *strong = weak;
    KKTimelineLanesView *basic = weakBasic;
    KKConstantsButton *btn = weakConstants;
    if (basic && btn)
      btn.hidden = !basic.hasUnoptedLanes;
    if (strong.onTimelineMutated)
      strong.onTimelineMutated(updated);
  };
  _basicView.onDragBegin = ^{
    if (weak.onDragBegin)
      weak.onDragBegin();
  };
  _basicView.onDragEnd = ^{
    if (weak.onDragEnd)
      weak.onDragEnd();
  };
  _basicView.onScrub = ^(double frac) {
    if (weak.onScrub)
      weak.onScrub(frac);
  };
  _basicView.onZoomChanged = ^(BOOL zoomed) {
    KKTimelineInspectorView *strong = weak;
    strong->_resetButton.zoomed = zoomed;
  };
  _basicView.onBoundaryPreviewNeedsRender = ^{
    if (weak.onBoundaryPreviewNeedsRender)
      weak.onBoundaryPreviewNeedsRender();
  };
  _basicView.onAccessoryButtonsChanged = ^{
    [weak _remountAccessoryButtons];
  };
  // Render-mode pill lives inside the keypose-value popover header (owned
  // by _basicView's lanes view); forward picks back to the inspector's own
  // onRenderModeChanged. _basicView.renderMode is pushed from the host via
  // -setRenderMode: below.
  _basicView.onRenderModeChanged = ^(KKMiniCanvasRenderMode mode) {
    KKTimelineInspectorView *strong = weak;
    if (strong.onRenderModeChanged)
      strong.onRenderModeChanged(mode);
  };
  [self _remountAccessoryButtons];

  _compatBanner = [[_KKCompatBannerView alloc] init];
  _compatBanner.translatesAutoresizingMaskIntoConstraints = NO;
  _compatBanner.hidden = YES;
  _compatBanner.wantsLayer = YES;
  _compatBanner.layer.cornerRadius = KKRadiusMD;
  _compatBanner.layer.masksToBounds = YES;
  [_contentView addSubview:_compatBanner
                positioned:NSWindowAbove
                relativeTo:_basicView];
  [NSLayoutConstraint activateConstraints:@[
    [_compatBanner.leadingAnchor
        constraintEqualToAnchor:_contentView.leadingAnchor],
    [_compatBanner.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor],
    [_compatBanner.topAnchor constraintEqualToAnchor:_contentView.topAnchor],
    [_compatBanner.bottomAnchor
        constraintEqualToAnchor:_contentView.bottomAnchor],
  ]];
  _compatBanner.onCancel = ^{
    [weak _dismissCompatBanner];
  };
  _compatBanner.onConfirm = ^{
    [weak _confirmCompatSwitch];
  };
}

- (BOOL)showsMotionBlurRow {
  return YES;
}

- (BOOL)showsOSCVisibilityRow {
  return NO;
}

- (CGFloat)_totalHeight {
  return kInspectorHeight +
         (_showsMotionBlurRow ? kMotionBlurRowHeight + KKPaddingMD : 0.0) +
         (_showsOSCVisibilityRow ? kOSCVisibilityRowHeight + KKPaddingMD
                                 : 0.0) +
         (_showsParamOrderRow ? kParamOrderRowHeight + KKPaddingMD : 0.0);
}

// Builds one of the optional rows below the box - a labeled left view plus a
// 12pt checkbox in the native control gutter and an 18pt settings gear to its
// left. The motion-blur and on-screen-control rows share this so their layout
// can't drift; the caller wires the checkbox's `onToggle` (the gear's action is
// passed in). The checkbox/gear are returned through the out-params.
- (KKParameterRowView *)
    _buildTickGearRowWithParameterID:(UInt32)parameterID
                          iconSymbol:(NSString *)iconSymbol
                               title:(NSString *)title
                   gearAccessibility:(NSString *)gearAccessibility
                          gearAction:(SEL)gearAction
                        showCheckbox:(BOOL)showCheckbox
                            checkbox:
                                (KKCheckboxView *__strong _Nullable *_Nullable)
                                    outCheckbox
                          gearButton:
                              (NSButton *__strong _Nonnull *_Nonnull)outGear {
  KKParameterRowView *row =
      [[KKParameterRowView alloc] initWithFrame:NSZeroRect
                                     apiManager:_apiManager
                                    parameterId:parameterID];
  row.translatesAutoresizingMaskIntoConstraints = NO;

  // KKLabelView carries the native label inset/styling so the gutter lines up
  // with FCP's other param rows.
  NSImage *icon = [NSImage imageWithSystemSymbolName:iconSymbol
                            accessibilityDescription:title];
  row.leftView = [[KKLabelView alloc] initWithText:title icon:icon];

  // rightView must be a container (KKParameterRowView contract), not a bare
  // control. Checkbox sits in the native control gutter (same as
  // KKCustomGroupHeaderView); the settings gear sits just to its left.
  NSView *controls = [[NSView alloc] initWithFrame:NSZeroRect];
  KKCheckboxView *checkbox = nil;
  if (showCheckbox) {
    checkbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
    checkbox.translatesAutoresizingMaskIntoConstraints = NO;
    [controls addSubview:checkbox];
  }

  NSImage *gear = [NSImage imageWithSystemSymbolName:@"gearshape"
                            accessibilityDescription:gearAccessibility];
  NSButton *gearButton = [NSButton buttonWithImage:gear
                                            target:self
                                            action:gearAction];
  gearButton.bezelStyle = NSBezelStyleAccessoryBarAction;
  gearButton.bordered = NO;
  gearButton.contentTintColor = [NSColor accentMatchingHost];
  gearButton.translatesAutoresizingMaskIntoConstraints = NO;
  [controls addSubview:gearButton];

  NSMutableArray<NSLayoutConstraint *> *cs = [NSMutableArray array];
  if (checkbox) {
    [cs addObjectsFromArray:@[
      [checkbox.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor
                                              constant:-kMBCheckboxTrailing],
      [checkbox.centerYAnchor constraintEqualToAnchor:controls.centerYAnchor],
      [checkbox.widthAnchor constraintEqualToConstant:12.0],
      [checkbox.heightAnchor constraintEqualToConstant:12.0],
      [gearButton.trailingAnchor constraintEqualToAnchor:checkbox.leadingAnchor
                                                constant:-KKSpacingMD],
    ]];
  } else {
    // No checkbox: center the 18pt gear on the 12pt checkbox column above it
    // (offset the trailing edge by half the width difference) so the glyphs
    // share a centerline rather than just a trailing edge.
    [cs addObject:[gearButton.trailingAnchor
                      constraintEqualToAnchor:controls.trailingAnchor
                                     constant:-(kMBCheckboxTrailing -
                                                (18.0 - 12.0) / 2.0)]];
  }
  [cs addObjectsFromArray:@[
    [gearButton.centerYAnchor constraintEqualToAnchor:controls.centerYAnchor],
    [gearButton.widthAnchor constraintEqualToConstant:18.0],
    [gearButton.heightAnchor constraintEqualToConstant:18.0],
  ]];
  [NSLayoutConstraint activateConstraints:cs];
  row.rightView = controls;

  if (outCheckbox)
    *outCheckbox = checkbox;
  *outGear = gearButton;
  return row;
}

- (void)_buildMotionBlurRow {
  // figure.walk.motion = the walking figure with motion lines, the same icon
  // the old native MB group header used.
  _mbRow = [self
      _buildTickGearRowWithParameterID:kKKParamMotionBlurData
                            iconSymbol:@"figure.walk.motion"
                                 title:KKLoc(@"Motion Blur",
                                             @"Section title: motion blur.")
                     gearAccessibility:KKLoc(@"Motion Blur settings",
                                             @"Accessibility: motion blur "
                                             @"settings.")
                            gearAction:@selector(_mbSettingsClicked:)
                          showCheckbox:YES
                              checkbox:&_mbCheckbox
                            gearButton:&_mbSettingsButton];

  __weak typeof(self) weak = self;
  _mbCheckbox.onToggle = ^(BOOL isChecked) {
    KKTimelineInspectorView *strong = weak;
    if (!strong)
      return;
    strong->_mbSettingsButton.enabled = isChecked;
    if (strong.onMotionBlurChanged)
      strong.onMotionBlurChanged(isChecked, strong->_mbShutterAngle,
                                 strong->_mbSamples, strong->_mbMode);
  };

  [self addSubview:_mbRow];
}

- (void)_buildOSCVisibilityRow {
  _oscRow = [self
      _buildTickGearRowWithParameterID:0
                            iconSymbol:@"scope"
                                 title:KKLoc(@"On-Screen Controls",
                                             @"Section title: viewer on-screen "
                                             @"controls visibility.")
                     gearAccessibility:KKLoc(@"On-screen control settings",
                                             @"Accessibility: per-element OSC "
                                             @"visibility settings.")
                            gearAction:@selector(_oscSettingsClicked:)
                          showCheckbox:YES
                              checkbox:&_oscCheckbox
                            gearButton:&_oscSettingsButton];
  _oscCheckbox.isChecked = YES;

  __weak typeof(self) weak = self;
  _oscCheckbox.onToggle = ^(BOOL isChecked) {
    KKTimelineInspectorView *strong = weak;
    if (!strong)
      return;
    // Per-element pills are moot when everything is hidden - mirror the
    // motion-blur gear, which disables while the effect is off.
    strong->_oscSettingsButton.enabled = isChecked;
    if (strong.onOSCVisibleToggled)
      strong.onOSCVisibleToggled(isChecked);
  };

  [self addSubview:_oscRow];
}

- (void)_buildParamOrderRow {
  KKCheckboxView *unused = nil;
  _paramOrderRow = [self
      _buildTickGearRowWithParameterID:0
                            iconSymbol:@"arrow.up.arrow.down"
                                 title:KKLoc(
                                           @"Parameter Order",
                                           @"Section title: parameter display "
                                           @"order in the timeline.")
                     gearAccessibility:KKLoc(@"Reorder parameters",
                                             @"Accessibility: drag-to-reorder "
                                             @"the parameter list.")
                            gearAction:@selector(_paramOrderClicked:)
                          showCheckbox:NO
                              checkbox:&unused
                            gearButton:&_paramOrderButton];
  [self addSubview:_paramOrderRow];
}

- (void)_paramOrderClicked:(id)sender {
  if (_paramOrderPopover.isShown) {
    [_paramOrderPopover close];
    return;
  }
  NSArray<NSString *> *labels = [_basicView orderedParamLabels];
  if (labels.count < 2)
    return;
  NSMutableArray<NSString *> *titles =
      [NSMutableArray arrayWithCapacity:labels.count];
  for (NSString *label in labels)
    [titles addObject:KKLocalizedParamName(label)];

  KKReorderListView *list = [[KKReorderListView alloc] initWithItemIDs:labels
                                                                titles:titles];
  list.translatesAutoresizingMaskIntoConstraints = NO;
  __weak typeof(self) weak = self;
  list.onReorder = ^(NSArray<NSString *> *newOrder) {
    KKTimelineInspectorView *strong = weak;
    [strong->_basicView applyParamOrder:newOrder];
  };

  // Wrap in the lanes-view popover content view for the macOS 26 liquid-glass
  // double-border fix (same as the motion-blur / OSC popovers).
  _KKLVPopoverContentView *content = [[_KKLVPopoverContentView alloc] init];
  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Parameter Order",
                          @"Section title: parameter display order in the "
                          @"timeline.")
             detail:KKLoc(@"Drag to reorder",
                          @"Popover hint: drag rows to reorder parameters.")
         symbolName:@"arrow.up.arrow.down"];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:header];
  [content addSubview:list];
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                         constant:KKPaddingMD],
    [header.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                          constant:-KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:content.topAnchor
                                     constant:KKPaddingMD],
    [list.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                       constant:KKPaddingMD],
    [list.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                        constant:-KKPaddingMD],
    [list.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                   constant:KKPaddingSM],
    [list.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                      constant:-KKPaddingMD],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = content;
  _paramOrderPopover = [[NSPopover alloc] init];
  _paramOrderPopover.behavior = NSPopoverBehaviorTransient;
  _paramOrderPopover.contentViewController = vc;
  _paramOrderPopover.contentSize = content.fittingSize;
  [_paramOrderPopover showRelativeToRect:_paramOrderButton.bounds
                                  ofView:_paramOrderButton
                           preferredEdge:NSRectEdgeMinY];
}

- (void)_oscSettingsClicked:(id)sender {
  if (_oscPopover.isShown) {
    [_oscPopover close];
    return;
  }
  NSArray<NSArray<NSString *> *> *compounds = self.oscVisibilityCompounds;
  if (!compounds.count)
    return;

  // Localize the display label of each segment (its last dot-separated
  // component, so @"Rotation.X" reads as "X").
  NSMutableArray<NSArray<NSString *> *> *labels = [NSMutableArray array];
  for (NSArray<NSString *> *compound in compounds) {
    NSMutableArray<NSString *> *group = [NSMutableArray array];
    for (NSString *key in compound) {
      NSString *leaf = [key componentsSeparatedByString:@"."].lastObject ?: key;
      [group addObject:KKLocalizedParamName(leaf)];
    }
    [labels addObject:group];
  }

  KKCompoundPillBar *bar = [[KKCompoundPillBar alloc] initWithCompounds:labels];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  NSArray<NSArray<NSNumber *> *> *states =
      self.oscVisibilityElementStates ? self.oscVisibilityElementStates() : nil;
  if (states.count == compounds.count)
    bar.states = states;
  __weak typeof(self) weak = self;
  bar.onToggled = ^(NSInteger compoundIdx, NSInteger segIdx, BOOL isOn) {
    KKTimelineInspectorView *strong = weak;
    if (strong.oscVisibilityElementToggled)
      strong.oscVisibilityElementToggled(compoundIdx, segIdx, isOn);
  };

  // Wrap in the lanes-view popover content view so the macOS 26 liquid-glass
  // double-border fix applies (same as the motion-blur / curve popovers).
  _KKLVPopoverContentView *content = [[_KKLVPopoverContentView alloc] init];
  [content addSubview:bar];
  [NSLayoutConstraint activateConstraints:@[
    [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                      constant:KKPaddingMD],
    [bar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                       constant:-KKPaddingMD],
    [bar.topAnchor constraintEqualToAnchor:content.topAnchor
                                  constant:KKPaddingMD],
    [bar.bottomAnchor constraintEqualToAnchor:content.bottomAnchor
                                     constant:-KKPaddingMD],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = content;
  _oscPopover = [[NSPopover alloc] init];
  _oscPopover.behavior = NSPopoverBehaviorTransient;
  _oscPopover.contentViewController = vc;
  _oscPopover.contentSize = content.fittingSize;
  [_oscPopover showRelativeToRect:_oscSettingsButton.bounds
                           ofView:_oscSettingsButton
                    preferredEdge:NSRectEdgeMinY];
}

- (void)setOSCVisible:(BOOL)visible {
  _oscCheckbox.isChecked = visible;
  _oscSettingsButton.enabled = visible;
}

- (void)setMotionBlurEnabled:(BOOL)enabled {
  _mbCheckbox.isChecked = enabled;
  _mbSettingsButton.enabled = enabled;
}

- (void)setMotionBlurShutterAngle:(double)shutterAngle
                          samples:(NSInteger)samples {
  _mbShutterAngle = shutterAngle;
  _mbSamples = samples;
  [_mbSettingsView applyShutterAngle:shutterAngle samples:samples mode:_mbMode];
}

- (void)setMotionBlurMode:(KKMotionBlurMode)mode {
  _mbMode = mode;
  [_mbSettingsView applyShutterAngle:_mbShutterAngle
                             samples:_mbSamples
                                mode:mode];
}

- (void)_mbSettingsClicked:(id)sender {
  if (_mbPopover.isShown) {
    [_mbPopover close];
    return;
  }
  _KKMotionBlurSettingsView *content =
      [[_KKMotionBlurSettingsView alloc] initWithShutterAngle:_mbShutterAngle
                                                      samples:_mbSamples
                                                         mode:_mbMode];
  __weak typeof(self) weak = self;
  content.onChanged =
      ^(double shutterAngle, NSInteger samples, KKMotionBlurMode mode) {
        KKTimelineInspectorView *strong = weak;
        if (!strong)
          return;
        strong->_mbShutterAngle = shutterAngle;
        strong->_mbSamples = samples;
        strong->_mbMode = mode;
        if (strong.onMotionBlurChanged)
          strong.onMotionBlurChanged(strong->_mbCheckbox.isChecked,
                                     shutterAngle, samples, mode);
      };
  content.onDragBegin = ^{
    if (weak.onDragBegin)
      weak.onDragBegin();
  };
  content.onDragEnd = ^{
    if (weak.onDragEnd)
      weak.onDragEnd();
  };
  _mbSettingsView = content;

  // Reuse the lanes view's popover wrapper so the macOS 26 liquid-glass
  // double-border fix (CoreHostingView/ContentHolderView clear) applies here
  // too - same as the constants / curve popovers.
  _KKLVPopoverContentView *wrapper = [[_KKLVPopoverContentView alloc] init];
  wrapper.frame = content.bounds;
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
    [content.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
    [content.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [content.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = wrapper;
  _mbPopover = [[NSPopover alloc] init];
  _mbPopover.contentViewController = vc;
  _mbPopover.behavior = NSPopoverBehaviorTransient;
  _mbPopover.contentSize = content.frame.size;
  [_mbPopover showRelativeToRect:_mbSettingsButton.bounds
                          ofView:_mbSettingsButton
                   preferredEdge:NSRectEdgeMaxY];
}

- (void)_installConstraints:(NSView *)box headerRow:(NSView *)headerRow {
  CGFloat h = KKInspectorHorizontalInset;
  [NSLayoutConstraint activateConstraints:@[
    [_tabBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:h],
    [_tabBar.topAnchor constraintEqualToAnchor:self.topAnchor
                                      constant:KKPaddingMD],

    [_constantsButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                    constant:-h],
    [_constantsButton.centerYAnchor
        constraintEqualToAnchor:_tabBar.centerYAnchor],

    [_detachButton.leadingAnchor constraintEqualToAnchor:_tabBar.trailingAnchor
                                                constant:KKPaddingMD],
    [_detachButton.centerYAnchor constraintEqualToAnchor:_tabBar.centerYAnchor],

    [box.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:h],
    [box.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                       constant:-h],
    [box.topAnchor constraintEqualToAnchor:_tabBar.bottomAnchor
                                  constant:KKPaddingMD],

    [headerRow.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
    [headerRow.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
    [headerRow.topAnchor constraintEqualToAnchor:box.topAnchor],
    [headerRow.heightAnchor constraintEqualToConstant:kHeaderRowHeight],

    [_playButton.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor
                                              constant:KKPaddingMD],
    [_playButton.centerYAnchor constraintEqualToAnchor:headerRow.centerYAnchor],
    [_loopButton.leadingAnchor
        constraintEqualToAnchor:_playButton.trailingAnchor
                       constant:KKSpacingSM],
    [_loopButton.centerYAnchor constraintEqualToAnchor:headerRow.centerYAnchor],
    [_resetButton.trailingAnchor
        constraintEqualToAnchor:headerRow.trailingAnchor
                       constant:-KKPaddingMD],
    [_resetButton.centerYAnchor
        constraintEqualToAnchor:headerRow.centerYAnchor],
    [_accessoryStack.trailingAnchor
        constraintEqualToAnchor:_resetButton.leadingAnchor
                       constant:-KKSpacingSM],
    [_accessoryStack.centerYAnchor
        constraintEqualToAnchor:headerRow.centerYAnchor],

    [_contentView.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
    [_contentView.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
    [_contentView.topAnchor constraintEqualToAnchor:headerRow.bottomAnchor],
    [_contentView.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],

    [_basicView.leadingAnchor
        constraintEqualToAnchor:_contentView.leadingAnchor],
    [_basicView.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor],
    [_basicView.topAnchor constraintEqualToAnchor:_contentView.topAnchor],
    [_basicView.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor],
  ]];

  // Optional parameter rows stack in their own section below the box,
  // top-to-bottom: OSC-visibility then motion-blur. Full width (no box inset):
  // KKParameterRowView aligns its own label gutter + control region to match
  // FCP's native param rows, which span edge to edge. With no extra rows the
  // box runs to the bottom of the view (original layout).
  NSMutableArray<NSView *> *bottomRows = [NSMutableArray array];
  NSMutableArray<NSNumber *> *bottomRowHeights = [NSMutableArray array];
  if (_showsOSCVisibilityRow && _oscRow) {
    [bottomRows addObject:_oscRow];
    [bottomRowHeights addObject:@(kOSCVisibilityRowHeight)];
  }
  if (_showsMotionBlurRow && _mbRow) {
    [bottomRows addObject:_mbRow];
    [bottomRowHeights addObject:@(kMotionBlurRowHeight)];
  }
  if (_showsParamOrderRow && _paramOrderRow) {
    [bottomRows addObject:_paramOrderRow];
    [bottomRowHeights addObject:@(kParamOrderRowHeight)];
  }

  if (bottomRows.count == 0) {
    [box.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                     constant:-KKPaddingLG]
        .active = YES;
  } else {
    NSView *above = box;
    for (NSInteger i = 0; i < (NSInteger)bottomRows.count; i++) {
      NSView *row = bottomRows[i];
      [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [row.heightAnchor
            constraintEqualToConstant:bottomRowHeights[i].doubleValue],
        [above.bottomAnchor constraintEqualToAnchor:row.topAnchor
                                           constant:-KKPaddingMD],
      ]];
      above = row;
    }
    [above.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                       constant:-KKPaddingLG]
        .active = YES;
  }
}

#pragma mark - Configuration propagation

- (void)setMiniCanvasDescriptorPath:(NSString *)path {
  _miniCanvasDescriptorPath = [path copy];
  _basicView.miniCanvasDescriptorPath = path;
}

- (void)setMiniCanvasRequestPath:(NSString *)path {
  _miniCanvasRequestPath = [path copy];
  _basicView.miniCanvasRequestPath = path;
}

- (void)setMiniCanvasDelegate:(id<KKMiniCanvasDelegate>)delegate {
  _miniCanvasDelegate = delegate;
  _basicView.miniCanvasDelegate = delegate;
}

- (void)setManagePopoverSpotlightLabel:(NSString *)label {
  _managePopoverSpotlightLabel = [label copy];
  _basicView.managePopoverSpotlightLabel = label;
}

#pragma mark - Tab + live push

- (void)_selectTab:(KKTimelineTab)tab {
  // Advanced → Basic with incompatible structure: show the overlay and
  // keep the tab on Advanced until the user confirms or cancels. The
  // tab-bar state was already flipped by the user's click so revert it.
  if (tab == KKTimelineTabBasic && _selectedTab != KKTimelineTabBasic &&
      !KKTimelineIsBasicCompatible(_basicView.currentTimeline)) {
    [_tabBar setState:NO atIndex:KKTimelineTabBasic];
    [_tabBar setState:YES atIndex:KKTimelineTabAdvanced];
    _compatBanner.hidden = NO;
    [_basicView setOverlayBlockingInteractions:YES];
    return;
  }
  _selectedTab = tab;
  [_tabBar setState:(tab == KKTimelineTabBasic) atIndex:KKTimelineTabBasic];
  [_tabBar setState:(tab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  [_basicView setActiveTab:tab];
  if (_onTabChanged)
    _onTabChanged(tab);
  if (_onGuideTabChanged)
    _onGuideTabChanged(tab);
}

- (void)_dismissCompatBanner {
  _compatBanner.hidden = YES;
  [_basicView setOverlayBlockingInteractions:NO];
}

- (void)_confirmCompatSwitch {
  // Basic stores the lane-end at `outEndFrac` (one frame before clip end),
  // not at 1.0 - feeding the reseed that value keeps the produced lanes
  // shaped exactly like Basic itself would emit, so switching the tab
  // doesn't show a stray pill past Basic's end marker.
  double endFrac = 1.0;
  if (_clipDurationSeconds > 0.0 && _frameDurationSeconds > 0.0 &&
      _frameDurationSeconds < _clipDurationSeconds)
    endFrac =
        (_clipDurationSeconds - _frameDurationSeconds) / _clipDurationSeconds;
  KKTimeline *reseeded =
      KKTimelineReseedToBasic(_basicView.currentTimeline, endFrac);
  [_basicView applyTimeline:reseeded];
  [_detachedView applyTimeline:reseeded];
  if (_onTimelineMutated)
    _onTimelineMutated(reseeded);
  _compatBanner.hidden = YES;
  [_basicView setOverlayBlockingInteractions:NO];
  [self _selectTab:KKTimelineTabBasic];
}

- (NSInteger)activeTab {
  return (NSInteger)_selectedTab;
}

- (void)setRenderMode:(KKMiniCanvasRenderMode)mode {
  _basicView.renderMode = mode;
}

- (KKMiniCanvasRenderMode)renderMode {
  return _basicView.renderMode;
}

- (void)setActiveTab:(NSInteger)tab {
  BOOL changed = (_selectedTab != (KKTimelineTab)tab);
  _selectedTab = (KKTimelineTab)tab;
  [_tabBar setState:(tab == KKTimelineTabBasic) atIndex:KKTimelineTabBasic];
  [_tabBar setState:(tab == KKTimelineTabAdvanced)
            atIndex:KKTimelineTabAdvanced];
  [_basicView setActiveTab:tab];
  [_detachedView setActiveTab:tab];
  // Mirror the user-tap path so external switches (guides, restore-from-
  // saved-state on a remount) also persist via the host's onTabChanged.
  if (changed && _onTabChanged)
    _onTabChanged(tab);
  if (changed && _onGuideTabChanged)
    _onGuideTabChanged(tab);
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [_basicView applyTimeline:timeline];
  _constantsButton.hidden = !_basicView.hasUnoptedLanes;
  [_detachedView applyTimeline:timeline];
}

- (void)setLoopEnabled:(BOOL)enabled {
  _loopButton.on = enabled;
  [_loopButton setNeedsDisplay:YES];
  [_detachedView setLoopEnabled:enabled];
}

- (void)setClipDurationSeconds:(double)seconds {
  _clipDurationSeconds = seconds;
  [_basicView setClipDurationSeconds:seconds];
  [_detachedView setClipDurationSeconds:seconds];
}

- (void)setFrameDurationSeconds:(double)seconds {
  _frameDurationSeconds = seconds;
  [_basicView setFrameDurationSeconds:seconds];
  [_detachedView setFrameDurationSeconds:seconds];
}

- (void)setPlayheadFraction:(double)frac {
  [_basicView setPlayheadFraction:frac];
  [_detachedView setPlayheadFraction:frac];
}

- (void)setPlaying:(BOOL)playing {
  // A guide drives the accent deterministically from taps; ignore the
  // poll-inferred state so it can't flicker the button mid-guide.
  if (_guideOwnsPlayState)
    return;
  _playButton.playing = playing;
  [_detachedView setPlaying:playing];
}

- (KKPlayButton *)_guidePlayButton {
  return _playButton;
}

- (KKPillToggleRowView *)_guideTabBar {
  return _tabBar;
}

#pragma mark - Detached copy

- (BOOL)hasDetachedWindow {
  return _detachedView != nil;
}

- (instancetype)beginDetachedCopy {
  if (_isDetachedCopy || _detachedView)
    return _detachedView;
  KKTimelineInspectorView *copy =
      [[[self class] alloc] initWithAPIManager:_apiManager
                                   loopEnabled:_loopButton.on
                                     activeTab:_selectedTab
                                availableLanes:_availableLanes
                                      timeline:_basicView.currentTimeline];
  copy->_isDetachedCopy = YES;
  copy->_detachedOwner = self;
  copy->_detachButton.hidden = YES;
  // Propagate plugin-supplied configuration so the copy matches the source.
  copy.miniCanvasDescriptorPath = _miniCanvasDescriptorPath;
  copy.miniCanvasRequestPath = _miniCanvasRequestPath;
  copy.miniCanvasDelegate = _miniCanvasDelegate;
  copy.managePopoverSpotlightLabel = _managePopoverSpotlightLabel;
  copy.constantsButtonTitle = _constantsButtonTitle;
  // Propagate standard callbacks (subclasses propagate any extras after
  // calling super).
  copy.onLoopToggled = _onLoopToggled;
  copy.onTabChanged = _onTabChanged;
  copy.onMotionBlurChanged = _onMotionBlurChanged;
  [copy setMotionBlurEnabled:_mbCheckbox.isChecked];
  [copy setMotionBlurShutterAngle:_mbShutterAngle samples:_mbSamples];
  [copy setMotionBlurMode:_mbMode];
  copy.onRenderModeChanged = _onRenderModeChanged;
  copy.renderMode = _basicView.renderMode;
  copy.onTimelineMutated = _onTimelineMutated;
  copy.onDragBegin = _onDragBegin;
  copy.onDragEnd = _onDragEnd;
  copy.onScrub = _onScrub;
  copy.onTogglePlayback = _onTogglePlayback;
  copy.onBoundaryPreviewNeedsRender = _onBoundaryPreviewNeedsRender;
  _detachedView = copy;
  // Bidirectional Advanced selection mirror - selection lives per-view, not
  // in the timeline blob, so without this clicks in the detached window
  // wouldn't reflect in the inspector and vice versa. Each side's
  // applyAdvancedSelectionPillKeys: no-ops on equal sets, breaking the
  // would-be ping-pong.
  __weak KKTimelineInspectorView *weakSelf = self;
  __weak KKTimelineInspectorView *weakCopy = copy;
  _basicView.onAdvancedSelectionChanged =
      ^(NSSet<NSString *> *pills, NSSet<NSString *> *gaps) {
        KKTimelineInspectorView *c = weakCopy;
        [c.basicLanesView applyAdvancedSelectionPillKeys:pills gapKeys:gaps];
      };
  copy.basicLanesView.onAdvancedSelectionChanged =
      ^(NSSet<NSString *> *pills, NSSet<NSString *> *gaps) {
        KKTimelineInspectorView *s = weakSelf;
        [s.basicLanesView applyAdvancedSelectionPillKeys:pills gapKeys:gaps];
      };
  _detachButton.on = YES;
  [_detachButton setNeedsDisplay:YES];
  return copy;
}

- (void)handleDetachedWindowClosed {
  _detachButton.on = NO;
  [_detachButton setNeedsDisplay:YES];
  if (!_detachedView)
    return;
  KKTimelineInspectorView *dying = _detachedView;
  _detachedView = nil;
  // Deferred - we may be unwinding the copy's own `-viewDidMoveToWindow`;
  // releasing inline is a use-after-free.
  dispatch_async(dispatch_get_main_queue(), ^{
    [dying removeFromSuperview];
  });
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!_isDetachedCopy)
    return;
  if (self.window) {
    _detachedAttached = YES;
  } else if (_detachedAttached) {
    _detachedAttached = NO;
    [_detachedOwner handleDetachedWindowClosed];
  }
}

- (CGSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, [self _totalHeight]);
}

@end
