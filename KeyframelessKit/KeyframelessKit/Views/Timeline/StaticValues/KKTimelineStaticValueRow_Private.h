/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared internals for _KKStaticValueRow and its category splits (+Choice /
// +Gradient / +Toggles / ...). The ivars are @package so the categories - which
// cannot see the primary class's backing store - reach the same state the main
// .m builds. The primary @interface lives in KKTimelineLanesView_Private.h.

#import "KKTimelineLanesView_Private.h"
#import "KKTimeline.h" // KKLaneValueType

@class KKCheckboxView;
@class KKChoiceChecklistView;
@class KKCodeEditorView;
@class KKColorWellView;
@class KKGradientControl;
@class KKGradientStop;
@class KKPillToggleRowView;
@class KKSeedView;
@class KKSliderView;
@class _KKDropdownTrigger;

// Row-building helpers defined in the main .m, shared with the category splits.
FOUNDATION_EXPORT NSTextField *_KKMakeCaption(NSString *s);
FOUNDATION_EXPORT NSAttributedString *_KKWarningCaption(NSString *text,
                                                        NSColor *tint);
FOUNDATION_EXPORT const CGFloat kChoiceListMaxBody;

@interface _KKStaticValueRow () <NSPopoverDelegate> {
@package
  KKLaneValueType _valueType;
  NSArray<NSNumber *> *_cmin;
  NSArray<NSNumber *> *_cmax;
  NSArray<NSString *> *_cunits;
  NSArray<NSString *>
      *_clabels;         // per-component captions (built once, line ~874)
  KKSliderView *_slider; // Float only
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
  NSString
      *_linkExpression; // param-link transform expression (nil = plain lane)
  BOOL _integerValued;  // fields display + round to whole numbers
  BOOL _clampsDisplayToMax;       // clamp field + thumb to _cmax (dynamic-max)
  BOOL _componentsScaleWithMedia; // display = norm x media px
                                  // (Position/Anchor/Crop)
  double _laneScrubStep;          // lane's explicit scrub increment (0 = auto)
  KKSeedView *_seedView; // seed control (value + re-roll), seedField lanes only
  BOOL _seedField;
  NSTextField *_titleField; // the lane-name caption; refreshed by applyLane:
  KKCodeEditorView *_codeEditor;    // code lanes only; re-synced by applyLane:
  KKPillToggleRowView *_choicePill; // grouped radio pill, choiceLabels only
  NSArray<NSString *> *_choiceLabels; // English identifiers (pills need >= 2)
  NSArray<NSNumber *> *_choiceValues; // stored value per choice (nil = index)
  NSArray<NSImage *> *_choiceIcons;   // optional per-choice glyphs (display)
  BOOL _wrapsChoicePills;             // pill wraps to multiple lines
  NSLayoutConstraint *_pillWidthConstraint; // wrapping pill width (= wrapW)
  BOOL _choiceUsesDropdown; // choice row is a dropdown, not pills
  // What a stored value that names no current choice should read as, and the
  // warning beside it. See KKLane.choiceUnknownLabels.
  NSDictionary<NSNumber *, NSString *> *_choiceUnknownLabels;
  NSString *_choiceUnknownBadge;
  NSTextField *_choiceWarning;
  _KKDropdownTrigger *_choiceField;   // the Animated dropdown's trigger
  KKChoiceChecklistView *_choiceList; // the popover's list; nil when shut
  NSPopover *_choicePopover;          // nil when shut
  CGFloat _rowHeight;                 // resolved height (wrapping pill rows)
  CGFloat _contentWidth;              // popover content width (for pill wrap)
  KKCheckboxView *_toggleCheckbox;    // single on/off checkbox, isToggle only
  BOOL _isToggle;                     // value row is a single checkbox (0/1)
  BOOL _autoSizesComponentLabels;     // prefix captions hug text (Start/End)
  BOOL _oscEditedOnly; // geometry-style lane: message instead of value fields
  KKColorWellView *_colorWell; // swatch: Color (offset 0) or ColorPoint
  NSInteger
      _swatchOffset;     // first RGBA component index for _colorWell (0 for a
                         // plain Color lane; = #leading fields for ColorPoint)
  NSButton *_lockBtn;    // palette lock toggle, left of a lockable swatch
  BOOL _paletteLockable; // lane opted into the lock toggle
  BOOL _paletteLocked;   // current (transient) lock state
  BOOL _paletteGeneratorBar; // row is the 5 mode buttons, not a value editor
  BOOL _positionPathDriven;  // position-OSC lane: no link-expression affordance
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
  NSLayoutConstraint *_titleWidthConstraint; // the label column, restretchable
  BOOL _locked;          // locked layer: row is read-only (dimmed, no input)
}
@end

// Private methods shared across the category splits (called from the main .m or
// another category).
@interface _KKStaticValueRow (Private)
// +Gradient - the value pipeline reads/composes stops + toggles the angle row;
// the knob/field actions are target-action-wired from the main .m's
// initWithLane.
- (NSArray<KKGradientStop *> *)_currentGradientStops;
- (NSArray<NSNumber *> *)_composeGradientWithStops:
    (NSArray<KKGradientStop *> *)stops;
- (void)_updateGradientAngleVisibility;
- (void)_gradientAngleKnobMoved:(NSSlider *)sender;
- (void)_gradientAngleFieldCommitted:(NSTextField *)sender;
// Core (main .m) - write the normalized values (+ optionally emit onChange).
- (void)_setValues:(NSArray<NSNumber *> *)v emit:(BOOL)emit;
// +Choice - dropdown index<->stored value + title/list, driven from
// initWithLane.
- (double)_storedForChoiceIndex:(NSInteger)index;
- (NSInteger)_selectedChoiceIndex;
- (void)_syncChoiceFieldTitle;
- (void)_toggleChoiceList;
// +Toggles - smooth/link/palette-lock + palette-mode buttons, built + tinted
// from initWithLane.
- (NSButton *)_makeSmoothToggle;
- (void)_updateSmoothTint;
- (NSButton *)_makeLinkToggle;
- (void)_updateLinkTint;
- (NSButton *)_makePaletteLockToggle;
- (void)_updatePaletteLockAppearance;
- (NSButton *)_makePaletteButtonSymbol:(NSString *)symbol
                                  name:(NSString *)englishName
                                   tag:(NSInteger)tag
                                action:(SEL)action;
- (NSButton *)_makePaletteModeButton:(NSInteger)mode
                              symbol:(NSString *)symbol
                                name:(NSString *)englishName;
@end
