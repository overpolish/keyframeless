/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCheckboxView.h"
#import "KKCodeEditorView.h"
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
static const CGFloat kCodeRowH =
    258.0; // multi-line code editor (title + ~9 lines)
static const CGFloat kStaticFieldW = 40.0;
static const CGFloat kWrapLineExtra =
    25.0; // +height per extra wrapped pill line
// Cap on the (uniform) label column so a long localized name (e.g. German
// "Geschwindigkeit") can't push the value controls off the popover's right
// edge. Longer names truncate with an ellipsis; the full name shows on hover.
static const CGFloat kMaxLabelColW = 140.0;

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
// When YES the prefix slot hugs its text (multi-word captions like "Start" /
// "End") instead of the fixed one-character slot. Default NO.
- (void)setPrefixAutoSizes:(BOOL)autoSizes;
@end

@implementation _KKValueField {
  NSTextField *_prefix;
  NSTextField *_suffix;
  NSLayoutConstraint *_prefixWidth;
  BOOL _prefixAutoSizes;
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
    (_prefixWidth =
         [_prefix.widthAnchor constraintEqualToConstant:kPrefixSlotW]),
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
  [self _updatePrefixWidth];
}
- (void)setPrefixAutoSizes:(BOOL)autoSizes {
  _prefixAutoSizes = autoSizes;
  [self _updatePrefixWidth];
}
- (void)_updatePrefixWidth {
  // Hug the caption text when auto-sizing (multi-word labels); else the fixed
  // one-character slot that keeps value columns aligned across rows. Measure
  // the string against its font directly - `fittingSize` would just echo the
  // active width constraint (the fixed slot) and never grow.
  if (!_prefixAutoSizes) {
    _prefixWidth.constant = kPrefixSlotW;
    return;
  }
  NSFont *font = _prefix.font
                     ?: [NSFont systemFontOfSize:KKFontSizeSM
                                          weight:NSFontWeightRegular];
  CGFloat textW =
      [_prefix.stringValue sizeWithAttributes:@{NSFontAttributeName : font}]
          .width;
  _prefixWidth.constant = MAX(kPrefixSlotW, ceil(textW) + 2.0);
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
  BOOL _clampsDisplayToMax;       // clamp field + thumb to _cmax (dynamic-max)
  BOOL _componentsScaleWithMedia; // display = norm x media px
                                  // (Position/Anchor/Crop)
  double _laneScrubStep;          // lane's explicit scrub increment (0 = auto)
  KKSeedView *_seedView; // seed control (value + re-roll), seedField lanes only
  BOOL _seedField;
  KKPillToggleRowView *_choicePill;   // grouped radio pill, choiceLabels only
  NSArray<NSString *> *_choiceLabels; // English identifiers (count >= 2)
  NSArray<NSImage *> *_choiceIcons;   // optional per-choice glyphs (display)
  BOOL _wrapsChoicePills;             // pill wraps to multiple lines
  NSLayoutConstraint *_pillWidthConstraint; // wrapping pill width (= wrapW)
  CGFloat _rowHeight;              // resolved height (wrapping pill rows)
  CGFloat _contentWidth;           // popover content width (for pill wrap)
  KKCheckboxView *_toggleCheckbox; // single on/off checkbox, isToggle only
  BOOL _isToggle;                  // value row is a single checkbox (0/1)
  BOOL _autoSizesComponentLabels;  // prefix captions hug text (Start/End)
  BOOL _oscEditedOnly; // geometry-style lane: message instead of value fields
  KKColorWellView *_colorWell; // swatch: Color (offset 0) or ColorPoint
  NSInteger
      _swatchOffset;     // first RGBA component index for _colorWell (0 for a
                         // plain Color lane; = #leading fields for ColorPoint)
  NSButton *_lockBtn;    // palette lock toggle, left of a lockable swatch
  BOOL _paletteLockable; // lane opted into the lock toggle
  BOOL _paletteLocked;   // current (transient) lock state
  BOOL _paletteGeneratorBar; // row is the 5 mode buttons, not a value editor
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
  BOOL _locked;          // locked layer: row is read-only (dimmed, no input)
}

// A locked lane's row shows its values but takes no input: swallow every mouse
// event (so no field/slider/well/pill responds) and dim to read as disabled.
- (NSView *)hitTest:(NSPoint)point {
  return _locked ? nil : [super hitTest:point];
}

- (BOOL)isCodeRow {
  return _valueType == KKLaneValueTypeCode;
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
  if (_oscEditedOnly || _valueType == KKLaneValueTypeCode) {
    _reset.hidden = YES; // geometry / code lane: nothing scalar to reset
    return;
  }
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

// Padlock toggle beside a lockable colour swatch. Closed/accent = locked (a
// palette reroll skips this colour), open/dim = unlocked. Borderless glyph
// styled like the row's other gutter toggles.
- (NSButton *)_makePaletteLockToggle {
  NSButton *b = [NSButton buttonWithImage:[[NSImage alloc] init]
                                   target:self
                                   action:@selector(_paletteLockTapped:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.toolTip =
      KKLoc(@"Lock this colour (kept when the palette regenerates)",
            @"Tooltip: per-colour lock toggle for the palette generator.");
  [NSLayoutConstraint activateConstraints:@[
    [b.widthAnchor constraintEqualToConstant:15.0],
    [b.heightAnchor constraintEqualToConstant:15.0],
  ]];
  return b;
}

- (void)_updatePaletteLockAppearance {
  NSImage *img = [NSImage
      imageWithSystemSymbolName:(_paletteLocked ? @"lock.fill" : @"lock.open")
       accessibilityDescription:nil];
  if (img)
    _lockBtn.image = img;
  _lockBtn.contentTintColor =
      _paletteLocked ? [NSColor accentMatchingHost]
                     : [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
}

- (void)_paletteLockTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  _paletteLocked = !_paletteLocked;
  [self _updatePaletteLockAppearance];
  if (self.onPaletteLockToggled)
    self.onPaletteLockToggled(_paletteLocked);
}

- (void)applyPaletteLock:(BOOL)locked {
  _paletteLocked = locked;
  [self _updatePaletteLockAppearance];
}

// One momentary palette-bar button (glyph, with a text fallback if the SF
// symbol is unavailable).
- (NSButton *)_makePaletteButtonSymbol:(NSString *)symbol
                                  name:(NSString *)englishName
                                   tag:(NSInteger)tag
                                action:(SEL)action {
  NSString *loc = KKLocalizedParamName(englishName);
  NSImage *img = [NSImage imageWithSystemSymbolName:symbol
                           accessibilityDescription:loc];
  NSButton *b = img ? [NSButton buttonWithImage:img target:self action:action]
                    : [NSButton buttonWithTitle:loc target:self action:action];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bezelStyle = NSBezelStyleRoundRect;
  b.controlSize = NSControlSizeSmall;
  b.imageScaling = NSImageScaleProportionallyDown;
  b.tag = tag;
  b.toolTip = loc;
  [b.heightAnchor constraintEqualToConstant:18.0].active = YES;
  return b;
}

// Tag = mode index; tapping rerolls in that mode.
- (NSButton *)_makePaletteModeButton:(NSInteger)mode
                              symbol:(NSString *)symbol
                                name:(NSString *)englishName {
  return [self _makePaletteButtonSymbol:symbol
                                   name:englishName
                                    tag:mode
                                 action:@selector(_paletteModeTapped:)];
}

- (void)_paletteModeTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  if (self.onPaletteGenerate)
    self.onPaletteGenerate([(NSButton *)sender tag]);
}

- (void)_paletteRefineTapped:(id)sender {
  [self.window makeFirstResponder:nil];
  if (self.onPaletteRefine)
    self.onPaletteRefine();
}

// A toggle row is one big click target (like KKCheckboxRowView): the inner
// KKCheckboxView's NSClickGestureRecognizer doesn't fire reliably inside FCP's
// ApplicationDefined popovers, so handle the click at the row level. Non-toggle
// rows fall through to AppKit so their fields/pills keep working.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return _isToggle ? YES : [super acceptsFirstMouse:event];
}

- (void)mouseDown:(NSEvent *)event {
  if (!_isToggle || _locked) {
    [super mouseDown:event];
    return;
  }
  BOOL newState = !(_values.count && llround(_values[0].doubleValue) != 0);
  _toggleCheckbox.isChecked = newState;
  [self _setValues:@[ @(newState ? 1.0 : 0.0) ] emit:YES];
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
  if (lane.valueType == KKLaneValueTypeCode)
    // A savable code lane adds the save bar (name + Save) below the editor;
    // grow the row so the code area keeps its full height.
    return kCodeRowH + (lane.codeSavable ? 34.0 : 0.0);
  return KKLaneComponentLabels(lane).count >= 2 ? kCropRowH : kFloatRowH;
}

// A choice-pill lane flagged `wrapsChoicePills` (the stroke marker types) wraps
// its pills to the row width and grows in height; everything else is one line.
static BOOL KKLaneWrapsChoicePills(KKLane *lane) {
  return lane.wrapsChoicePills && lane.choiceLabels.count >= 2;
}

// Width a wrapping pill block flows within (and right-aligns to): the row
// content width minus the label column, the reset slot and the paddings. MUST
// match the choice-branch constraint chain so the popover height calc agrees
// with the laid-out wrap.
+ (CGFloat)pillWrapWidthForContentWidth:(CGFloat)cw
                       labelColumnWidth:(CGFloat)lw {
  CGFloat labelCol = (lw > 0 ? lw : 54.0);
  // title-lead LG + labelCol + pill-gap MD + pill-to-reset LG + reset 15 +
  // reset-inset LG  ==  3*LG + MD + labelCol + 15.
  CGFloat w = cw - (3 * KKPaddingLG + KKPaddingMD + 15.0) - labelCol;
  return w > 60.0 ? w : 60.0;
}

// Width-aware height: a wrapping pill lane grows per wrapped line for the given
// content width; everything else is width-independent.
+ (CGFloat)heightForLane:(KKLane *)lane
            contentWidth:(CGFloat)contentWidth
        labelColumnWidth:(CGFloat)labelColumnWidth {
  if (!KKLaneWrapsChoicePills(lane))
    return [self heightForLane:lane];
  CGFloat wrapW = [self pillWrapWidthForContentWidth:contentWidth
                                    labelColumnWidth:labelColumnWidth];
  NSMutableArray<NSString *> *loc =
      [NSMutableArray arrayWithCapacity:lane.choiceLabels.count];
  for (NSString *c in lane.choiceLabels)
    [loc addObject:KKLocalizedParamName(c)];
  KKPillToggleRowView *probe =
      [[KKPillToggleRowView alloc] initWithLabels:loc icons:lane.choiceIcons];
  probe.grouped = YES;
  probe.wraps = YES;
  probe.preferredMaxLayoutWidth = wrapW;
  NSInteger lines = [probe lineCountForWidth:wrapW];
  return kFloatRowH + (lines - 1) * kWrapLineExtra; // 22pt pill + 3pt line gap
}

// NSStackView sizes arranged rows by their intrinsic height; without this
// the rows collapse on top of each other (no height constraint otherwise).
- (NSSize)intrinsicContentSize {
  if (_rowHeight > 0)
    return NSMakeSize(NSViewNoIntrinsicMetric, _rowHeight);
  CGFloat h = _gradientControl ? kGradientRowH
                               : (_fields.count >= 2 ? kCropRowH : kFloatRowH);
  return NSMakeSize(NSViewNoIntrinsicMetric, h);
}

// A popover resize (sm/md/lg) changes the content width without rebuilding
// rows, so the host calls this to re-derive a wrapping pill row's block width +
// height for the new width. No-op for a non-wrapping row.
- (void)updateContentWidth:(CGFloat)contentWidth {
  if (!_wrapsChoicePills || !_pillWidthConstraint || contentWidth <= 0)
    return;
  _contentWidth = contentWidth;
  CGFloat wrapW =
      [_KKStaticValueRow pillWrapWidthForContentWidth:contentWidth
                                     labelColumnWidth:_labelColumnW];
  _pillWidthConstraint.constant = wrapW;
  _choicePill.preferredMaxLayoutWidth = wrapW; // invalidates + redraws the pill
  CGFloat newH =
      kFloatRowH + ([_choicePill lineCountForWidth:wrapW] - 1) * kWrapLineExtra;
  if (fabs(newH - _rowHeight) > 0.5) {
    _rowHeight = newH;
    [self invalidateIntrinsicContentSize];
  }
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
              reservesGutter:(BOOL)reservesGutter
            labelColumnWidth:(CGFloat)labelColumnWidth
                contentWidth:(CGFloat)contentWidth {
  CGFloat cw = contentWidth > 0 ? contentWidth : kCanvasPopoverW;
  CGFloat h = [_KKStaticValueRow heightForLane:lane
                                  contentWidth:cw
                              labelColumnWidth:labelColumnWidth];
  self = [super initWithFrame:NSMakeRect(0, 0, cw, h)];
  if (!self)
    return nil;
  _rowHeight = h;
  _contentWidth = cw;
  _wrapsChoicePills = KKLaneWrapsChoicePills(lane);
  _laneLabel = [lane.label copy];
  _valueType = lane.valueType;
  _cmin = lane.componentMin ?: @[];
  _cmax = lane.componentMax ?: @[];
  _cunits = lane.componentUnits ?: @[];
  _integerValued = lane.integerValued;
  // A dynamic-max lane (its slider top tracks another lane) also clamps its
  // displayed value to that max - unlike normal lanes, whose field may exceed
  // the slider's end. Keeps the readout consistent with the reactive track.
  _clampsDisplayToMax = lane.maxControllerLabel.length > 0;
  _componentsScaleWithMedia = lane.componentsScaleWithMedia;
  _laneScrubStep = lane.scrubStep;
  _seedField = lane.seedField;
  _choiceLabels = [lane.choiceLabels copy];
  _choiceIcons = [lane.choiceIcons copy];
  _isToggle = lane.isToggle;
  _autoSizesComponentLabels = lane.autoSizesComponentLabels;
  _oscEditedOnly = lane.oscEditedOnly;
  _paletteLockable = lane.paletteLockable;
  _paletteGeneratorBar = lane.paletteGeneratorBar;
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
  } else if (reservesGutter) {
    // A constant (non-animatable) row in a popover whose animatable rows carry
    // a leading gutter button: reserve that button's column so this label + its
    // value control line up with the animatable rows instead of starting ~15pt
    // further left (matches the gutter geometry above: MD + 15 + SM).
    titleLeadInset = KKPaddingMD + 15.0 + KKPaddingSM;
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

  // OSC-edited-only lane (e.g. a path's points): no inline value editor. Keep
  // the standard row (title + the make-animatable / remove gutter button) but
  // show an "edit on canvas" message where the value fields would be.
  if (_oscEditedOnly) {
    _reset.hidden = YES; // no scalar value to reset for a geometry lane
    NSTextField *msg = _KKMakeCaption(KKLoc(
        @"Edit on canvas", @"OSC-only lane: edit via the on-screen control."));
    msg.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
    msg.alignment =
        NSTextAlignmentRight; // sits where the value fields would be
    msg.lineBreakMode = NSLineBreakByTruncatingTail;
    msg.usesSingleLineMode = YES;
    [self addSubview:msg];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [msg.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                      constant:KKPaddingSM],
      // Align where the value controls end (leave the reset-button slot) so
      // the message lines up with every other lane row.
      [msg.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                         constant:-KKPaddingLG],
      [msg.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    // This branch returns BEFORE the shared applyLane: below, so apply the
    // lock state here too - otherwise a freshly-built geometry row (e.g.
    // Points created on a multi-select refresh) never reads `locked` and its
    // gutter button stays clickable while every value row is read-only.
    _locked = lane.locked;
    self.alphaValue = _locked ? 0.5 : 1.0;
    return self;
  }

  // Code lane: a tall, full-width multi-line editor (no numeric value fields).
  // The text is the lane's `codeString`; edits fire onCodeChanged (debounced).
  if (_valueType == KKLaneValueTypeCode) {
    _reset.hidden = YES; // no scalar value to reset
    KKCodeEditorView *editor =
        [[KKCodeEditorView alloc] initWithFrame:NSZeroRect];
    editor.translatesAutoresizingMaskIntoConstraints = NO;
    editor.codeValidator =
        lane.codeValidator; // set before text so it validates
    editor.savable = lane.codeSavable;
    __weak typeof(self) weak = self;
    if (lane.codeTabs.count > 0 || lane.codeTabCatalog.count > 0) {
      // Tabbed: section 0 is Image (the lane's codeString), then any added
      // extra sections from codeTabs. `codeTabCatalog` feeds the "+" menu.
      // Edits + tab add/remove persist the whole section set.
      NSMutableArray<NSDictionary<NSString *, NSString *> *> *sections =
          [NSMutableArray array];
      [sections
          addObject:@{@"name" : @"Image", @"code" : lane.codeString ?: @""}];
      [sections addObjectsFromArray:lane.codeTabs ?: @[]];
      editor.addableTabNames = lane.codeTabCatalog;
      [editor setSections:sections];
      editor.onSectionsChange =
          ^(NSArray<NSDictionary<NSString *, NSString *> *> *secs) {
            __strong typeof(weak) s = weak;
            if (s.onCodeSectionsChanged)
              s.onCodeSectionsChanged(secs);
          };
    } else {
      editor.codeText = lane.codeString ?: @"";
      editor.onChange = ^(NSString *code) {
        __strong typeof(weak) s = weak;
        if (s.onCodeChanged)
          s.onCodeChanged(code);
      };
    }
    [self addSubview:editor];
    // Title sits top-left; the editor fills the row below it, edge to edge.
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.topAnchor constraintEqualToAnchor:self.topAnchor
                                      constant:KKPaddingSM],
      [editor.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                           constant:KKPaddingLG],
      [editor.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                            constant:-KKPaddingLG],
      [editor.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                       constant:KKPaddingSM],
      [editor.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                          constant:-KKPaddingSM],
    ]];
    _locked = lane.locked;
    self.alphaValue = _locked ? 0.5 : 1.0;
    return self;
  }

  NSArray<NSString *> *caps = KKLaneComponentLabels(lane);
  NSArray<NSColor *> *capColors = lane.componentLabelColors;
  if (_paletteGeneratorBar) {
    // Not a value editor: a row of momentary mode buttons that reroll the
    // palette. Each tap fires onPaletteGenerate(mode); the host regenerates the
    // visible colour lanes (keeping locked swatches).
    _reset.hidden = YES;
    NSArray<NSString *> *syms =
        @[ @"sun.max", @"cloud", @"circle.lefthalf.filled", @"dice" ];
    NSArray<NSString *> *names = @[ @"Bright", @"Dull", @"Shades", @"Chaotic" ];
    NSMutableArray<NSView *> *btns = [NSMutableArray array];
    for (NSInteger m = 0; m < (NSInteger)names.count; m++)
      [btns addObject:[self _makePaletteModeButton:m
                                            symbol:syms[m]
                                              name:names[m]]];
    // "Vary" button: nudges the current palette instead of rerolling.
    NSButton *vary =
        [self _makePaletteButtonSymbol:@"wand.and.stars"
                                  name:@"Vary"
                                   tag:0
                                action:@selector(_paletteRefineTapped:)];
    [btns addObject:vary];
    NSStackView *hs = [NSStackView stackViewWithViews:btns];
    hs.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hs.alignment = NSLayoutAttributeCenterY;
    hs.distribution = NSStackViewDistributionFillEqually;
    hs.spacing = KKPaddingSM;
    hs.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:hs];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [hs.leadingAnchor constraintEqualToAnchor:title.trailingAnchor
                                       constant:KKPaddingMD],
      [hs.trailingAnchor constraintEqualToAnchor:_reset.trailingAnchor],
      [hs.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
  } else if (_isToggle) {
    // A structural on/off: a single right-aligned checkbox (the shared
    // KKCheckboxView, same glyph as the global-settings / motion-blur rows -
    // not a raw AppKit checkbox). The lane's single value is 0 (off) or 1 (on);
    // refreshDisplay re-syncs isChecked, the shared applyLane tail below sets
    // the initial value + lock state.
    _toggleCheckbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
    _toggleCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    _toggleCheckbox.onToggle = ^(BOOL isOn) {
      [weakSelf _setValues:@[ @(isOn ? 1.0 : 0.0) ] emit:YES];
    };
    [self addSubview:_toggleCheckbox];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_toggleCheckbox.trailingAnchor
          constraintEqualToAnchor:_reset.leadingAnchor
                         constant:-KKPaddingLG],
      [_toggleCheckbox.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                      constant:KKPaddingMD],
      [_toggleCheckbox.centerYAnchor
          constraintEqualToAnchor:self.centerYAnchor],
      [_toggleCheckbox.widthAnchor constraintEqualToConstant:12.0],
      [_toggleCheckbox.heightAnchor constraintEqualToConstant:12.0],
    ]];
    _reset.hidden = YES; // a toggle resets via the checkbox itself
  } else if (_choiceLabels.count >= 2) {
    // A structural enum (e.g. a colour mode): a grouped radio pill, one segment
    // per choice, instead of a number field. The lane's single value is the
    // selected index. Labels localize at display time like any param name.
    NSMutableArray<NSString *> *locLabels =
        [NSMutableArray arrayWithCapacity:_choiceLabels.count];
    for (NSString *c in _choiceLabels)
      [locLabels addObject:KKLocalizedParamName(c)];
    // Glyph enum (e.g. Line Cap / Join): show the per-choice icons, with the
    // localized labels kept as accessibility/tooltip names. Falls back to a
    // text pill when no icons are supplied.
    if (_choiceIcons.count == _choiceLabels.count)
      _choicePill = [[KKPillToggleRowView alloc] initWithLabels:locLabels
                                                          icons:_choiceIcons];
    else
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
      [_choicePill.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    if (_wrapsChoicePills) {
      // Wide glyph set (stroke markers): a fixed-width block = wrapW, anchored
      // at the right (trailing at reset), whose pills wrap onto right-aligned
      // lines. -updateContentWidth: re-derives wrapW + the row height on a
      // popover resize. Otherwise the pill stays content-sized, right-aligned,
      // one line.
      CGFloat wrapW =
          [_KKStaticValueRow pillWrapWidthForContentWidth:_contentWidth
                                         labelColumnWidth:_labelColumnW];
      _choicePill.wraps = YES;
      _choicePill.preferredMaxLayoutWidth = wrapW;
      _pillWidthConstraint =
          [_choicePill.widthAnchor constraintEqualToConstant:wrapW];
      _pillWidthConstraint.active = YES;
    } else {
      [_choicePill.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                      constant:KKPaddingMD]
          .active = YES;
    }
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
    NSMutableArray<NSLayoutConstraint *> *cc = [NSMutableArray arrayWithArray:@[
      [title.leadingAnchor constraintEqualToAnchor:titleLead
                                          constant:titleLeadInset],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_colorWell.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                                constant:-KKPaddingLG],
      [_colorWell.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_colorWell.widthAnchor constraintEqualToConstant:28.0],
      [_colorWell.heightAnchor constraintEqualToConstant:16.0],
    ]];
    if (_paletteLockable) {
      // Padlock just left of the swatch: pins this colour so a palette reroll
      // leaves it untouched. State is transient (the host popover tracks it).
      _lockBtn = [self _makePaletteLockToggle];
      [self _updatePaletteLockAppearance];
      [self addSubview:_lockBtn];
      [cc addObjectsFromArray:@[
        [_lockBtn.trailingAnchor
            constraintEqualToAnchor:_colorWell.leadingAnchor
                           constant:-KKPaddingSM],
        [_lockBtn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_lockBtn.leadingAnchor
            constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                        constant:KKPaddingMD],
      ]];
    } else {
      [cc addObject:[_colorWell.leadingAnchor
                        constraintGreaterThanOrEqualToAnchor:title
                                                                 .trailingAnchor
                                                    constant:KKPaddingMD]];
    }
    [NSLayoutConstraint activateConstraints:cc];
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
      [cell setPrefixAutoSizes:_autoSizesComponentLabels];
      NSString *prefix = caps[i].length ? KKLocalizedParamName(caps[i]) : nil;
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
    // ColorPoint: a trailing RGBA swatch after the numeric fields. The leading
    // fields cover components [0..n-1]; the swatch edits [n..n+3].
    if (_valueType == KKLaneValueTypeColorPoint) {
      _swatchOffset = n;
      NSView *div = [[NSView alloc] init];
      div.translatesAutoresizingMaskIntoConstraints = NO;
      div.wantsLayer = YES;
      div.layer.backgroundColor =
          [[NSColor inspectorLabel] colorWithAlphaComponent:0.25].CGColor;
      [div.widthAnchor constraintEqualToConstant:1.0].active = YES;
      [div.heightAnchor constraintEqualToConstant:16.0].active = YES;
      [arranged addObject:div];

      _colorWell = [[KKColorWellView alloc] initWithFrame:NSZeroRect];
      _colorWell.translatesAutoresizingMaskIntoConstraints = NO;
      [_colorWell.widthAnchor constraintEqualToConstant:28.0].active = YES;
      [_colorWell.heightAnchor constraintEqualToConstant:16.0].active = YES;
      __weak typeof(self) weakCP = self;
      _colorWell.onColorChanged = ^(NSColor *c) {
        __strong typeof(weakCP) ss = weakCP;
        if (!ss)
          return;
        NSColor *sc =
            [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: c;
        CGFloat r = 0, g = 0, b = 0, a = 1;
        [sc getRed:&r green:&g blue:&b alpha:&a];
        NSMutableArray<NSNumber *> *v = [ss->_values mutableCopy];
        NSInteger o = ss->_swatchOffset;
        while ((NSInteger)v.count < o + 4)
          [v addObject:@0];
        v[o] = @(r);
        v[o + 1] = @(g);
        v[o + 2] = @(b);
        v[o + 3] = @(a);
        [ss _setValues:v emit:YES];
      };
      _colorWell.onColorEditingChanged = ^(BOOL editing) {
        __strong typeof(weakCP) ss = weakCP;
        if (ss.onColorEditing)
          ss.onColorEditing(editing);
      };
      [arranged addObject:_colorWell];
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
    // The slider can stop short of the field's hard min/max (componentMin/Max)
    // so a value is typeable past the slider's ends (marker width: slider
    // 0..500 %; draw-on Offset: slider 0..100 %, field unbounded to spin
    // round).
    _slider.minValue = lane.sliderMin
                           ? lane.sliderMin.doubleValue
                           : (_cmin.count ? _cmin[0].doubleValue : 0.0);
    _slider.maxValue = lane.sliderMax
                           ? lane.sliderMax.doubleValue
                           : (_cmax.count ? _cmax[0].doubleValue : 1.0);
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

  [self applyLane:lane]; // also sets _locked + dims when the lane is locked
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
  double dispMax =
      (_clampsDisplayToMax && _cmax.count) ? _cmax[0].doubleValue : INFINITY;
  for (NSInteger i = 0;
       i < (NSInteger)_fields.count && i < (NSInteger)_values.count; i++) {
    if ([self _fieldEditing:_fields[i]])
      continue;
    double v = _values[i].doubleValue;
    if (v > dispMax)
      v = dispMax;
    _fields[i].stringValue = [self _displayForNorm:v index:i];
  }
  if (_slider && _values.count && ![self _fieldEditing:_fields[0]]) {
    double v = _values[0].doubleValue;
    _slider.doubleValue = v > dispMax ? dispMax : v;
  }
  if (_seedView && _values.count)
    _seedView.seed = (uint32_t)llround(_values[0].doubleValue);
  if (_choicePill && _values.count) {
    NSInteger sel = (NSInteger)llround(_values[0].doubleValue);
    for (NSInteger i = 0; i < (NSInteger)_choiceLabels.count; i++)
      [_choicePill setState:(i == sel) atIndex:i];
  }
  if (_toggleCheckbox && _values.count)
    _toggleCheckbox.isChecked = llround(_values[0].doubleValue) != 0;
  if (_colorWell && (NSInteger)_values.count >= _swatchOffset + 3) {
    NSInteger o = _swatchOffset;
    CGFloat a =
        (NSInteger)_values.count >= o + 4 ? _values[o + 3].doubleValue : 1.0;
    _colorWell.color = [NSColor colorWithSRGBRed:_values[o].doubleValue
                                           green:_values[o + 1].doubleValue
                                            blue:_values[o + 2].doubleValue
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
  // Locked lane = read-only: dim + swallow input (handled in hitTest:). Set
  // here (not just init) so a row reused across an updateUnoptedLanes / rebuild
  // also reflects the current lock state.
  _locked = lane.locked;
  self.alphaValue = _locked ? 0.5 : 1.0;
}

- (void)applySliderMax:(double)maxValue {
  if (!_slider || (_cmax.count && _cmax[0].doubleValue == maxValue))
    return;
  _cmax = @[ @(maxValue) ];
  _slider.maxValue = maxValue;
  // Re-clamp the field + thumb to the new range (stored _values is preserved,
  // so a wider Type later restores the original count).
  [self refreshDisplay];
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

- (NSRect)guideChoicePillScreenRectForIndex:(NSInteger)index {
  return _choicePill ? [_choicePill guidePillScreenRectAtIndex:index]
                     : NSZeroRect;
}

- (NSRect)guideAddToAnimatedButtonScreenRect {
  NSWindow *w = _addBtn.window;
  if (!_addBtn || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[_addBtn convertRect:_addBtn.bounds
                                              toView:nil]];
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
