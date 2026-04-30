/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSegmentEditView.h"

#import "../Math/KKCurveTicks.h"
#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCheckboxView.h"
#import "KKCurvePillView.h"
#import "KKSeedView.h"
#import "KKSliderView.h"

static const CGFloat kWidth = 280.0;
static const CGFloat kHPadding = 10.0;
static const CGFloat kVPadding = 10.0;
static const CGFloat kPillHeight = 28.0;
static const CGFloat kSliderHeight = 20.0;
static const CGFloat kTickHeight = 10.0;
static const CGFloat kSeedHeight = 26.0;
static const CGFloat kLinkedHeight = 20.0;
static const CGFloat kRowGap = 8.0;
static const NSInteger kIntensityTickCount = 3;
static const NSInteger kFrequencyTickCount = 3;

/// Removes macOS 26's liquid-glass content background from the popover
/// frame so a content view's own styling isn't drawn on top of the default
/// glass pane (which otherwise shows as a doubled border). Matches the
/// approach in KKGradientFavoritesPopover.
static void _clearPopoverBackground(NSView *view) {
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        NSView *current = view;
        NSView *popoverFrame = nil;
        while (current) {
          if ([NSStringFromClass([current class])
                  hasPrefix:@"NSPopoverFrame"]) {
            popoverFrame = current;
            break;
          }
          current = current.superview;
        }
        if (!popoverFrame)
          return;
        for (NSView *sub in popoverFrame.subviews) {
          if (![NSStringFromClass([sub class]) containsString:@"GlassView"])
            continue;
          for (NSView *glassSub in sub.subviews) {
            glassSub.wantsLayer = YES;
            NSString *name = NSStringFromClass([glassSub class]);
            if ([name containsString:@"CoreHostingView"])
              glassSub.layer.opacity = 0;
            else if ([name containsString:@"ContentHolderView"])
              glassSub.layer.backgroundColor = NSColor.clearColor.CGColor;
          }
          break;
        }
      });
}

static const CGFloat kBulkHeaderHeight = 18.0;

@implementation KKSegmentEditView {
  KKCurvePillView *_pills;
  KKSliderView *_intensitySlider;
  KKSliderView *_frequencySlider;
  NSImageView *_intensityTicks;
  NSImageView *_frequencyTicks;
  KKSeedView *_seedView;
  KKCheckboxView *_linkedToggle;
  NSLayoutConstraint *_intensityTrailingHalf;
  NSLayoutConstraint *_intensityTrailingFull;
}

static BOOL _curveUsesFrequency(KKSegmentEditKind kind, NSInteger curveType) {
  if (kind == KKSegmentEditKindHold)
    return curveType == KKHoldEffectBounce || curveType == KKHoldEffectWiggle;
  return curveType == KKEasingCurveElastic || curveType == KKEasingCurveBounce;
}

- (instancetype)initWithKind:(KKSegmentEditKind)kind {
  return [self initWithKind:kind showsLinked:NO bulkHeader:NO];
}

- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked {
  return [self initWithKind:kind showsLinked:showsLinked bulkHeader:NO];
}

- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked
                  bulkHeader:(BOOL)bulkHeader {
  BOOL actuallyShows = showsLinked && kind == KKSegmentEditKindHold;
  CGFloat h = [KKSegmentEditView contentHeightForKind:kind
                                          showsLinked:actuallyShows
                                           bulkHeader:bulkHeader];
  self = [super initWithFrame:NSMakeRect(0, 0, kWidth, h)];
  if (self) {
    _kind = kind;
    _showsLinked = actuallyShows;
    _bulkHeader = bulkHeader;
    _linked = YES;
    _intensity = 0.5;
    _frequency = 0.5;
    self.wantsLayer = YES;
    [self buildUI];
  }
  return self;
}

+ (CGFloat)contentWidth {
  return kWidth;
}

+ (CGFloat)contentHeightForKind:(KKSegmentEditKind)kind
                    showsLinked:(BOOL)showsLinked
                     bulkHeader:(BOOL)bulkHeader {
  CGFloat h =
      2 * kVPadding + kPillHeight + kRowGap + kSliderHeight + kTickHeight;
  if (kind == KKSegmentEditKindHold) {
    if (showsLinked)
      h += kRowGap + kLinkedHeight;
    h += kRowGap + kSeedHeight;
  }
  if (bulkHeader)
    h += kBulkHeaderHeight + kRowGap;
  return h;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSView *)_buildBulkHeaderRow {
  NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
  NSImage *img =
      [NSImage imageWithSystemSymbolName:@"rectangle.on.rectangle.angled"
                accessibilityDescription:@"Bulk edit"];
  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:11.0
                          weight:NSFontWeightMedium];
  icon.image = [img imageWithSymbolConfiguration:cfg];
  icon.contentTintColor = [NSColor inspectorLabel];
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:icon];

  NSTextField *label = [NSTextField labelWithString:@"Bulk Edit"];
  label.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  label.textColor = [NSColor inspectorLabel];
  label.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:label];

  [NSLayoutConstraint activateConstraints:@[
    [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                       constant:kHPadding],
    [icon.topAnchor constraintEqualToAnchor:self.topAnchor
                                   constant:kVPadding / 2.0],
    [icon.widthAnchor constraintEqualToConstant:14.0],
    [icon.heightAnchor constraintEqualToConstant:kBulkHeaderHeight],
    [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor
                                        constant:5.0],
    [label.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
  ]];
  return icon;
}

- (NSView *)_buildLinkedRowBelow:(NSView *)anchorView {
  __weak typeof(self) weakSelf = self;
  NSTextField *linkedLabel = [NSTextField labelWithString:@"Linked"];
  linkedLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  linkedLabel.textColor = [NSColor inspectorLabel];
  linkedLabel.translatesAutoresizingMaskIntoConstraints = NO;
  linkedLabel.toolTip = @"Maintain proportions across components (e.g. "
                        @"keep Radius X/Y aspect-locked through wobble)";
  [self addSubview:linkedLabel];

  _linkedToggle = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
  _linkedToggle.translatesAutoresizingMaskIntoConstraints = NO;
  _linkedToggle.isChecked = _linked;
  _linkedToggle.toolTip = linkedLabel.toolTip;
  _linkedToggle.onToggle = ^(BOOL isOn) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return;
    self->_linked = isOn;
    if (self.onLinkedChanged)
      self.onLinkedChanged(isOn);
  };
  [self addSubview:_linkedToggle];

  [NSLayoutConstraint activateConstraints:@[
    [linkedLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                              constant:kHPadding],
    [linkedLabel.centerYAnchor
        constraintEqualToAnchor:_linkedToggle.centerYAnchor],

    [_linkedToggle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                 constant:-kHPadding],
    [_linkedToggle.topAnchor constraintEqualToAnchor:anchorView.bottomAnchor
                                            constant:kRowGap],
    [_linkedToggle.widthAnchor constraintEqualToConstant:kLinkedHeight],
    [_linkedToggle.heightAnchor constraintEqualToConstant:kLinkedHeight],
  ]];
  return _linkedToggle;
}

- (void)_buildSeedRowBelow:(NSView *)anchorView {
  __weak typeof(self) weakSelf = self;
  NSTextField *seedLabel = [NSTextField labelWithString:@"Seed"];
  seedLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  seedLabel.textColor = [NSColor inspectorLabel];
  seedLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:seedLabel];

  _seedView = [[KKSeedView alloc] initWithFrame:NSZeroRect];
  _seedView.translatesAutoresizingMaskIntoConstraints = NO;
  _seedView.onSeedChanged = ^(uint32_t newSeed) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return;
    self->_seed = newSeed;
    if (self.onSeedChanged)
      self.onSeedChanged(newSeed);
  };
  _seedView.onReroll = ^{
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return;
    if (self.onSeedReroll)
      self.onSeedReroll();
  };
  [self addSubview:_seedView];

  [NSLayoutConstraint activateConstraints:@[
    [seedLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                            constant:kHPadding],
    [seedLabel.centerYAnchor constraintEqualToAnchor:_seedView.centerYAnchor],

    [_seedView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                             constant:-kHPadding],
    [_seedView.topAnchor constraintEqualToAnchor:anchorView.bottomAnchor
                                        constant:kRowGap],
    [_seedView.heightAnchor constraintEqualToConstant:kSeedHeight],
    [_seedView.widthAnchor constraintEqualToConstant:120.0],
  ]];
}

- (void)buildUI {
  __weak typeof(self) weakSelf = self;

  NSView *pillTopReference = self;
  CGFloat pillTopConstant = kVPadding;
  if (_bulkHeader) {
    pillTopReference = [self _buildBulkHeaderRow];
    pillTopConstant = kRowGap;
  }

  _pills = [[KKCurvePillView alloc] initWithFrame:NSZeroRect];
  _pills.translatesAutoresizingMaskIntoConstraints = NO;
  _pills.pillCount =
      (_kind == KKSegmentEditKindHold) ? KKHoldEffectCount : KKEasingCurveCount;
  _pills.valueBlock = ^CGFloat(NSInteger pillIndex, CGFloat t) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return 0;
    if (self.kind == KKSegmentEditKindHold) {
      return KKApplyHoldEffect(t, (KKHoldEffect)pillIndex, self.intensity,
                               self.frequency, (int)self.seed);
    }
    // For animate-out, show the curve with time mirrored so the pill reads
    // as the value descending over time — matches the lane graph.
    double ti = self.animateOut ? (1.0 - t) : t;
    return KKApplyEasing(ti, (KKEasingCurve)pillIndex, self.intensity,
                         self.frequency);
  };
  _pills.onSelectionChanged = ^(NSInteger index) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return;
    self->_curveType = index;
    [self _updateFrequencyVisibility];
    if (self.onCurveTypeChanged)
      self.onCurveTypeChanged(index);
  };
  [self addSubview:_pills];

  _intensitySlider = [KKSliderView styledSlider];
  _intensitySlider.translatesAutoresizingMaskIntoConstraints = NO;
  _intensitySlider.minValue = 0.0;
  _intensitySlider.maxValue = 1.0;
  _intensitySlider.doubleValue = _intensity;
  _intensitySlider.continuous = YES;
  _intensitySlider.trackFillColor = [NSColor accentMatchingHost];
  _intensitySlider.target = self;
  _intensitySlider.action = @selector(intensityChanged:);
  [self addSubview:_intensitySlider];

  _frequencySlider = [KKSliderView styledSlider];
  _frequencySlider.translatesAutoresizingMaskIntoConstraints = NO;
  _frequencySlider.minValue = 0.0;
  _frequencySlider.maxValue = 1.0;
  _frequencySlider.doubleValue = _frequency;
  _frequencySlider.continuous = YES;
  _frequencySlider.trackFillColor = [NSColor warning];
  _frequencySlider.target = self;
  _frequencySlider.action = @selector(frequencyChanged:);
  [self addSubview:_frequencySlider];

  _intensityTicks = [[NSImageView alloc] initWithFrame:NSZeroRect];
  _intensityTicks.imageScaling = NSImageScaleNone;
  _intensityTicks.translatesAutoresizingMaskIntoConstraints = NO;
  [_intensityTicks
      setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                               forOrientation:
                                   NSLayoutConstraintOrientationHorizontal];
  [self addSubview:_intensityTicks];

  _frequencyTicks = [[NSImageView alloc] initWithFrame:NSZeroRect];
  _frequencyTicks.imageScaling = NSImageScaleNone;
  _frequencyTicks.translatesAutoresizingMaskIntoConstraints = NO;
  [_frequencyTicks
      setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                               forOrientation:
                                   NSLayoutConstraintOrientationHorizontal];
  [self addSubview:_frequencyTicks];

  _intensityTrailingHalf = [_intensitySlider.trailingAnchor
      constraintEqualToAnchor:self.centerXAnchor
                     constant:-kRowGap / 2.0];
  _intensityTrailingFull = [_intensitySlider.trailingAnchor
      constraintEqualToAnchor:self.trailingAnchor
                     constant:-kHPadding];
  _intensityTrailingHalf.active = YES;

  [NSLayoutConstraint activateConstraints:@[
    [_pills.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                         constant:kHPadding],
    [_pills.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                          constant:-kHPadding],
    [_pills.topAnchor
        constraintEqualToAnchor:(_bulkHeader ? pillTopReference.bottomAnchor
                                             : self.topAnchor)
                       constant:pillTopConstant],
    [_pills.heightAnchor constraintEqualToConstant:kPillHeight],

    [_intensitySlider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                   constant:kHPadding],
    [_intensitySlider.topAnchor constraintEqualToAnchor:_pills.bottomAnchor
                                               constant:kRowGap],
    [_intensitySlider.heightAnchor constraintEqualToConstant:kSliderHeight],

    [_frequencySlider.leadingAnchor constraintEqualToAnchor:self.centerXAnchor
                                                   constant:kRowGap / 2.0],
    [_frequencySlider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                    constant:-kHPadding],
    [_frequencySlider.topAnchor
        constraintEqualToAnchor:_intensitySlider.topAnchor],
    [_frequencySlider.heightAnchor
        constraintEqualToAnchor:_intensitySlider.heightAnchor],

    [_intensityTicks.leadingAnchor
        constraintEqualToAnchor:_intensitySlider.leadingAnchor],
    [_intensityTicks.trailingAnchor
        constraintEqualToAnchor:_intensitySlider.trailingAnchor],
    [_intensityTicks.topAnchor
        constraintEqualToAnchor:_intensitySlider.bottomAnchor],
    [_intensityTicks.heightAnchor constraintEqualToConstant:kTickHeight],

    [_frequencyTicks.leadingAnchor
        constraintEqualToAnchor:_frequencySlider.leadingAnchor],
    [_frequencyTicks.trailingAnchor
        constraintEqualToAnchor:_frequencySlider.trailingAnchor],
    [_frequencyTicks.topAnchor
        constraintEqualToAnchor:_frequencySlider.bottomAnchor],
    [_frequencyTicks.heightAnchor constraintEqualToConstant:kTickHeight],
  ]];

  if (_kind == KKSegmentEditKindHold) {
    NSView *seedTopAnchor = _showsLinked
                                ? [self _buildLinkedRowBelow:_intensityTicks]
                                : (NSView *)_intensityTicks;
    [self _buildSeedRowBelow:seedTopAnchor];
  }
}

- (void)setLinked:(BOOL)linked {
  _linked = linked;
  _linkedToggle.isChecked = linked;
}

- (void)setCurveType:(NSInteger)curveType {
  _curveType = curveType;
  _pills.selectedIndex = curveType;
  [_pills redraw];
  [self _updateFrequencyVisibility];
}

- (void)setAnimateOut:(BOOL)animateOut {
  _animateOut = animateOut;
  [_pills redraw];
  [self _renderTicks];
}

- (void)layout {
  [super layout];
  [self _renderTicks];
}

- (void)_updateFrequencyVisibility {
  BOOL showFreq = _curveUsesFrequency(_kind, _curveType);
  _frequencySlider.hidden = !showFreq;
  _frequencyTicks.hidden = !showFreq;
  _intensityTrailingHalf.active = showFreq;
  _intensityTrailingFull.active = !showFreq;
  [self _renderTicks];
}

- (CGFloat)_curveValueAtTickIndex:(NSInteger)idx
                                t:(CGFloat)t
                intensityOverride:(double)intensity
                frequencyOverride:(double)frequency {
  if (_kind == KKSegmentEditKindHold) {
    return KKApplyHoldEffect(t, (KKHoldEffect)_curveType, intensity, frequency,
                             (int)_seed);
  }
  double ti = _animateOut ? (1.0 - t) : t;
  return KKApplyEasing(ti, (KKEasingCurve)_curveType, intensity, frequency);
}

- (void)_renderTicks {
  if (NSWidth(_intensityTicks.bounds) < 1)
    return;

  NSInteger intensityActive = KKExactTickIndex(_intensity, kIntensityTickCount);
  __weak typeof(self) weakSelf = self;
  KKRenderHalfWidthTicks(
      _intensityTicks, kIntensityTickCount, intensityActive,
      [NSColor accentMatchingHost], ^CGFloat(NSInteger idx, CGFloat t) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self)
          return 0;
        double inten = (double)idx / (double)(kIntensityTickCount - 1);
        return [self _curveValueAtTickIndex:idx
                                          t:t
                          intensityOverride:inten
                          frequencyOverride:self->_frequency];
      });

  if (!_frequencyTicks.hidden) {
    NSInteger frequencyActive =
        KKExactTickIndex(_frequency, kFrequencyTickCount);
    KKRenderHalfWidthTicks(
        _frequencyTicks, kFrequencyTickCount, frequencyActive,
        [NSColor warning], ^CGFloat(NSInteger idx, CGFloat t) {
          __strong typeof(weakSelf) self = weakSelf;
          if (!self)
            return 0;
          double freq = (double)idx / (double)(kFrequencyTickCount - 1);
          return [self _curveValueAtTickIndex:idx
                                            t:t
                            intensityOverride:self->_intensity
                            frequencyOverride:freq];
        });
  }
}

- (NSRect)_tickHitRectForIndex:(NSInteger)idx
                     imageView:(NSImageView *)imageView
                     tickCount:(NSInteger)tickCount {
  CGFloat w = NSWidth(imageView.bounds);
  static const CGFloat kHalfTickWidth = 18.0;
  CGFloat tickPad = kHalfTickWidth / 2.0;
  CGFloat usable = w - 2 * tickPad;
  CGFloat frac =
      (tickCount > 1) ? (CGFloat)idx / (CGFloat)(tickCount - 1) : 0.5;
  CGFloat centerX = tickPad + frac * usable;
  NSRect local = NSMakeRect(centerX - kHalfTickWidth / 2.0, 0, kHalfTickWidth,
                            KKCurveTickHeight);
  return [self convertRect:local fromView:imageView];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  for (NSInteger i = 0; i < kIntensityTickCount; i++) {
    NSRect r = [self _tickHitRectForIndex:i
                                imageView:_intensityTicks
                                tickCount:kIntensityTickCount];
    if (NSPointInRect(loc, r)) {
      double v = (double)i / (double)(kIntensityTickCount - 1);
      _intensity = v;
      _intensitySlider.doubleValue = v;
      [_pills redraw];
      [self _renderTicks];
      if (_onIntensityChanged)
        _onIntensityChanged(v);
      return;
    }
  }
  if (!_frequencyTicks.hidden) {
    for (NSInteger i = 0; i < kFrequencyTickCount; i++) {
      NSRect r = [self _tickHitRectForIndex:i
                                  imageView:_frequencyTicks
                                  tickCount:kFrequencyTickCount];
      if (NSPointInRect(loc, r)) {
        double v = (double)i / (double)(kFrequencyTickCount - 1);
        _frequency = v;
        _frequencySlider.doubleValue = v;
        [_pills redraw];
        [self _renderTicks];
        if (_onFrequencyChanged)
          _onFrequencyChanged(v);
        return;
      }
    }
  }
  [super mouseDown:event];
}

- (void)setIntensity:(double)intensity {
  _intensity = intensity;
  _intensitySlider.doubleValue = intensity;
  [_pills redraw];
  [self _renderTicks];
}

- (void)setFrequency:(double)frequency {
  _frequency = frequency;
  _frequencySlider.doubleValue = frequency;
  [_pills redraw];
  [self _renderTicks];
}

- (void)setSeed:(uint32_t)seed {
  _seed = seed;
  _seedView.seed = seed;
  [_pills redraw];
  [self _renderTicks];
}

- (void)intensityChanged:(id)sender {
  _intensity = _intensitySlider.doubleValue;
  [_pills redraw];
  [self _renderTicks];
  if (_onIntensityChanged)
    _onIntensityChanged(_intensity);
}

- (void)frequencyChanged:(id)sender {
  _frequency = _frequencySlider.doubleValue;
  [_pills redraw];
  [self _renderTicks];
  if (_onFrequencyChanged)
    _onFrequencyChanged(_frequency);
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    // Prevent the popover from auto-focusing the seed field on open so
    // spacebar still controls timeline playback.
    [self.window makeFirstResponder:nil];
    _clearPopoverBackground(self);
  }
}

@end
