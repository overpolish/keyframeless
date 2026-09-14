/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKSegmentEditView_Private.h"
#import <KeyframelessKit/KKSegmentEditView.h>

#import "KKCurveDefaults.h"
#import "KKCurvePillView.h"
#import "KKEasing.h"
#import "KKFloatingPanel.h"
#import "KKLaneModulationChecklistView.h"
#import "KKLaneParticipationChecklistView.h"
#import "KKPopoverBackground.h"
#import "KKTimeline.h"                  // KKLane
#import "KKTimelineLanesView_Private.h" // _KKStaticValueRow
#import "KKTokens.h"
#import "NSColor+KKColors.h"

static const CGFloat kWidth = 370.0;
// Pills carry a caption line (at low intensity several curves plot alike).
static const CGFloat kPillHeight = 36.0;
static const CGFloat kBulkHeaderHeight = 18.0;
// Air above the "Applies to" section - inside a group the rows butt at 0.
static const CGFloat kSectionGap = KKPaddingLG;
// The "Applies to" caption hugs its text: the checklist below is part of the
// same field, so it butts straight under it.
static const CGFloat kSectionCaptionH = 16.0;

// Intensity / Frequency / Linked / Seed are all _KKStaticValueRow rows fed a
// synthetic single-keypose lane, stacked at spacing 0 exactly like the
// constants + keypose popovers: the row's own kFloatRowH carries the rhythm,
// and the label column, gutter insets and value column line up with every
// other popover in the kit. Nothing here hand-rolls a row.
static NSString *const kKKSegmentIntensityKey = @"Intensity";
static NSString *const kKKSegmentFrequencyKey = @"Frequency";
static NSString *const kKKSegmentLinkedKey = @"Linked";
static NSString *const kKKSegmentSeedKey = @"Seed";

@interface KKSegmentEditView ()
- (void)_layoutParticipationCaption:(NSTextField *)cap
                          checklist:(NSView *)checklist;
@end

@implementation KKSegmentEditView {
  KKCurvePillView *_pills;
  NSStackView *_rowStack;
  _KKStaticValueRow *_intensityRow;
  _KKStaticValueRow *_frequencyRow;
  _KKStaticValueRow *_linkedRow;
  _KKStaticValueRow *_seedRow;
  NSView *_defaultsAccessory;
  NSButton *_makeDefaultButton;
  NSButton *_resetDefaultButton;
  KKLaneParticipationChecklistView *_partChecklist;
  KKLaneModulationChecklistView *_partCompoundChecklist;
  NSArray<KKLane *> *_partLanes;
  NSArray<KKLane *> *_partCompoundLanes;
  NSArray<NSString *> *_partLabels;
  NSArray<NSNumber *> *_partStates;
  NSArray<NSArray<NSString *> *> *_partCompoundLabels;
  NSArray<NSArray<NSNumber *> *> *_partCompoundStates;
}

// "Applies to": a section caption with the embedded checklist - capped,
// internally scrolling - directly below it.
static const CGFloat kPartChecklistMaxBody = 168.0; // ~6 rows before scrolling

// What the pill preview plots a value AS: the shapes are authored over 0..1,
// so anything past that is drawn at its end of the range.
static double KKPreviewClamped(double v) { return MIN(MAX(v, 0.0), 1.0); }

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

// Everything above the rows: top pad, the optional bulk header, the pills, and
// the pad below them. The rows themselves are whole kFloatRowH slots.
+ (CGFloat)_chromeHeightForBulkHeader:(BOOL)bulkHeader {
  CGFloat h = KKPaddingMD;
  if (bulkHeader)
    h += kBulkHeaderHeight + KKPaddingMD;
  return h + kPillHeight + KKPaddingMD;
}

+ (CGFloat)contentHeightForKind:(KKSegmentEditKind)kind
                    showsLinked:(BOOL)showsLinked
                     bulkHeader:(BOOL)bulkHeader
                  participation:(BOOL)participation {
  // Intensity + Frequency; the Frequency row only applies to the curves that
  // use it, and the instance method below subtracts it when collapsed.
  NSInteger rows = 2;
  CGFloat h = [self _chromeHeightForBulkHeader:bulkHeader];
  if (kind == KKSegmentEditKindHold) {
    if (showsLinked)
      rows++;
    rows++; // Seed
  }
  if (participation)
    h += kSectionGap + kSectionCaptionH;
  return h + rows * kFloatRowH + KKPaddingMD;
}

- (CGFloat)contentHeight {
  CGFloat h = [KKSegmentEditView _chromeHeightForBulkHeader:_bulkHeader];
  for (NSView *row in _rowStack.arrangedSubviews)
    if (!row.hidden)
      h += kFloatRowH;
  _KKLaneChecklistView *checklist = _partChecklist ?: _partCompoundChecklist;
  if (checklist)
    // Caption + checklist are ONE field: the list butts straight under its
    // caption (its own top pad is the only air), and its scroll fade marks the
    // bottom edge, so no bottom pad below it either.
    return h + kSectionGap + kSectionCaptionH + [checklist fittingHeight];
  return h + KKPaddingMD;
}

- (void)selectParticipationLayerKey:(NSString *)layerKey {
  [(_partChecklist ?: _partCompoundChecklist) selectLayerKey:layerKey];
}

- (BOOL)hasChecklistParticipation {
  return _partChecklist != nil || _partCompoundChecklist != nil;
}

// Stack the "Applies to" checklist (full width) directly under its caption -
// caption and list are ONE field, so nothing sits between them; the section's
// air goes ABOVE the caption instead. Shared by the lane (transition) and
// compound (hold) checklist branches - only the toggle wiring differs.
- (void)_layoutParticipationCaption:(NSTextField *)cap
                          checklist:(NSView *)checklist {
  [self addSubview:checklist];
  [NSLayoutConstraint activateConstraints:@[
    [cap.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                      constant:KKPaddingLG],
    [cap.topAnchor constraintEqualToAnchor:_rowStack.bottomAnchor
                                  constant:kSectionGap],
    [cap.heightAnchor constraintEqualToConstant:kSectionCaptionH],
    [checklist.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [checklist.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [checklist.topAnchor constraintEqualToAnchor:cap.bottomAnchor],
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
                                       constant:KKPaddingLG],
    [icon.topAnchor constraintEqualToAnchor:self.topAnchor
                                   constant:KKPaddingMD],
    [icon.widthAnchor constraintEqualToConstant:14.0],
    [icon.heightAnchor constraintEqualToConstant:kBulkHeaderHeight],
    [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor
                                        constant:5.0],
    [label.centerYAnchor constraintEqualToAnchor:icon.centerYAnchor],
  ]];
  return icon;
}

// One flat text-and-glyph action for the popover's title bar: no bezel, no
// background - just a tinted glyph + label, matching the caption-style bar in
// Steno.
static NSButton *KKDefaultsButton(NSString *title, NSString *symbol,
                                  NSColor *tint, id target, SEL action) {
  NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.controlSize = NSControlSizeSmall;
  b.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
  b.image = [NSImage imageWithSystemSymbolName:symbol
                      accessibilityDescription:title];
  b.imagePosition = b.image ? NSImageLeading : NSNoImage;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.contentTintColor = tint;
  b.imageHugsTitle = YES;
  // Act on press, not on a matched press+release: when this popover opens over
  // another one (constants, keypose), the release can land in the OTHER
  // popover's window, so a release-driven NSButton highlights and never fires.
  [b sendActionOn:NSEventMaskLeftMouseDown];
  return b;
}

// The saved default for this popover's kind: the easing shape for a transition,
// the modulation shape for a hold. Modulation crosses the pill/enum boundary,
// so it is converted on the way in and out.
- (KKCurveDefault)_savedDefault {
  if (_kind == KKSegmentEditKindHold) {
    KKCurveDefault d = KKModulationDefaultsRead(nil);
    d.curve = KKModulationToPill(d.curve);
    return d;
  }
  return KKCurveDefaultsRead(nil);
}

- (BOOL)_matchesSavedDefault {
  KKCurveDefault d = [self _savedDefault];
  if (d.curve != _curveType)
    return NO;
  if (fabs(d.intensity - _intensity) > 1e-6)
    return NO;
  // Frequency only reads on the curves that expose it; ignore it elsewhere so a
  // stale slider value doesn't keep the buttons up on an otherwise-default
  // segment.
  if (_curveUsesFrequency(_kind, _curveType) &&
      fabs(d.frequency - _frequency) > 1e-6)
    return NO;
  return YES;
}

// Title-bar actions: [Reset][Make Default]. Both stay hidden while the segment
// already IS the saved default - there is nothing to save and nothing to go
// back to.
- (NSView *)defaultsAccessoryView {
  if (_defaultsAccessory)
    return _defaultsAccessory;

  BOOL hold = (_kind == KKSegmentEditKindHold);
  _defaultsAccessory = [[NSView alloc] initWithFrame:NSZeroRect];
  _defaultsAccessory.translatesAutoresizingMaskIntoConstraints = NO;

  _resetDefaultButton = KKDefaultsButton(
      KKLoc(@"Reset", @"Button: restore the saved default curve."),
      @"arrow.uturn.backward", [NSColor secondaryLabelColor], self,
      @selector(_resetToDefaultTapped:));
  _resetDefaultButton.toolTip =
      hold ? KKLoc(@"Put this modulation back to the saved default",
                   @"Tooltip for the modulate Reset button.")
           : KKLoc(@"Put this transition back to the saved default",
                   @"Tooltip for the Reset button.");
  [_defaultsAccessory addSubview:_resetDefaultButton];

  _makeDefaultButton = KKDefaultsButton(
      KKLoc(@"Make Default", @"Button: save these curve settings as default."),
      @"star", [NSColor accentMatchingHost], self,
      @selector(_makeDefaultTapped:));
  _makeDefaultButton.toolTip =
      hold ? KKLoc(@"Start every new segment in this plugin with this "
                   @"modulation, intensity and frequency",
                   @"Tooltip for the modulate Make Default button.")
           : KKLoc(@"Start every new transition in this plugin with this "
                   @"curve, intensity and frequency",
                   @"Tooltip for the Make Default button.");
  [_defaultsAccessory addSubview:_makeDefaultButton];

  [NSLayoutConstraint activateConstraints:@[
    [_resetDefaultButton.leadingAnchor
        constraintEqualToAnchor:_defaultsAccessory.leadingAnchor],
    [_resetDefaultButton.centerYAnchor
        constraintEqualToAnchor:_defaultsAccessory.centerYAnchor],
    [_makeDefaultButton.leadingAnchor
        constraintEqualToAnchor:_resetDefaultButton.trailingAnchor
                       constant:KKSpacingSM],
    [_makeDefaultButton.trailingAnchor
        constraintEqualToAnchor:_defaultsAccessory.trailingAnchor],
    [_makeDefaultButton.centerYAnchor
        constraintEqualToAnchor:_defaultsAccessory.centerYAnchor],
    [_defaultsAccessory.heightAnchor
        constraintEqualToAnchor:_makeDefaultButton.heightAnchor],
  ]];
  [self _updateDefaultsRow];
  return _defaultsAccessory;
}

- (void)_updateDefaultsRow {
  if (!_makeDefaultButton)
    return;
  BOOL matches = [self _matchesSavedDefault];
  _makeDefaultButton.hidden = matches;
  _resetDefaultButton.hidden = matches;
}

- (void)_makeDefaultTapped:(id)sender {
  KKCurveDefault d = {
      .curve = _curveType, .intensity = _intensity, .frequency = _frequency};
  if (_kind == KKSegmentEditKindHold) {
    d.curve = KKPillToModulation(_curveType);
    KKModulationDefaultsWrite(d, nil);
  } else {
    KKCurveDefaultsWrite(d, nil);
  }
  [self _updateDefaultsRow];
}

- (void)_resetToDefaultTapped:(id)sender {
  KKCurveDefault d = [self _savedDefault];
  // Three writes, one gesture: bracket them in the host's undo group so cmd-Z
  // takes the whole reset back rather than the frequency alone.
  if (self.onSliderDragBegin)
    self.onSliderDragBegin();
  self.curveType = d.curve;
  if (self.onCurveTypeChanged)
    self.onCurveTypeChanged(d.curve);
  self.intensity = d.intensity;
  if (self.onIntensityChanged)
    self.onIntensityChanged(d.intensity);
  self.frequency = d.frequency;
  if (self.onFrequencyChanged)
    self.onFrequencyChanged(d.frequency);
  if (self.onSliderDragEnd)
    self.onSliderDragEnd();
  [self _updateDefaultsRow];
}

// One stacked row, built the way every constants / keypose row is built: the
// lane describes the control (slider, checkbox, seed dice) and the row owns the
// geometry.
- (_KKStaticValueRow *)_addRowForLane:(KKLane *)lane
                          labelColumn:(CGFloat)labelColumn {
  _KKStaticValueRow *row = [[_KKStaticValueRow alloc] initWithLane:lane
                                                       showsRemove:NO
                                                showsAddToAnimated:NO
                                                       showsSmooth:NO
                                                    reservesGutter:NO
                                                  labelColumnWidth:labelColumn
                                                      contentWidth:kWidth];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [_rowStack addArrangedSubview:row];
  [row.widthAnchor constraintEqualToAnchor:_rowStack.widthAnchor].active = YES;
  return row;
}

- (void)buildUI {
  __weak typeof(self) weakSelf = self;

  NSView *pillTopReference = _bulkHeader ? [self _buildBulkHeaderRow] : nil;

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
    // Same names under each glyph: at low intensity Linear / Ease In / Ease Out
    // all plot as near-straight lines, so the shape alone can't identify them.
    _pills.pillCaptions = names;
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
    [self _applyHoldPreviewBand];
  }
  _pills.valueBlock = ^CGFloat(NSInteger pillIndex, CGFloat t) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return 0;
    // The preview plots the 0..1 shape even when the value is pushed past it
    // (modulation leaves intensity + frequency uncapped): beyond 1 the curve
    // math runs away and the auto-fitted glyph collapses into a spike, so the
    // pill would stop reading as the shape it names.
    double intensity = KKPreviewClamped(self.intensity);
    double frequency = KKPreviewClamped(self.frequency);
    if (self.kind == KKSegmentEditKindHold) {
      return KKApplyHoldEffect(t, (KKHoldEffect)pillIndex, intensity, frequency,
                               (int)self.seed);
    }
    // For animate-out, show the curve with time mirrored so the pill reads
    // as the value descending over time - matches the lane graph.
    double ti = self.animateOut ? (1.0 - t) : t;
    return KKApplyEasing(ti, (KKEasingCurve)pillIndex, intensity, frequency);
  };
  _pills.onSelectionChanged = ^(NSInteger index) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self)
      return;
    self->_curveType = index;
    [self _updateFrequencyVisibility];
    [self _updateDefaultsRow];
    if (self.onCurveTypeChanged)
      self.onCurveTypeChanged(index);
  };
  [self addSubview:_pills];

  // Every row below the pills is the SAME value row the constants + keypose
  // popovers use (_KKStaticValueRow), stacked at spacing 0: label column,
  // value control, scrub, reset-to-default, one shared rhythm. Each is fed a
  // synthetic single-keypose lane - these values live on the interval, not the
  // timeline - so the row code stays the one implementation everywhere.
  _rowStack = [NSStackView stackViewWithViews:@[]];
  _rowStack.translatesAutoresizingMaskIntoConstraints = NO;
  _rowStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _rowStack.spacing = 0;
  [self addSubview:_rowStack];

  CGFloat labelCol = [self _valueRowLabelColumnWidth];
  void (^dragBegin)(void) = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s.onSliderDragBegin)
      s.onSliderDragBegin();
  };
  void (^dragEnd)(void) = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s.onSliderDragEnd)
      s.onSliderDragEnd();
  };

  _intensityRow = [self _addRowForLane:[self _intensityLane]
                           labelColumn:labelCol];
  _intensityRow.defaultValues = @[ @(KKCurveDefaultBuiltIn.intensity) ];
  _intensityRow.onValue = ^(NSArray<NSNumber *> *values) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s || !values.count)
      return;
    s->_intensity = values[0].doubleValue;
    [s _applyHoldPreviewBand];
    [s->_pills redraw];
    [s _updateDefaultsRow];
    if (s.onIntensityChanged)
      s.onIntensityChanged(s->_intensity);
  };
  _intensityRow.onDragBegin = dragBegin;
  _intensityRow.onDragEnd = dragEnd;

  _frequencyRow = [self _addRowForLane:[self _frequencyLane]
                           labelColumn:labelCol];
  _frequencyRow.defaultValues = @[ @(KKCurveDefaultBuiltIn.frequency) ];
  _frequencyRow.onValue = ^(NSArray<NSNumber *> *values) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s || !values.count)
      return;
    s->_frequency = values[0].doubleValue;
    [s->_pills redraw];
    [s _updateDefaultsRow];
    if (s.onFrequencyChanged)
      s.onFrequencyChanged(s->_frequency);
  };
  _frequencyRow.onDragBegin = dragBegin;
  _frequencyRow.onDragEnd = dragEnd;

  if (_showsLinked) {
    _linkedRow = [self _addRowForLane:[self _linkedLane] labelColumn:labelCol];
    _linkedRow.toolTip = KKLoc(@"Maintain proportions across components (e.g. "
                               @"keep Radius X/Y aspect-locked through wobble)",
                               @"Tooltip for the Linked toggle.");
    _linkedRow.onValue = ^(NSArray<NSNumber *> *values) {
      __strong typeof(weakSelf) s = weakSelf;
      if (!s || !values.count)
        return;
      s->_linked = values[0].doubleValue >= 0.5;
      if (s.onLinkedChanged)
        s.onLinkedChanged(s->_linked);
    };
  }

  if (_kind == KKSegmentEditKindHold) {
    // The row's own dice button re-rolls within the lane's range and emits the
    // new value through onValue, so a re-roll and a typed seed take one path.
    _seedRow = [self _addRowForLane:[self _seedLane] labelColumn:labelCol];
    _seedRow.onValue = ^(NSArray<NSNumber *> *values) {
      __strong typeof(weakSelf) s = weakSelf;
      if (!s || !values.count)
        return;
      s->_seed = (uint32_t)values[0].doubleValue;
      [s->_pills redraw];
      if (s.onSeedChanged)
        s.onSeedChanged(s->_seed);
    };
  }

  [NSLayoutConstraint activateConstraints:@[
    [_pills.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                         constant:KKPaddingLG],
    [_pills.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                          constant:-KKPaddingLG],
    [_pills.topAnchor
        constraintEqualToAnchor:(pillTopReference
                                     ? pillTopReference.bottomAnchor
                                     : self.topAnchor)
                       constant:KKPaddingMD],
    [_pills.heightAnchor constraintEqualToConstant:kPillHeight],

    [_rowStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_rowStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_rowStack.topAnchor constraintEqualToAnchor:_pills.bottomAnchor
                                        constant:KKPaddingMD],
  ]];

  [self _updateFrequencyVisibility];

  if (_partLabels.count > 0 || _partCompoundLabels.count > 0) {
    NSTextField *cap =
        [NSTextField labelWithString:KKLoc(@"Applies to",
                                           @"Label: where a setting applies.")];
    cap.font = [NSFont systemFontOfSize:KKFontSizeSM
                                 weight:NSFontWeightRegular];
    cap.textColor = [NSColor inspectorLabel];
    cap.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:cap];

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
      [self _layoutParticipationCaption:cap checklist:_partChecklist];
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
      [self _layoutParticipationCaption:cap checklist:_partCompoundChecklist];
      return;
    }
  }
}

- (void)setLinked:(BOOL)linked {
  _linked = linked;
  [_linkedRow applyLane:[self _linkedLane]];
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
  [self _updateDefaultsRow];
}

- (void)setAnimateOut:(BOOL)animateOut {
  _animateOut = animateOut;
  [_pills redraw];
}

// The rows are backed by throwaway single-keypose lanes: the row renders any
// KKLane, and the interval - not the timeline - owns these numbers.
- (KKLane *)_laneForKey:(NSString *)key value:(double)value {
  KKLane *lane = [KKLane laneWithKey:key label:KKLocalizedParamName(key)];
  lane.valueType = KKLaneValueTypeFloat;
  lane.animatable = NO; // there is nothing here to keyframe
  lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:@[ @(value) ]] ];
  return lane;
}

// Float, one component, slider 0..1. `capped` also clamps the FIELD to 1 (an
// empty componentMax leaves it free to be typed past the slider's end).
- (KKLane *)_sliderLaneForKey:(NSString *)key
                        value:(double)value
                       capped:(BOOL)capped {
  KKLane *lane = [self _laneForKey:key value:value];
  lane.componentMin = @[ @0.0 ];
  lane.componentMax = capped ? @[ @1.0 ] : @[];
  lane.sliderMin = @0.0;
  lane.sliderMax = @1.0;
  return lane;
}

// A transition's curve SHAPE is a 0..100% dial: every easing reads intensity as
// a blend or a decay exponent, and past 1 they stop being stronger versions of
// themselves (ease overshoots extrapolate between two curves, elastic's
// envelope stops converging, bounce's restitution exceeds 1 and the ball gains
// energy). A modulation's intensity is an AMPLITUDE - `scale = intensity * 3`
// - so past 1 is just a bigger wobble, and the pill's preview band grows with
// it.
- (KKLane *)_intensityLane {
  return [self _sliderLaneForKey:kKKSegmentIntensityKey
                           value:_intensity
                          capped:(_kind == KKSegmentEditKindTransition)];
}

// Capped for a transition: the Bounce curve derives its bounce COUNT from
// frequency into a fixed-size array (KKEaseOutBounce), so >1 indexes past its
// end. A modulation's frequency is a plain rate multiplier on a sine, so it
// keeps going - a faster shake than the slider reaches.
- (KKLane *)_frequencyLane {
  return [self _sliderLaneForKey:kKKSegmentFrequencyKey
                           value:_frequency
                          capped:(_kind == KKSegmentEditKindTransition)];
}

// Structural on/off - the row's shared checkbox, right-aligned in the value
// column like every other toggle lane in the kit.
- (KKLane *)_linkedLane {
  KKLane *lane = [self _laneForKey:kKKSegmentLinkedKey
                             value:(_linked ? 1.0 : 0.0)];
  lane.integerValued = YES;
  lane.isToggle = YES;
  lane.componentMin = @[ @0.0 ];
  lane.componentMax = @[ @1.0 ];
  return lane;
}

// A random integer, not a range: the row builds the seed control (value +
// re-roll) instead of a slider, and re-rolls within componentMax.
- (KKLane *)_seedLane {
  KKLane *lane = [self _laneForKey:kKKSegmentSeedKey value:(double)_seed];
  lane.integerValued = YES;
  lane.seedField = YES;
  lane.componentMin = @[ @0.0 ];
  lane.componentMax = @[ @99999.0 ];
  return lane;
}

// One column across every row, so the value controls line up with each other
// and with the constants popover's rows.
- (CGFloat)_valueRowLabelColumnWidth {
  NSMutableArray<KKLane *> *lanes = [NSMutableArray
      arrayWithObjects:[self _intensityLane], [self _frequencyLane], nil];
  if (_showsLinked)
    [lanes addObject:[self _linkedLane]];
  if (_kind == KKSegmentEditKindHold)
    [lanes addObject:[self _seedLane]];
  return [_KKStaticValueRow labelColumnWidthForLanes:lanes];
}

// Hold pills plot against a FIXED band (auto-fit would normalise the amplitude
// straight back out). The band spans the intensity the preview DRAWS - clamped
// to 1 like the waveform itself - so the two grow together instead of the band
// outrunning a curve that has stopped growing.
- (void)_applyHoldPreviewBand {
  if (_kind != KKSegmentEditKindHold)
    return;
  double span = MAX(0.6, KKPreviewClamped(_intensity));
  _pills.fixedMin = 1.0 - span;
  _pills.fixedMax = 1.0 + span;
}

// Elastic / Bounce (and the hold effects) are the only shapes Frequency means
// anything for; elsewhere the row collapses away (the stack drops a hidden
// arranged row) rather than sitting inert, so the popover shrinks to what it
// actually offers.
- (void)_updateFrequencyVisibility {
  BOOL showFreq = _curveUsesFrequency(_kind, _curveType);
  if (_frequencyRow.hidden == !showFreq)
    return;
  _frequencyRow.hidden = !showFreq;
  // The host owns the popover's size, so tell it the content height moved.
  if (self.onContentHeightChanged)
    self.onContentHeightChanged();
}

- (void)setIntensity:(double)intensity {
  _intensity = intensity;
  [self _applyHoldPreviewBand];
  [_intensityRow applyLane:[self _intensityLane]];
  [_pills redraw];
  [self _updateDefaultsRow];
}

- (void)setFrequency:(double)frequency {
  _frequency = frequency;
  [_frequencyRow applyLane:[self _frequencyLane]];
  [_pills redraw];
  [self _updateDefaultsRow];
}

- (void)setSeed:(uint32_t)seed {
  _seed = seed;
  [_seedRow applyLane:[self _seedLane]];
  [_pills redraw];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window) {
    // Prevent the popover from auto-focusing the seed field on open so
    // spacebar still controls timeline playback.
    [self.window makeFirstResponder:nil];
    // In an NSPopover the wash is ours to paint. A floating panel already
    // paints KKPanelBackingFill over its whole content, header included, so
    // painting again here made the body darker than the header.
    if (![self.window isKindOfClass:[KKFloatingPanel class]])
      KKApplyPopoverBackground(self);
  }
}

- (KKCurvePillView *)_guidePillsView {
  return _pills;
}

@end
