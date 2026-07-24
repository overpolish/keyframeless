/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKSegmentEditView_Private.h"
#import <KeyframelessKit/KKSegmentEditView.h>

#import "KKCheckboxRowView.h"
#import "KKCheckboxView.h"
#import "KKCurvePillView.h"
#import "KKCurveTicks.h"
#import "KKEasing.h"
#import "KKLaneModulationChecklistView.h"
#import "KKLaneParticipationChecklistView.h"
#import "KKPopoverBackground.h"
#import "KKSeedView.h"
#import "KKSliderView.h"
#import "KKTimeline.h" // KKLane
#import "KKTokens.h"
#import "NSColor+KKColors.h"

static const CGFloat kWidth = 280.0;
static const CGFloat kHPadding = 10.0;
static const CGFloat kVPadding = 10.0;
static const CGFloat kPillHeight = 28.0;
static const CGFloat kSliderHeight = 20.0;
static const CGFloat kTickHeight = 10.0;
static const CGFloat kSeedHeight = 26.0;
static const CGFloat kLinkedHeight = 22.0; // matches KKLaneRowView's row height
static const CGFloat kRowGap = 8.0;
static const NSInteger kIntensityTickCount = 3;
static const NSInteger kFrequencyTickCount = 3;

static const CGFloat kBulkHeaderHeight = 18.0;

@interface KKSegmentEditView ()
- (void)_layoutParticipationCaption:(NSTextField *)cap
                          checklist:(NSView *)checklist
                              below:(NSView *)bottom;
@end

@implementation KKSegmentEditView {
  KKCurvePillView *_pills;
  KKSliderView *_intensitySlider;
  KKSliderView *_frequencySlider;
  NSImageView *_intensityTicks;
  NSImageView *_frequencyTicks;
  KKSeedView *_seedView;
  KKCheckboxRowView *_linkedRow;
  NSLayoutConstraint *_intensityTrailingHalf;
  NSLayoutConstraint *_intensityTrailingFull;
  KKLaneParticipationChecklistView *_partChecklist;
  KKLaneModulationChecklistView *_partCompoundChecklist;
  NSArray<KKLane *> *_partLanes;
  NSArray<KKLane *> *_partCompoundLanes;
  NSArray<NSString *> *_partLabels;
  NSArray<NSNumber *> *_partStates;
  NSArray<NSArray<NSString *> *> *_partCompoundLabels;
  NSArray<NSArray<NSNumber *> *> *_partCompoundStates;
}

static const CGFloat kPartBarH = 22.0; // matches kGroupPillHeight for compounds
static const CGFloat kPartRowH = kPartBarH; // caption + bar share one line
// Checklist "Applies to" section: caption line above, the embedded checklist
// (capped + internally scrolling) below.
static const CGFloat kPartCaptionH = 16.0;
static const CGFloat kPartChecklistMaxBody = 168.0; // ~6 rows before scrolling

static BOOL _curveUsesFrequency(KKSegmentEditKind kind, NSInteger curveType) {
  if (kind == KKSegmentEditKindHold)
    return curveType == KKHoldEffectBounce || curveType == KKHoldEffectWiggle ||
           curveType == KKHoldEffectHandheld;
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
  return [self initWithKind:kind
                showsLinked:showsLinked
                 bulkHeader:bulkHeader
        participationLabels:nil
        participationStates:nil];
}

- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked
                  bulkHeader:(BOOL)bulkHeader
         participationLabels:(NSArray<NSString *> *)labels
         participationStates:(NSArray<NSNumber *> *)states {
  BOOL actuallyShows = showsLinked && kind == KKSegmentEditKindHold;
  _partLabels = [labels copy];
  _partStates = [states copy];
  CGFloat h = [KKSegmentEditView contentHeightForKind:kind
                                          showsLinked:actuallyShows
                                           bulkHeader:bulkHeader
                                        participation:(_partLabels.count > 0)];
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

- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked
                  bulkHeader:(BOOL)bulkHeader
          participationLanes:(NSArray<KKLane *> *)lanes
         participationStates:(NSArray<NSNumber *> *)states {
  BOOL actuallyShows = showsLinked && kind == KKSegmentEditKindHold;
  _partLanes = [lanes copy];
  _partStates = [states copy];
  NSMutableArray<NSString *> *labels =
      [NSMutableArray arrayWithCapacity:lanes.count];
  for (KKLane *lane in lanes)
    [labels addObject:lane.key];
  _partLabels = labels; // keeps the existing `participation > 0` gating true
  // Frame height is a placeholder - the presenter pins the real height from
  // -contentHeight once the checklist (and its row count) is built.
  CGFloat h = [KKSegmentEditView contentHeightForKind:kind
                                          showsLinked:actuallyShows
                                           bulkHeader:bulkHeader
                                        participation:(lanes.count > 0)];
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

- (instancetype)initWithKind:(KKSegmentEditKind)kind
                    showsLinked:(BOOL)showsLinked
                     bulkHeader:(BOOL)bulkHeader
     participationCompoundLanes:(NSArray<KKLane *> *)lanes
         participationCompounds:(NSArray<NSArray<NSString *> *> *)compoundLabels
    participationCompoundStates:
        (NSArray<NSArray<NSNumber *> *> *)compoundStates {
  BOOL actuallyShows = showsLinked && kind == KKSegmentEditKindHold;
  _partCompoundLanes = [lanes copy];
  _partCompoundLabels = [compoundLabels copy];
  _partCompoundStates = [compoundStates copy];
  // Placeholder height - the presenter pins the real height from -contentHeight
  // once the checklist's row count is known.
  CGFloat h =
      [KKSegmentEditView contentHeightForKind:kind
                                  showsLinked:actuallyShows
                                   bulkHeader:bulkHeader
                                participation:(compoundLabels.count > 0)];
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
  return [self contentHeightForKind:kind
                        showsLinked:showsLinked
                         bulkHeader:bulkHeader
                      participation:NO];
}

+ (CGFloat)contentHeightForKind:(KKSegmentEditKind)kind
                    showsLinked:(BOOL)showsLinked
                     bulkHeader:(BOOL)bulkHeader
                  participation:(BOOL)participation {
  CGFloat h =
      2 * kVPadding + kPillHeight + kRowGap + kSliderHeight + kTickHeight;
  if (kind == KKSegmentEditKindHold) {
    if (showsLinked)
      h += kRowGap + kLinkedHeight;
    h += kRowGap + kSeedHeight;
  }
  if (bulkHeader)
    h += kBulkHeaderHeight + kRowGap;
  if (participation)
    h += kRowGap + kPartRowH;
  return h;
}

- (CGFloat)contentHeight {
  _KKLaneChecklistView *checklist = _partChecklist ?: _partCompoundChecklist;
  if (checklist) {
    // base includes its own bottom kVPadding; the checklist section provides
    // the real bottom padding, so drop the base's to avoid a double gap below
    // it.
    CGFloat base = [KKSegmentEditView contentHeightForKind:_kind
                                               showsLinked:_showsLinked
                                                bulkHeader:_bulkHeader
                                             participation:NO];
    return base - kVPadding + kRowGap + kPartCaptionH + KKSpacingSM +
           [checklist fittingHeight];
  }
  return
      [KKSegmentEditView contentHeightForKind:_kind
                                  showsLinked:_showsLinked
                                   bulkHeader:_bulkHeader
                                participation:(_partLabels.count > 0 ||
                                               _partCompoundLabels.count > 0)];
}

- (BOOL)hasChecklistParticipation {
  return _partChecklist != nil || _partCompoundChecklist != nil;
}

// Stack the "Applies to" checklist (full width) below its caption, which sits a
// row-gap under `bottom`. Shared by the lane (transition) and compound (hold)
// checklist branches - only the toggle wiring differs.
- (void)_layoutParticipationCaption:(NSTextField *)cap
                          checklist:(NSView *)checklist
                              below:(NSView *)bottom {
  [self addSubview:checklist];
  [NSLayoutConstraint activateConstraints:@[
    [cap.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                      constant:kHPadding],
    [cap.topAnchor constraintEqualToAnchor:bottom.bottomAnchor
                                  constant:kRowGap],
    [cap.heightAnchor constraintEqualToConstant:kPartCaptionH],
    [checklist.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [checklist.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [checklist.topAnchor constraintEqualToAnchor:cap.bottomAnchor
                                        constant:KKSpacingSM],
  ]];
}

- (BOOL)isFlipped {
  return YES;
}

- (NSView *)_buildBulkHeaderRow {
  NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
  NSImage *img = [NSImage
      imageWithSystemSymbolName:@"rectangle.on.rectangle.angled"
       accessibilityDescription:KKLoc(@"Bulk edit",
                                      @"Accessibility: bulk edit toggle.")];
  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:11.0
                          weight:NSFontWeightMedium];
  icon.image = [img imageWithSymbolConfiguration:cfg];
  icon.contentTintColor = [NSColor inspectorLabel];
  icon.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:icon];

  NSTextField *label = [NSTextField
      labelWithString:KKLoc(@"Bulk Edit", @"Label: bulk edit mode.")];
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
  _linkedRow = [[KKCheckboxRowView alloc]
      initWithTitle:KKLoc(@"Linked", @"Label: components linked toggle.")
      tooltip:KKLoc(@"Maintain proportions across components (e.g. "
                    @"keep Radius X/Y aspect-locked through wobble)",
                    @"Tooltip for the Linked toggle.")
      binding:^BOOL {
        __strong typeof(weakSelf) s = weakSelf;
        return s ? s->_linked : NO;
      }
      disabledBinding:nil
      onToggle:^(BOOL isOn) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self)
          return;
        self->_linked = isOn;
        if (self.onLinkedChanged)
          self.onLinkedChanged(isOn);
      }];
  _linkedRow.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_linkedRow];
  [NSLayoutConstraint activateConstraints:@[
    [_linkedRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:kHPadding],
    [_linkedRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                              constant:-kHPadding],
    [_linkedRow.topAnchor constraintEqualToAnchor:anchorView.bottomAnchor
                                         constant:kRowGap],
  ]];
  return _linkedRow;
}

- (void)_buildSeedRowBelow:(NSView *)anchorView {
  __weak typeof(self) weakSelf = self;
  NSTextField *seedLabel = [NSTextField
      labelWithString:KKLoc(@"Seed", @"Label: random seed field.")];
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
  {
    // Name the glyph-only pills on hover (localized).
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (_kind == KKSegmentEditKindHold)
      for (NSInteger i = 0; i < KKHoldEffectCount; i++)
        [names addObject:KKHoldEffectDisplayName((KKHoldEffect)i)];
    else
      for (NSInteger i = 0; i < KKEasingCurveCount; i++)
        [names addObject:KKEasingCurveDisplayName((KKEasingCurve)i)];
    _pills.pillTooltips = names;
  }
  // Transition pills (curve picker) read in the warn tint that matches the
  // transition curve drawn in the lane graph; Hold (modulation) keeps the
  // accent tint.
  _pills.accentColor = (_kind == KKSegmentEditKindHold)
                           ? [NSColor accentMatchingHost]
                           : [NSColor warning];
  if (_kind == KKSegmentEditKindHold) {
    // Hold-effect intensity scales amplitude around 1.0; plot against a fixed
    // band (≈ max deviation across the effects) so intensity is visible in
    // the preview instead of being auto-normalised away.
    _pills.usesFixedRange = YES;
    _pills.fixedMin = 0.4;
    _pills.fixedMax = 1.6;
  }
  _pills.valueBlock = ^CGFloat(NSInteger pillIndex, CGFloat t) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return 0;
    if (self.kind == KKSegmentEditKindHold) {
      return KKApplyHoldEffect(t, (KKHoldEffect)pillIndex, self.intensity,
                               self.frequency, (int)self.seed);
    }
    // For animate-out, show the curve with time mirrored so the pill reads
    // as the value descending over time - matches the lane graph.
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
  __weak typeof(self) weakSelfDragI = self;
  _intensitySlider.onDragBegin = ^{
    if (weakSelfDragI.onSliderDragBegin)
      weakSelfDragI.onSliderDragBegin();
  };
  _intensitySlider.onDragEnd = ^{
    if (weakSelfDragI.onSliderDragEnd)
      weakSelfDragI.onSliderDragEnd();
  };
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
  __weak typeof(self) weakSelfDragF = self;
  _frequencySlider.onDragBegin = ^{
    if (weakSelfDragF.onSliderDragBegin)
      weakSelfDragF.onSliderDragBegin();
  };
  _frequencySlider.onDragEnd = ^{
    if (weakSelfDragF.onSliderDragEnd)
      weakSelfDragF.onSliderDragEnd();
  };
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

  if (_partLabels.count > 0 || _partCompoundLabels.count > 0) {
    NSView *bottom = (_kind == KKSegmentEditKindHold)
                         ? (NSView *)_seedView
                         : (NSView *)_intensityTicks;
    NSTextField *cap =
        [NSTextField labelWithString:KKLoc(@"Applies to",
                                           @"Label: where a setting applies.")];
    cap.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    cap.textColor = [NSColor inspectorLabel];
    cap.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:cap];

    __weak typeof(self) weakSelf = self;

    // Checklist "Applies to": the Animated dropdown's content stacked BELOW the
    // caption (vertical), so many grouped properties scroll instead of forcing
    // a horizontal pill scroll. The toggle index maps back to `_partLanes`
    // order, so the downstream participation callback is unchanged.
    if (_partLanes.count > 0) {
      NSMutableSet<NSString *> *checked = [NSMutableSet set];
      for (NSInteger i = 0; i < (NSInteger)_partLanes.count; i++)
        if (i < (NSInteger)_partStates.count && _partStates[i].boolValue)
          [checked addObject:_partLanes[i].key];
      _partChecklist = [[KKLaneParticipationChecklistView alloc]
          initWithLanes:_partLanes
          checkedLabels:checked
                  width:kWidth
          maxBodyHeight:kPartChecklistMaxBody];
      _partChecklist.translatesAutoresizingMaskIntoConstraints = NO;
      // Read `_partLanes` live (not a capture) so a layer re-scope updating it
      // keeps the toggle index correct.
      _partChecklist.onToggled = ^(NSString *label, BOOL on) {
        __strong typeof(weakSelf) s = weakSelf;
        NSInteger idx = NSNotFound;
        for (NSInteger i = 0; i < (NSInteger)s->_partLanes.count; i++)
          if ([s->_partLanes[i].key isEqualToString:label]) {
            idx = i;
            break;
          }
        if (idx != NSNotFound && s.onParticipationToggled)
          s.onParticipationToggled(idx, on);
      };
      [self _layoutParticipationCaption:cap
                              checklist:_partChecklist
                                  below:bottom];
      return;
    }

    // Compound checklist (modulate / Hold): same vertical layout, but multi-
    // component lanes expand into indented per-component sub-rows. The
    // (compound, segment) toggle is flattened to the same index the pill bar
    // emitted.
    if (_partCompoundLanes.count > 0) {
      _partCompoundChecklist = [[KKLaneModulationChecklistView alloc]
          initWithLanes:_partCompoundLanes
              compounds:_partCompoundLabels
                 states:_partCompoundStates
                  width:kWidth
          maxBodyHeight:kPartChecklistMaxBody];
      _partCompoundChecklist.translatesAutoresizingMaskIntoConstraints = NO;
      // Read `_partCompoundLabels` live so a layer re-scope keeps the flattened
      // (compound, segment) -> index mapping correct.
      _partCompoundChecklist.onToggled =
          ^(NSInteger ci, NSInteger seg, BOOL on) {
            __strong typeof(weakSelf) s = weakSelf;
            NSInteger flat = 0;
            for (NSInteger k = 0;
                 k < ci && k < (NSInteger)s->_partCompoundLabels.count; k++)
              flat += (NSInteger)s->_partCompoundLabels[k].count;
            flat += seg;
            if (s.onParticipationToggled)
              s.onParticipationToggled(flat, on);
          };
      [self _layoutParticipationCaption:cap
                              checklist:_partCompoundChecklist
                                  below:bottom];
      return;
    }
  }
}

- (void)setLinked:(BOOL)linked {
  _linked = linked;
  [_linkedRow popoverDidRefresh];
}

- (void)applyParticipationCompoundStates:
    (NSArray<NSArray<NSNumber *> *> *)states {
  _partCompoundStates = [states copy];
  if (_partCompoundChecklist)
    [_partCompoundChecklist reloadStates:states];
}

- (void)applyParticipationStates:(NSArray<NSNumber *> *)states {
  _partStates = [states copy];
  if (_partChecklist && states.count == _partLanes.count) {
    NSMutableSet<NSString *> *checked = [NSMutableSet set];
    for (NSInteger i = 0; i < (NSInteger)_partLanes.count; i++)
      if (states[i].boolValue)
        [checked addObject:_partLanes[i].key];
    [_partChecklist reloadCheckedLabels:checked];
  }
}

- (void)rescopeParticipationLanes:(NSArray<KKLane *> *)lanes
                           states:(NSArray<NSNumber *> *)states {
  _partLanes = [lanes copy];
  _partStates = [states copy];
  NSMutableArray<NSString *> *labels =
      [NSMutableArray arrayWithCapacity:lanes.count];
  for (KKLane *lane in lanes)
    [labels addObject:lane.key];
  _partLabels = labels;
  if (!_partChecklist)
    return;
  NSMutableSet<NSString *> *checked = [NSMutableSet set];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
    if (i < (NSInteger)states.count && states[i].boolValue)
      [checked addObject:lanes[i].key];
  [_partChecklist reloadLanes:lanes checkedLabels:checked];
}

- (void)rescopeCompoundParticipationLanes:(NSArray<KKLane *> *)lanes
                                compounds:
                                    (NSArray<NSArray<NSString *> *> *)compounds
                                   states:(NSArray<NSArray<NSNumber *> *> *)
                                              states {
  _partCompoundLanes = [lanes copy];
  _partCompoundLabels = [compounds copy];
  _partCompoundStates = [states copy];
  if (_partCompoundChecklist)
    [_partCompoundChecklist reloadLanes:lanes
                              compounds:compounds
                                 states:states];
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
  // Deactivate the outgoing constraint before activating the incoming one - the
  // two are mutually exclusive, so flipping in the other order leaves both
  // active for an instant and Auto Layout logs a conflict.
  if (showFreq) {
    _intensityTrailingFull.active = NO;
    _intensityTrailingHalf.active = YES;
  } else {
    _intensityTrailingHalf.active = NO;
    _intensityTrailingFull.active = YES;
  }
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
    KKApplyPopoverBackground(self);
  }
}

- (KKCurvePillView *)_guidePillsView {
  return _pills;
}

@end
