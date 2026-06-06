/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKMiniViewerView.h"
#import "KKPillToggleRowView.h"
#import "KKPopoverHeaderView.h"
#import "KKSliderView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTokens.h"
#import "KKValueTextField.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/QuartzCore.h>

const CGFloat kFloatRowH = 30.0;
static const CGFloat kCropRowH = 30.0; // single-line W/H/X/Y hstack
static const CGFloat kStaticFieldW = 40.0;

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
  BOOL _integerValued; // fields display + round to whole numbers
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

- (BOOL)isFlipped {
  return YES;
}

+ (CGFloat)heightForLane:(KKLane *)lane {
  return KKLaneComponentLabels(lane).count >= 2 ? kCropRowH : kFloatRowH;
}

// NSStackView sizes arranged rows by their intrinsic height; without this
// the rows collapse on top of each other (no height constraint otherwise).
- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric,
                    _fields.count >= 2 ? kCropRowH : kFloatRowH);
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

- (instancetype)initWithLane:(KKLane *)lane
                 showsRemove:(BOOL)showsRemove
          showsAddToAnimated:(BOOL)showsAddToAnimated
                 showsSmooth:(BOOL)showsSmooth {
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

  NSTextField *title = _KKMakeCaption(KKLocalizedParamName(lane.label));
  [self addSubview:title];

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
  if (caps.count >= 2) {
    NSInteger n = (NSInteger)caps.count;
    NSMutableArray<NSView *> *arranged = [NSMutableArray array];
    NSMutableArray<NSTextField *> *fs = [NSMutableArray array];
    NSMutableArray<NSSlider *> *knobs = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
      _KKValueField *cell = [[_KKValueField alloc] init];
      [cell setPrefix:caps[i]];
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
      [title.widthAnchor constraintEqualToConstant:54.0],
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
