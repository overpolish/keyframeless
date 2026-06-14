/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKColorWellView.h"
#import "KKGradientBarView.h"
#import "KKGradientControl.h"
#import "KKGradientSampling.h"
#import "KKLocalized.h"
#import "KKMiniViewerView.h"
#import "KKPillToggleRowView.h"
#import "KKPopoverHeaderView.h"
#import "KKSeedView.h"
#import "KKSliderView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTokens.h"
#import "KKValueTextField.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/QuartzCore.h>

const CGFloat kFloatRowH = 30.0;
static const CGFloat kCropRowH = 30.0;     // single-line W/H/X/Y hstack
static const CGFloat kGradientRowH = 42.0; // 36pt gradient control + padding
static const CGFloat kStaticFieldW = 40.0;
// Cap on the (uniform) label column so a long localized name (e.g. German
// "Geschwindigkeit") can't push the value controls off the popover's right
// edge. Longer names truncate with an ellipsis; the full name shows on hover.
static const CGFloat kMaxLabelColW = 86.0;

static NSTextField *_KKMakeNumberField(void) {
  return [KKValueTextField valueField];
}

NSTextField *_KKMakeCaption(NSString *s) {
  NSTextField *l = [NSTextField labelWithString:s];
  l.translatesAutoresizingMaskIntoConstraints = NO;
  l.font = [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightRegular];
  l.textColor = [NSColor inspectorLabel];
  return l;
}

// Reserved widths for the prefix caption and unit suffix, kept whether or not
// either renders so the value column lands in the same place on every row
// (e.g. "1080" lines up across rows whether or not there's a leading "H" or a
// trailing "px"/"%"). Prefix fits one caption character.
static const CGFloat kPrefixSlotW = 13.0;
static const CGFloat kSuffixSlotW = 17.0;

// A right-aligned number field flanked by fixed-width prefix (caption) and
// suffix (unit) slots. Both slots are always present so columns line up; pass
// nil/@"" for an absent prefix/unit. The inner `field` is exposed for
// target/action, delegate, and guide wiring.
@interface _KKValueField : NSView
@property(nonatomic, readonly) NSTextField *field;
- (void)setPrefix:(nullable NSString *)prefix;
- (void)setPrefixColor:(nullable NSColor *)color;
- (void)setSuffix:(nullable NSString *)suffix;
@end

@implementation _KKValueField {
  NSTextField *_prefix;
  NSTextField *_suffix;
}
- (instancetype)init {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  _prefix = _KKMakeCaption(@"");
  _prefix.alignment = NSTextAlignmentLeft;
  _field = _KKMakeNumberField();
  _suffix = _KKMakeCaption(@"");
  _suffix.alignment = NSTextAlignmentLeft;
  _suffix.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.5];
  [self addSubview:_prefix];
  [self addSubview:_field];
  [self addSubview:_suffix];
  [NSLayoutConstraint activateConstraints:@[
    [_prefix.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_prefix.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_prefix.widthAnchor constraintEqualToConstant:kPrefixSlotW],
    [_field.leadingAnchor constraintEqualToAnchor:_prefix.trailingAnchor
                                         constant:KKPaddingXS],
    [_field.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_field.widthAnchor constraintEqualToConstant:kStaticFieldW],
    [_suffix.leadingAnchor constraintEqualToAnchor:_field.trailingAnchor
                                          constant:KKPaddingXS],
    [_suffix.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_suffix.widthAnchor constraintEqualToConstant:kSuffixSlotW],
    [_suffix.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
  ]];
  return self;
}
- (void)setPrefix:(NSString *)prefix {
  _prefix.stringValue = prefix ?: @"";
}
- (void)setPrefixColor:(NSColor *)color {
  _prefix.textColor = color ?: [NSColor inspectorLabel];
}
- (void)setSuffix:(NSString *)suffix {
  _suffix.stringValue = suffix ?: @"";
}
@end

// Small borderless SF-symbol button for the leading gutter (− remove / + add).
// Template image → tints with contentTintColor.
NSButton *_KKGutterGlyphButton(NSString *symbol, id target, SEL action,
                               NSColor *tint) {
  NSImage *img = [NSImage imageWithSystemSymbolName:symbol
                           accessibilityDescription:nil];
  NSButton *b = [NSButton buttonWithImage:img ?: [[NSImage alloc] init]
                                   target:target
                                   action:action];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.contentTintColor = tint;
  return b;
}

@implementation _KKStaticValueRow {
  KKLaneValueType _valueType;
  NSArray<NSNumber *> *_cmin;
  NSArray<NSNumber *> *_cmax;
  NSArray<NSString *> *_cunits;
  KKSliderView *_slider;            // Float only
  NSArray<NSSlider *> *_angleKnobs; // Angle only - one per component
  NSMutableArray<NSNumber *>
      *_prevKnobValues; // last seen knob position per knob
  BOOL _angleKnobDragging;
  NSArray<NSTextField *> *_fields;     // Float: 1; Angle: N; Crop: 4 (w,h,x,y)
  NSMutableArray<NSNumber *> *_values; // normalized, authoritative
  NSButton *_reset;                    // reset-to-default, right of the label
  NSButton *_removeBtn;                // leading "−" gutter (Advanced only)
  NSButton *_addBtn;                   // leading curve-glyph gutter (constants)
  NSArray<NSNumber *> *_defaultValues;
  NSButton *_smoothBtn; // curve toggle, left of the value fields
  BOOL _smoothOn;
  NSButton *_linkBtn; // aspect-link toggle, left of the value fields
  BOOL _linkOn;
  BOOL _integerValued;            // fields display + round to whole numbers
  BOOL _componentsScaleWithMedia; // display = norm x media px
                                  // (Position/Anchor/Crop)
  double _laneScrubStep;          // lane's explicit scrub increment (0 = auto)
  KKSeedView *_seedView; // seed control (value + re-roll), seedField lanes only
  BOOL _seedField;
  KKPillToggleRowView *_choicePill;    // grouped radio pill, choiceLabels only
  NSArray<NSString *> *_choiceLabels;  // English identifiers (count >= 2)
  KKColorWellView *_colorWell;         // swatch, KKLaneValueTypeColor only
  KKGradientControl *_gradientControl; // KKLaneValueTypeGradient only
  BOOL
      _suppressGradientRefresh; // mid own-edit: don't reset the control's stops
  BOOL _gradientWithTypeAngle;  // value = [type, angle, <flat stops>]
  KKPillToggleRowView *_gradientTypePill; // radial/linear, composite only
  NSView *_gradientAngleContainer;        // knob + field, hidden unless linear
  NSSlider *_gradientAngleKnob;
  NSTextField *_gradientAngleField;
  BOOL _gradientAngleKnobDragging;
  CGFloat _labelColumnW; // uniform label-column width (0 = natural)
}

- (void)setDefaultValues:(NSArray<NSNumber *> *)defaultValues {
  _defaultValues = [defaultValues copy];
  [self _updateResetVisibility];
}

- (NSArray<NSNumber *> *)defaultValues {
  return _defaultValues;
}

// Reset is only meaningful when a default exists AND the current value
// differs from it - hidden otherwise so a row at default has no clutter.
- (void)_updateResetVisibility {
  BOOL atDefault =
      _defaultValues.count > 0 && _values.count == _defaultValues.count;
  for (NSInteger i = 0; atDefault && i < (NSInteger)_values.count; i++)
    if (fabs(_values[i].doubleValue - _defaultValues[i].doubleValue) > 1e-6)
      atDefault = NO;
  _reset.hidden = (_defaultValues.count == 0) || atDefault;
}

- (void)_resetTapped:(id)sender {
  // Drop focus from any field still being edited first - otherwise
  // refreshDisplay skips the focused field and the reset value won't appear in
  // it (the editor's typed text lingers).
  [self.window makeFirstResponder:nil];
  if (_defaultValues.count)
    [self _setValues:_defaultValues emit:YES]; // commits like a field edit
}

- (void)_removeTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  if (self.onRemove)
    self.onRemove();
}

- (void)_addToAnimatedTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  if (self.onAddToAnimated)
    self.onAddToAnimated();
}

// Curve glyph that flips this keypose corner↔smooth. Same SF Symbol the gap
// popover uses for its "Curve" header, so the spatial-curve and timing-curve
// affordances read consistently. Lit/accent = smooth, dim = corner.
- (NSButton *)_makeSmoothToggle {
  NSImage *img = [NSImage
      imageWithSystemSymbolName:@"point.topleft.down.to.point.bottomright."
                                @"curvepath"
       accessibilityDescription:nil];
  if (!img)
    img = [NSImage imageWithSystemSymbolName:@"scribble"
                    accessibilityDescription:nil];
  NSButton *b = [NSButton buttonWithImage:img ?: [[NSImage alloc] init]
                                   target:self
                                   action:@selector(_smoothTapped:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.toolTip = KKLoc(@"Smooth path through this keypose",
                    @"Tooltip: per-keypose curve toggle on the Position row.");
  [NSLayoutConstraint activateConstraints:@[
    [b.widthAnchor constraintEqualToConstant:15.0],
    [b.heightAnchor constraintEqualToConstant:15.0],
  ]];
  return b;
}

- (void)_updateSmoothTint {
  _smoothBtn.contentTintColor =
      _smoothOn ? [NSColor accentMatchingHost]
                : [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
}

- (void)_smoothTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  _smoothOn = !_smoothOn;
  [self _updateSmoothTint];
  if (self.onSmoothToggled)
    self.onSmoothToggled(_smoothOn);
}

- (void)applySmooth:(BOOL)on {
  _smoothOn = on;
  [self _updateSmoothTint];
}

// Link glyph that aspect-locks the two components: editing one scales the other
// by the same factor, preserving their current ratio. Global per-lane toggle.
// Lit/accent = linked, dim = unlinked.
- (NSButton *)_makeLinkToggle {
  NSImage *img = [NSImage imageWithSystemSymbolName:@"link"
                           accessibilityDescription:nil];
  NSButton *b = [NSButton buttonWithImage:img ?: [[NSImage alloc] init]
                                   target:self
                                   action:@selector(_linkTapped:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.toolTip = KKLoc(@"Link X and Y (lock aspect ratio)",
                    @"Tooltip: aspect-link toggle on the Scale row.");
  [NSLayoutConstraint activateConstraints:@[
    [b.widthAnchor constraintEqualToConstant:15.0],
    [b.heightAnchor constraintEqualToConstant:15.0],
  ]];
  return b;
}

- (void)_updateLinkTint {
  _linkBtn.contentTintColor =
      _linkOn ? [NSColor accentMatchingHost]
              : [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
}

- (void)_linkTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  _linkOn = !_linkOn;
  [self _updateLinkTint];
  if (self.onLinkToggled)
    self.onLinkToggled(_linkOn);
}

- (void)applyLink:(BOOL)on {
  _linkOn = on;
  [self _updateLinkTint];
}

// Display = stored(normalized) × scale; stored = entered ÷ scale. Lets the
// crop fields show pixels while the model stays 0–1. 1.0 == show raw.
- (double)_scaleAt:(NSInteger)i {
  double s = _componentScale ? _componentScale(i) : 1.0;
  return s > 0 ? s : 1.0;
}

// Scrub step matching the component's displayed precision: whole numbers for
// pixel-scaled (crop), integer, and angle fields; 0.01 for raw 2-decimal
// fields (scale, radius, 0..1 factors). Shift/Option scale this at drag time.
- (double)_scrubStepForComponent:(NSInteger)i {
  if (_laneScrubStep > 0)
    return _laneScrubStep; // plugin-specified increment wins over the auto rule
  if (_valueType == KKLaneValueTypeAngle)
    return 1.0;
  // Pixel-displayed (media-scaled), integer, and crop fields step by whole
  // units. Key off componentsScaleWithMedia rather than the runtime scale:
  // the scale resolves lazily (0 until the mini-viewer feed arrives), so at
  // construction _scaleAt: would read 1.0 and mis-pick the 0.01 raw step -
  // making a Position/Anchor scrub move 0.01px per step (invisible).
  BOOL intFmt = _componentsScaleWithMedia || _integerValued;
  return intFmt ? 1.0 : 0.01;
}

// Wire a freshly created value field for scrubbing: per-component step plus
// drag-undo bracketing through the row's onDragBegin/onDragEnd.
- (void)_configureScrubForField:(NSTextField *)fld component:(NSInteger)i {
  if (![fld isKindOfClass:[KKValueTextField class]])
    return;
  KKValueTextField *vf = (KKValueTextField *)fld;
  vf.scrubStep = [self _scrubStepForComponent:i];
  __weak typeof(self) weak = self;
  vf.onScrubBegin = ^{
    if (weak.onDragBegin)
      weak.onDragBegin();
  };
  vf.onScrubEnd = ^{
    if (weak.onDragEnd)
      weak.onDragEnd();
  };
}

- (BOOL)isFlipped {
  return YES;
}

+ (CGFloat)heightForLane:(KKLane *)lane {
  if (lane.valueType == KKLaneValueTypeGradient)
    return kGradientRowH;
  return KKLaneComponentLabels(lane).count >= 2 ? kCropRowH : kFloatRowH;
}

// NSStackView sizes arranged rows by their intrinsic height; without this
// the rows collapse on top of each other (no height constraint otherwise).
- (NSSize)intrinsicContentSize {
  CGFloat h = _gradientControl ? kGradientRowH
                               : (_fields.count >= 2 ? kCropRowH : kFloatRowH);
  return NSMakeSize(NSViewNoIntrinsicMetric, h);
}

- (double)_clamp:(double)v index:(NSInteger)i {
  if (i < (NSInteger)_cmin.count && v < _cmin[i].doubleValue)
    v = _cmin[i].doubleValue;
  if (i < (NSInteger)_cmax.count && v > _cmax[i].doubleValue)
    v = _cmax[i].doubleValue;
  return v;
}

// normalized (clamped) → display string in scaled units. Pixel-scaled
// fields (scale ≠ 1, i.e. crop) show whole numbers; raw fields (radius)
// keep 2 decimals.
- (NSString *)_displayForNorm:(double)norm index:(NSInteger)i {
  double scale = [self _scaleAt:i];
  BOOL intFmt = (scale != 1.0) || _integerValued;
  double dv = norm * scale;
  // Round to the displayed precision first, then squash -0 → 0 so a tiny
  // negative never shows as "-0".
  dv = intFmt ? round(dv) : round(dv * 100.0) / 100.0;
  if (dv == 0.0)
    dv = 0.0;
  return [NSString stringWithFormat:(intFmt ? @"%.0f" : @"%.2f"), dv];
}

+ (CGFloat)labelColumnWidthForLanes:(NSArray<KKLane *> *)lanes {
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular]
  };
  CGFloat w = 0;
  for (KKLane *lane in lanes) {
    NSString *name = KKLocalizedParamName(lane.label);
    w = MAX(w, ceil([name sizeWithAttributes:attrs].width));
  }
  // Trailing breathing room so the value controls never butt up against the
  // widest label, capped so a very long localized name can't eat the row.
  return w > 0 ? MIN(w + KKPaddingMD, kMaxLabelColW) : w;
}

- (instancetype)initWithLane:(KKLane *)lane
                 showsRemove:(BOOL)showsRemove
          showsAddToAnimated:(BOOL)showsAddToAnimated
                 showsSmooth:(BOOL)showsSmooth
            labelColumnWidth:(CGFloat)labelColumnWidth {
  CGFloat h = [_KKStaticValueRow heightForLane:lane];
  self = [super initWithFrame:NSMakeRect(0, 0, kCanvasPopoverW, h)];
  if (!self)
    return nil;
  _laneLabel = [lane.label copy];
  _valueType = lane.valueType;
  _cmin = lane.componentMin ?: @[];
  _cmax = lane.componentMax ?: @[];
  _cunits = lane.componentUnits ?: @[];
  _integerValued = lane.integerValued;
  _componentsScaleWithMedia = lane.componentsScaleWithMedia;
  _laneScrubStep = lane.scrubStep;
  _seedField = lane.seedField;
  _choiceLabels = [lane.choiceLabels copy];
  _labelColumnW = labelColumnWidth;

  NSTextField *title = _KKMakeCaption(KKLocalizedParamName(lane.label));
  // Truncate a too-long localized name to an ellipsis (the column is capped);
  // the full name is on hover so nothing is lost.
  title.lineBreakMode = NSLineBreakByTruncatingTail;
  title.usesSingleLineMode = YES;
  title.toolTip = KKLocalizedParamName(lane.label);
  [self addSubview:title];
  // Uniform label column so the value controls line up across rows regardless
  // of label length (widest localized name); 54 is the legacy fallback.
  [title.widthAnchor
      constraintEqualToConstant:(_labelColumnW > 0 ? _labelColumnW : 54.0)]
      .active = YES;

  // Leading gutter, shared slot. Keypose popover (Advanced) uses "−" to
  // remove this lane's KP at the open fraction; constants popover uses the
  // animation curve glyph to flip the lane to animatable (mirrors the
  // lane-manager dropdown). The two are mutually exclusive - a row is
  // either editing a KP value or a constant, never both.
  NSLayoutXAxisAnchor *titleLead = self.leadingAnchor;
  CGFloat titleLeadInset = KKPaddingLG;
  NSButton *gutterBtn = nil;
  if (showsRemove) {
    _removeBtn = _KKGutterGlyphButton(
        @"minus", self, @selector(_removeTapped:),
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.55]);
    gutterBtn = _removeBtn;
  } else if (showsAddToAnimated) {
    // SF Symbol "point.bottomleft.forward.to.point.topright.scurvepath"
    // reads as an animation curve - same metaphor as keyframe gizmos in
    // other tools. Falls back to "waveform.path" on older OS versions.
    NSImage *curve =
        [NSImage imageWithSystemSymbolName:@"point.bottomleft.forward.to.point."
                                           @"topright.scurvepath"
                  accessibilityDescription:nil];
    if (!curve)
      curve = [NSImage imageWithSystemSymbolName:@"waveform.path"
                        accessibilityDescription:nil];
    _addBtn = [NSButton buttonWithImage:curve ?: [[NSImage alloc] init]
                                 target:self
                                 action:@selector(_addToAnimatedTapped:)];
    _addBtn.translatesAutoresizingMaskIntoConstraints = NO;
    _addBtn.bordered = NO;
    _addBtn.bezelStyle = NSBezelStyleShadowlessSquare;
    _addBtn.imageScaling = NSImageScaleProportionallyDown;
    _addBtn.contentTintColor =
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
    gutterBtn = _addBtn;
  }
  if (gutterBtn) {
    [self addSubview:gutterBtn];
    [NSLayoutConstraint activateConstraints:@[
      [gutterBtn.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                              constant:KKPaddingMD],
      [gutterBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [gutterBtn.widthAnchor constraintEqualToConstant:15.0],
      [gutterBtn.heightAnchor constraintEqualToConstant:15.0],
    ]];
    titleLead = gutterBtn.trailingAnchor;
    titleLeadInset = KKPaddingSM;
  }

  _reset = KKResetToDefaultButton(self, @selector(_resetTapped:));
  [self addSubview:_reset];
  // Trailing-most element so its position is identical on every lane row,
  // regardless of label/control widths.
  [NSLayoutConstraint activateConstraints:@[
    [_reset.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                          constant:-KKPaddingLG],
    [_reset.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_reset.widthAnchor constraintEqualToConstant:15.0],
    [_reset.heightAnchor constraintEqualToConstant:15.0],
  ]];

  NSArray<NSString *> *caps = KKLaneComponentLabels(lane);
  NSArray<NSColor *> *capColors = lane.componentLabelColors;
  if (_choiceLabels.count >= 2) {
    // A structural enum (e.g. a colour mode): a grouped radio pill, one segment
    // per choice, instead of a number field. The lane's single value is the
    // selected index. Labels localize at display time like any param name.
    NSMutableArray<NSString *> *locLabels =
        [NSMutableArray arrayWithCapacity:_choiceLabels.count];
    for (NSString *c in _choiceLabels)
      [locLabels addObject:KKLocalizedParamName(c)];
    _choicePill = [[KKPillToggleRowView alloc] initWithLabels:locLabels];
    _choicePill.radioMode = YES;
    _choicePill.grouped = YES;
    _choicePill.hidesGroupTrack = YES; // inline selector, not a nav bar
    _choicePill.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weak = self;
    _choicePill.onToggled = ^(NSInteger index, BOOL isOn) {
      if (isOn)
        [weak _setValues:@[ @((double)index) ] emit:YES];
    };
    [self addSubview:_choicePill];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_choicePill.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                                 constant:-KKPaddingLG],
      [_choicePill.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                      constant:KKPaddingMD],
      [_choicePill.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
  } else if (_valueType == KKLaneValueTypeColor) {
    // A solid colour: a swatch that opens the system colour panel. Stored as
    // [r, g, b, a] in sRGB 0..1 (the shader linearises). KKColorWellView is a
    // dumb NSView - no FxPlug action scope needed.
    _colorWell = [[KKColorWellView alloc] initWithFrame:NSZeroRect];
    _colorWell.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weak = self;
    _colorWell.onColorChanged = ^(NSColor *c) {
      NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: c;
      CGFloat r = 0, g = 0, b = 0, a = 1;
      [s getRed:&r green:&g blue:&b alpha:&a];
      [weak _setValues:@[ @(r), @(g), @(b), @(a) ] emit:YES];
    };
    _colorWell.onColorEditingChanged = ^(BOOL editing) {
      __strong typeof(weak) ss = weak;
      if (ss.onColorEditing)
        ss.onColorEditing(editing);
    };
    [self addSubview:_colorWell];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_colorWell.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                                constant:-KKPaddingLG],
      [_colorWell.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                      constant:KKPaddingMD],
      [_colorWell.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_colorWell.widthAnchor constraintEqualToConstant:28.0],
      [_colorWell.heightAnchor constraintEqualToConstant:16.0],
    ]];
  } else if (_valueType == KKLaneValueTypeGradient) {
    // The shared gradient editor (bar + favourites/reverse/distribute). Stored
    // as a flat [pos, r, g, b, mid] per stop; the row converts to/from
    // KKGradientStop. Editing a stop opens the shared colour panel, so it
    // reports onColorEditing up to suspend the popover's dismissal (same as the
    // solid swatch).
    _gradientWithTypeAngle = lane.gradientShowsTypeAngle;
    __weak typeof(self) weak = self;
    _gradientControl = [[KKGradientControl alloc] initWithFrame:NSZeroRect];
    _gradientControl.translatesAutoresizingMaskIntoConstraints = NO;
    // Without an explicit height the control collapses (its bar is pinned to
    // its own top/bottom), leaving a zero-height, un-clickable strip.
    [_gradientControl.heightAnchor constraintEqualToConstant:36.0].active = YES;
    [_gradientControl
        setContentHuggingPriority:1
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
    _gradientControl.onStopsChanged = ^(NSArray<KKGradientStop *> *stops) {
      __strong typeof(weak) ss = weak;
      if (!ss)
        return;
      ss->_suppressGradientRefresh = YES;
      [ss _setValues:[ss _composeGradientWithStops:stops] emit:YES];
      ss->_suppressGradientRefresh = NO;
    };
    _gradientControl.onDragBegin = ^{
      __strong typeof(weak) ss = weak;
      if (ss.onDragBegin)
        ss.onDragBegin();
    };
    _gradientControl.onDragEnd = ^{
      __strong typeof(weak) ss = weak;
      if (ss.onDragEnd)
        ss.onDragEnd();
    };
    _gradientControl.onColorEditingChanged = ^(BOOL editing) {
      __strong typeof(weak) ss = weak;
      if (ss.onColorEditing)
        ss.onColorEditing(editing);
    };

    NSMutableArray<NSView *> *arranged = [NSMutableArray array];
    if (_gradientWithTypeAngle) {
      // Radial/linear toggle (value[0]). Type is a single, non-animated
      // property: in the per-keypose editor the change is routed via
      // onGradientTypeChanged to ALL keyposes (so type stays editable once
      // animated); in the constants editor (no handler) it commits normally.
      _gradientTypePill = [[KKPillToggleRowView alloc] initWithLabels:@[
        KKLocalizedParamName(@"Radial"), KKLocalizedParamName(@"Linear")
      ]];
      _gradientTypePill.radioMode = YES;
      _gradientTypePill.grouped = YES;
      _gradientTypePill.hidesGroupTrack = YES; // inline, not a nav bar
      _gradientTypePill.translatesAutoresizingMaskIntoConstraints = NO;
      _gradientTypePill.onToggled = ^(NSInteger index, BOOL isOn) {
        __strong typeof(weak) ss = weak;
        if (!ss || !isOn)
          return;
        NSMutableArray<NSNumber *> *v = [ss->_values mutableCopy];
        if (v.count >= 1)
          v[0] = @((double)index);
        if (ss.onGradientTypeChanged) {
          [ss _setValues:v emit:NO];       // immediate UI (angle reveal)
          ss.onGradientTypeChanged(index); // persists across all keyposes
        } else {
          [ss _setValues:v emit:YES]; // constants: commit the single keypose
        }
      };
      [arranged addObject:_gradientTypePill];

      _gradientAngleKnob = [[NSSlider alloc] initWithFrame:NSZeroRect];
      _gradientAngleKnob.sliderType = NSSliderTypeCircular;
      _gradientAngleKnob.controlSize = NSControlSizeMini;
      _gradientAngleKnob.minValue = 0.0;
      _gradientAngleKnob.maxValue = 360.0;
      _gradientAngleKnob.continuous = YES;
      _gradientAngleKnob.target = self;
      _gradientAngleKnob.action = @selector(_gradientAngleKnobMoved:);
      _gradientAngleKnob.translatesAutoresizingMaskIntoConstraints = NO;
      _KKValueField *angleCell = [[_KKValueField alloc] init];
      [angleCell setSuffix:@"°"];
      _gradientAngleField = angleCell.field;
      _gradientAngleField.target = self;
      _gradientAngleField.action = @selector(_gradientAngleFieldCommitted:);
      _gradientAngleField.delegate = (id<NSTextFieldDelegate>)self;
      if ([_gradientAngleField isKindOfClass:[KKValueTextField class]]) {
        KKValueTextField *gf = (KKValueTextField *)_gradientAngleField;
        gf.scrubStep = 1.0; // degrees
        __weak typeof(self) weak = self;
        gf.onScrubBegin = ^{
          if (weak.onDragBegin)
            weak.onDragBegin();
        };
        gf.onScrubEnd = ^{
          if (weak.onDragEnd)
            weak.onDragEnd();
        };
      }
      _gradientAngleContainer =
          [NSStackView stackViewWithViews:@[ _gradientAngleKnob, angleCell ]];
      ((NSStackView *)_gradientAngleContainer).spacing = KKSpacingSM;
      ((NSStackView *)_gradientAngleContainer).alignment =
          NSLayoutAttributeCenterY;
      _gradientAngleContainer.translatesAutoresizingMaskIntoConstraints = NO;
      [arranged addObject:_gradientAngleContainer];
    }
    [arranged addObject:_gradientControl];

    NSStackView *hs = [NSStackView stackViewWithViews:arranged];
    hs.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hs.alignment = NSLayoutAttributeCenterY;
    hs.spacing = KKPaddingMD;
    hs.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:hs];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [hs.leadingAnchor constraintEqualToAnchor:title.trailingAnchor
                                       constant:KKPaddingMD],
      [hs.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                        constant:-KKPaddingLG],
      [hs.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
  } else if (_seedField) {
    // A random integer, not a range: the gap-popover seed control (value +
    // re-roll) instead of a slider. Stored as the lane's single value.
    _seedView = [[KKSeedView alloc] init];
    _seedView.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weak = self;
    _seedView.onSeedChanged = ^(uint32_t s) {
      [weak _setValues:@[ @((double)s) ] emit:YES];
    };
    _seedView.onReroll = ^{
      __strong typeof(weak) ss = weak;
      // Re-roll within the lane's range so values stay evenly distributed
      // (a fixed 0..100000 would clamp-pile onto the max for a small range).
      uint32_t hi =
          ss->_cmax.count ? (uint32_t)ss->_cmax[0].doubleValue : 99999;
      uint32_t s = arc4random_uniform(hi + 1);
      ss->_seedView.seed = s;
      [ss _setValues:@[ @((double)s) ] emit:YES];
    };
    [self addSubview:_seedView];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_seedView.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                               constant:-KKPaddingLG],
      [_seedView.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                      constant:KKPaddingMD],
      // The seed control has no intrinsic height; without pinning it to the
      // row it collapses to a zero-height frame and its field/button fall
      // outside hit-testing (looks disabled). Fill the row's height.
      [_seedView.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_seedView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
  } else if (caps.count >= 2 ||
             (_valueType == KKLaneValueTypeAngle && caps.count >= 1)) {
    // Angle lanes (knob + field) route here for a single component too - a lone
    // angle (e.g. a gradient direction) still wants the circular knob, not a
    // 0..1 slider.
    NSInteger n = (NSInteger)caps.count;
    NSMutableArray<NSView *> *arranged = [NSMutableArray array];
    NSMutableArray<NSTextField *> *fs = [NSMutableArray array];
    NSMutableArray<NSSlider *> *knobs = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
      _KKValueField *cell = [[_KKValueField alloc] init];
      NSString *prefix = caps[i].length ? caps[i] : nil;
      if (prefix)
        [cell setPrefix:prefix];
      [cell setSuffix:(i < (NSInteger)_cunits.count ? _cunits[i] : nil)];
      if (i < (NSInteger)capColors.count) {
        NSColor *c = capColors[i];
        if ([c isKindOfClass:[NSColor class]])
          [cell setPrefixColor:c];
      }
      NSTextField *fld = cell.field;
      fld.target = self;
      fld.action = @selector(_fieldCommitted:);
      fld.delegate = (id<NSTextFieldDelegate>)self; // live-typing for a guide
      [self _configureScrubForField:fld component:i];
      [fs addObject:fld];
      if (_valueType == KKLaneValueTypeAngle) {
        // Mini circular knob ahead of each field. Range -180..180 so one
        // physical revolution of the knob = 360° of value (1:1). Field
        // still accepts the full lane range (e.g. ±360) for multi-turn
        // values; the knob clamps but the model doesn't.
        NSSlider *knob = [[NSSlider alloc] initWithFrame:NSZeroRect];
        knob.sliderType = NSSliderTypeCircular;
        // NSSlider circular ignores width/height constraints; controlSize
        // is the only knob that actually changes its visual diameter.
        knob.controlSize = NSControlSizeMini;
        knob.minValue = -180.0;
        knob.maxValue = 180.0;
        knob.continuous = YES;
        knob.tag = i;
        knob.target = self;
        knob.action = @selector(_angleKnobMoved:);
        knob.translatesAutoresizingMaskIntoConstraints = NO;
        [knobs addObject:knob];
        NSStackView *entry = [NSStackView stackViewWithViews:@[ knob, cell ]];
        entry.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        entry.alignment = NSLayoutAttributeCenterY;
        entry.spacing = KKSpacingMD;
        entry.translatesAutoresizingMaskIntoConstraints = NO;
        [arranged addObject:entry];
      } else {
        [arranged addObject:cell];
      }
      if (i < n - 1) { // divider between each component group
        NSView *div = [[NSView alloc] init];
        div.translatesAutoresizingMaskIntoConstraints = NO;
        div.wantsLayer = YES;
        div.layer.backgroundColor =
            [[NSColor inspectorLabel] colorWithAlphaComponent:0.25].CGColor;
        [div.widthAnchor constraintEqualToConstant:1.0].active = YES;
        [div.heightAnchor constraintEqualToConstant:16.0].active = YES;
        [arranged addObject:div];
      }
    }
    // Curve toggle rides just left of the X/Y fields (reset stays trailing).
    if (showsSmooth) {
      _smoothOn =
          lane.keyposes.count ? lane.keyposes.firstObject.spatialSmooth : NO;
      _smoothBtn = [self _makeSmoothToggle];
      [self _updateSmoothTint];
      [arranged insertObject:_smoothBtn atIndex:0];
    }
    // Aspect-link toggle shares that slot (Scale uses it; mutually exclusive
    // with the smooth toggle in practice). Global per-lane, shown in both the
    // constants and keypose popovers, so it is not gated on _editsKeypose.
    if (lane.aspectLinkable) {
      _linkOn = lane.aspectLinked;
      _linkBtn = [self _makeLinkToggle];
      [self _updateLinkTint];
      [arranged insertObject:_linkBtn atIndex:0];
    }
    NSStackView *hs = [NSStackView stackViewWithViews:arranged];
    hs.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hs.alignment = NSLayoutAttributeCenterY;
    hs.spacing = KKPaddingMD;
    // Give the curve toggle more breathing room from the value fields, matching
    // the reset button's padding rather than the tight inter-field spacing.
    if (_smoothBtn)
      [hs setCustomSpacing:KKPaddingLG afterView:_smoothBtn];
    if (_linkBtn)
      [hs setCustomSpacing:KKPaddingLG afterView:_linkBtn];
    hs.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:hs];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      // Pushed to the right, hugging the trailing edge (like the radius
      // field) rather than sitting right after the label.
      [hs.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                        constant:-KKPaddingLG],
      [hs.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                      constant:KKPaddingMD],
      [hs.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    _fields = fs;
    _angleKnobs = knobs;
    _prevKnobValues = [NSMutableArray array];
    for (NSUInteger k = 0; k < knobs.count; k++)
      [_prevKnobValues addObject:@0];
  } else {
    _KKValueField *cell = [[_KKValueField alloc] init];
    [cell setSuffix:(_cunits.count ? _cunits[0] : nil)];
    NSTextField *fld = cell.field;
    fld.target = self;
    fld.action = @selector(_fieldCommitted:);
    fld.delegate = (id<NSTextFieldDelegate>)self;
    [self _configureScrubForField:fld component:0];
    _fields = @[ fld ];
    _slider = [KKSliderView styledSlider];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    _slider.minValue = _cmin.count ? _cmin[0].doubleValue : 0.0;
    _slider.maxValue = _cmax.count ? _cmax[0].doubleValue : 1.0;
    _slider.continuous = YES;
    _slider.trackFillColor = [NSColor accentMatchingHost];
    _slider.target = self;
    _slider.action = @selector(_sliderMoved:);
    __weak typeof(self) weak = self;
    _slider.onDragBegin = ^{
      if (weak.onDragBegin)
        weak.onDragBegin();
    };
    _slider.onDragEnd = ^{
      if (weak.onDragEnd)
        weak.onDragEnd();
    };
    [self addSubview:_slider];
    [self addSubview:cell];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_slider.leadingAnchor constraintEqualToAnchor:title.trailingAnchor
                                            constant:KKPaddingSM],
      [_slider.trailingAnchor constraintEqualToAnchor:cell.leadingAnchor
                                             constant:-KKPaddingSM],
      [_slider.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [cell.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                          constant:-KKPaddingLG],
      [cell.topAnchor constraintEqualToAnchor:self.topAnchor],
      [cell.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
  }

  [self applyLane:lane];
  return self;
}

// Gradient value layout: pure flat stops, or - for a composite type/angle lane
// - [type, angleDegrees, <flat stops>]. These split/join the parts.
- (NSArray<KKGradientStop *> *)_currentGradientStops {
  NSArray<NSNumber *> *flat = _values;
  if (_gradientWithTypeAngle)
    flat = _values.count > 2
               ? [_values subarrayWithRange:NSMakeRange(2, _values.count - 2)]
               : @[];
  return KKGradientStopsFromFlat(flat);
}

- (NSArray<NSNumber *> *)_composeGradientWithStops:
    (NSArray<KKGradientStop *> *)stops {
  NSArray<NSNumber *> *flat = KKGradientFlatFromStops(stops);
  if (!_gradientWithTypeAngle)
    return flat;
  double type = _values.count >= 1 ? _values[0].doubleValue : 0.0;
  double angle = _values.count >= 2 ? _values[1].doubleValue : 0.0;
  NSMutableArray<NSNumber *> *out = [@[ @(type), @(angle) ] mutableCopy];
  [out addObjectsFromArray:flat];
  return out;
}

- (void)_updateGradientAngleVisibility {
  NSInteger type = _values.count >= 1 ? llround(_values[0].doubleValue) : 0;
  _gradientAngleContainer.hidden = (type != 1); // angle only for Linear
}

- (void)_gradientAngleKnobMoved:(NSSlider *)sender {
  if (!_gradientAngleKnobDragging) {
    [sender.window makeFirstResponder:nil];
    _gradientAngleKnobDragging = YES;
    if (self.onDragBegin)
      self.onDragBegin();
  }
  NSMutableArray<NSNumber *> *v = [_values mutableCopy];
  if (v.count >= 2)
    v[1] = @(sender.doubleValue);
  [self _setValues:v emit:YES];
  if (NSApp.currentEvent.type == NSEventTypeLeftMouseUp) {
    _gradientAngleKnobDragging = NO;
    if (self.onDragEnd)
      self.onDragEnd();
  }
}

- (void)_gradientAngleFieldCommitted:(NSTextField *)sender {
  NSMutableArray<NSNumber *> *v = [_values mutableCopy];
  if (v.count >= 2)
    v[1] = @(sender.doubleValue);
  [self _setValues:v emit:YES];
}

// Per-component clamp; for Crop additionally keep the box inside the image
// (|x| ≤ (1-w)/2, |y| ≤ (1-h)/2) so typed values match the OSC, which
// never lets the crop rect exceed the image.
- (void)_constrain:(NSMutableArray<NSNumber *> *)v {
  for (NSInteger i = 0; i < (NSInteger)v.count; i++)
    v[i] = @([self _clamp:v[i].doubleValue index:i]);
  if (_valueType == KKLaneValueTypeCrop && v.count >= 4) {
    double w = v[0].doubleValue, h = v[1].doubleValue;
    double xb = (1.0 - w) / 2.0, yb = (1.0 - h) / 2.0;
    double x = v[2].doubleValue, y = v[3].doubleValue;
    v[2] = @(x < -xb ? -xb : (x > xb ? xb : x));
    v[3] = @(y < -yb ? -yb : (y > yb ? yb : y));
  }
}

// Render _values into the fields/slider (display = norm × scale). Skips a
// field the user is editing (or mid end-editing) so typing isn't clobbered and
// a stringValue write can't re-grab focus on the field that's resigning.
- (void)refreshDisplay {
  for (NSInteger i = 0;
       i < (NSInteger)_fields.count && i < (NSInteger)_values.count; i++) {
    if ([self _fieldEditing:_fields[i]])
      continue;
    _fields[i].stringValue = [self _displayForNorm:_values[i].doubleValue
                                             index:i];
  }
  if (_slider && _values.count && ![self _fieldEditing:_fields[0]])
    _slider.doubleValue = _values[0].doubleValue;
  if (_seedView && _values.count)
    _seedView.seed = (uint32_t)llround(_values[0].doubleValue);
  if (_choicePill && _values.count) {
    NSInteger sel = (NSInteger)llround(_values[0].doubleValue);
    for (NSInteger i = 0; i < (NSInteger)_choiceLabels.count; i++)
      [_choicePill setState:(i == sel) atIndex:i];
  }
  if (_colorWell && _values.count >= 3) {
    CGFloat a = _values.count >= 4 ? _values[3].doubleValue : 1.0;
    _colorWell.color = [NSColor colorWithSRGBRed:_values[0].doubleValue
                                           green:_values[1].doubleValue
                                            blue:_values[2].doubleValue
                                           alpha:a];
  }
  if (_gradientControl) {
    if (!_suppressGradientRefresh) {
      NSArray<KKGradientStop *> *stops = [self _currentGradientStops];
      if (stops)
        _gradientControl.stops = stops;
    }
    if (_gradientWithTypeAngle) {
      NSInteger type = _values.count >= 1 ? llround(_values[0].doubleValue) : 0;
      [_gradientTypePill setState:(type == 0) atIndex:0];
      [_gradientTypePill setState:(type == 1) atIndex:1];
      double angle = _values.count >= 2 ? _values[1].doubleValue : 0.0;
      if (!_gradientAngleKnobDragging)
        _gradientAngleKnob.doubleValue = angle;
      if (![self _fieldEditing:_gradientAngleField])
        _gradientAngleField.stringValue =
            [NSString stringWithFormat:@"%.0f", angle];
      [self _updateGradientAngleVisibility];
    }
  }
  if (_angleKnobs.count && !_angleKnobDragging) {
    for (NSInteger i = 0;
         i < (NSInteger)_angleKnobs.count && i < (NSInteger)_values.count;
         i++) {
      if (i < (NSInteger)_fields.count && [self _fieldEditing:_fields[i]])
        continue;
      // Knob wraps the value into its -180..180 range visually - the model
      // still stores the unwrapped degree. Keep _prevKnobValues in sync so
      // the next delta calc doesn't see a jump from external mutation.
      double v = _values[i].doubleValue;
      double wrapped = fmod(v + 180.0, 360.0);
      if (wrapped < 0)
        wrapped += 360.0;
      double knobPos = wrapped - 180.0;
      _angleKnobs[i].doubleValue = knobPos;
      if (i < (NSInteger)_prevKnobValues.count)
        _prevKnobValues[i] = @(knobPos);
    }
  }
}

- (BOOL)_fieldEditing:(NSTextField *)f {
  if (f.currentEditor)
    return YES;
  return [f isKindOfClass:[KKValueTextField class]] &&
         ((KKValueTextField *)f).kkEditing;
}

- (void)_setValues:(NSArray<NSNumber *> *)v emit:(BOOL)emit {
  _values = [v mutableCopy] ?: [NSMutableArray array];
  [self _constrain:_values];
  if (_integerValued)
    for (NSInteger i = 0; i < (NSInteger)_values.count; i++)
      _values[i] = @(round(_values[i].doubleValue));
  [self refreshDisplay];
  [self _updateResetVisibility];
  if (emit && self.onValue)
    self.onValue([_values copy]);
}

- (void)_sliderMoved:(id)sender {
  NSMutableArray *v = [_values mutableCopy];
  if (v.count)
    v[0] = @(_slider.doubleValue); // radius: scale 1
  [self _setValues:v emit:YES];
}

// NSSlider (unlike KKSliderView) has no built-in onDragBegin/End hooks - we
// detect drag start on the first continuous fire and drag end via the
// pressed-mouse-button state. Same drag-undo bracketing as _sliderMoved.
// Knob delta accumulation: NSSlider circular wraps at min/max, but we want
// the model to keep climbing (FCP behavior - 720° = two full turns). On
// each fire, compute the delta from the previous knob position, correct
// for the ±180 → ∓180 wrap, and add that to the model value. The knob's
// visible position re-syncs from the wrapped model in refreshDisplay.
- (void)_angleKnobMoved:(NSSlider *)sender {
  if (!_angleKnobDragging) {
    // Drop focus from any field still editing first - otherwise the field's
    // stale stringValue commits over the knob-driven value next runloop tick
    // (same bug class as the reset-to-default button before its fix).
    [sender.window makeFirstResponder:nil];
    _angleKnobDragging = YES;
    if (self.onDragBegin)
      self.onDragBegin();
  }
  NSInteger i = sender.tag;
  if (i < 0 || i >= (NSInteger)_values.count)
    return;
  double prev = (i < (NSInteger)_prevKnobValues.count)
                    ? _prevKnobValues[i].doubleValue
                    : sender.doubleValue;
  double delta = sender.doubleValue - prev;
  if (delta > 180.0)
    delta -= 360.0;
  else if (delta < -180.0)
    delta += 360.0;
  while (i >= (NSInteger)_prevKnobValues.count)
    [_prevKnobValues addObject:@0];
  _prevKnobValues[i] = @(sender.doubleValue);
  NSMutableArray<NSNumber *> *v = [_values mutableCopy];
  v[i] = @([v[i] doubleValue] + delta);
  [self _setValues:v emit:YES];
  NSEvent *evt = NSApp.currentEvent;
  if (evt.type == NSEventTypeLeftMouseUp) {
    _angleKnobDragging = NO;
    if (self.onDragEnd)
      self.onDragEnd();
  }
}

- (void)_fieldCommitted:(id)sender {
  NSMutableArray<NSNumber *> *v = [_values mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)_fields.count && i < (NSInteger)v.count;
       i++)
    v[i] = @(_fields[i].doubleValue / [self _scaleAt:i]);
  // Aspect link: scale the partner of the edited component by the same factor,
  // preserving the current X:Y ratio. _values still holds the pre-edit values.
  if (_linkOn && v.count == 2 && _values.count == 2) {
    NSInteger edited = [_fields indexOfObjectIdenticalTo:sender];
    if (edited == 0 || edited == 1) {
      NSInteger other = 1 - edited;
      double oldEdited = _values[edited].doubleValue;
      double newEdited = v[edited].doubleValue;
      double oldOther = _values[other].doubleValue;
      if (fabs(oldEdited) > 1e-9)
        v[other] = @(oldOther * (newEdited / oldEdited)); // preserve ratio
      else
        v[other] = @(newEdited); // ratio undefined from 0 - move together 1:1
    }
  }
  [self _setValues:v emit:YES];
  // _setValues clamps to componentMin/Max, but the field editor is still
  // tearing down this tick so refreshDisplay skipped the edited field - leaving
  // an out-of-range entry (e.g. "150") on screen. Re-render next tick, once the
  // editor is gone, so the field snaps to the clamped value.
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weak refreshDisplay];
  });
}

- (void)applyValues:(NSArray<NSNumber *> *)vals {
  [self _setValues:vals emit:NO];
}

// KKPopoverExtraRow hook (inherited via KKLaneRowView). External mutations
// (cmd-Z etc.) land here; refreshDisplay re-renders fields/slider from
// _values without clobbering an in-progress edit.
- (void)popoverDidRefresh {
  [super popoverDidRefresh];
  [self refreshDisplay];
}

- (void)applyLane:(KKLane *)lane {
  [self applyValues:lane.keyposes.firstObject.values];
}

- (NSView *)guideSliderView {
  return _slider ?: (NSView *)_angleKnobs.firstObject;
}

- (NSView *)guideFieldViewForComponent:(NSInteger)i {
  return (i >= 0 && i < (NSInteger)_fields.count) ? _fields[i] : nil;
}

- (void)guideCommitFieldForComponent:(NSInteger)i {
  if (i < 0 || i >= (NSInteger)_fields.count)
    return;
  // End editing → sendsActionOnEndEditing fires _fieldCommitted:.
  [_fields[i].window makeFirstResponder:nil];
}

// Return commits and fully defocuses. Returning YES suppresses AppKit's
// default Return handling, which otherwise re-selects all text and re-focuses
// the field *after* our textDidEndEditing handler - leaving it stuck "all
// selected" and impossible to clear via reset/OSC.
- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (KKValueFieldHandleReturnCommand(self.window, commandSelector))
    return YES;
  return KKValueFieldHandleTabCommand((NSTextField *)control, commandSelector);
}

// Live keystrokes in any field - report the parsed *display* value (the
// editor's current text, not the cell's committed value) so a guide can
// watch the user type toward a target.
- (void)controlTextDidChange:(NSNotification *)note {
  if (!_onGuideFieldEdit)
    return;
  NSInteger comp = [_fields indexOfObjectIdenticalTo:note.object];
  if (comp == NSNotFound)
    return;
  NSText *ed = note.userInfo[@"NSFieldEditor"];
  double disp = ed ? ed.string.doubleValue : [note.object doubleValue];
  _onGuideFieldEdit(comp, disp);
}

@end
