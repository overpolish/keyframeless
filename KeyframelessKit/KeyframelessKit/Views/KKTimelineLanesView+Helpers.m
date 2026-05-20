/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKMiniCanvasView.h"
#import "KKSliderView.h"
#import "KKTimelineLanesView_Private.h"
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/QuartzCore.h>

/// Hosts the mini canvas as its documentView so magnify/scroll events flow
/// (the arrangement the old working KKStageSequencerView used). Blocks
/// at-boundary overscroll from reaching FCP's inspector root scroll view.
@interface _KKMiniCanvasScrollView : NSScrollView
@end

@implementation _KKMiniCanvasScrollView
- (NSResponder *)_recursiveResponderThatWantsForwardedScrollEventsForAxis:
                     (NSEventGestureAxis)axis
                                                         intendedForSwipe:
                                                             (BOOL)forSwipe {
  return nil;
}
@end

// macOS 26 wraps popover content in a GlassView that injects a CoreHostingView
// (glass chrome) and ContentHolderView (opaque bg fill). Walk up to
// NSPopoverFrame and zero out both so liquid glass shows through unobstructed.
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

@implementation _KKLVPopoverContentView
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window)
    _clearPopoverBackground(self);
}
@end

@implementation _KKSearchFieldCell
- (NSRect)searchTextRectForBounds:(NSRect)bounds {
  NSRect r = [super searchTextRectForBounds:bounds];
  r.origin.x += 4.0;
  r.size.width -= 4.0;
  return r;
}
@end

@implementation _KKSearchField
+ (Class)cellClass {
  return [_KKSearchFieldCell class];
}

- (void)drawRect:(NSRect)dirty {
  NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                     xRadius:5.0
                                                     yRadius:5.0];
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
  [bg fill];
  [self.cell drawInteriorWithFrame:self.bounds inView:self];
}

- (BOOL)becomeFirstResponder {
  BOOL r = [super becomeFirstResponder];
  if (r) {
    NSTextView *ed = (NSTextView *)[self currentEditor];
    if ([ed isKindOfClass:[NSTextView class]]) {
      ed.insertionPointColor = [NSColor accentMatchingHost];
      ed.selectedTextAttributes = @{
        NSBackgroundColorAttributeName :
            [[NSColor accentMatchingHost] colorWithAlphaComponent:0.2],
        NSForegroundColorAttributeName : [NSColor inspectorLabel],
      };
    }
  }
  return r;
}
@end

@implementation _KKManageRow

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
  return YES;
}

- (void)setChecked:(BOOL)checked {
  _checked = checked;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
  // Square checkbox — Bezier path approach (coordinate-system independent
  // shape).
  CGFloat checkX = KKPaddingLG;
  CGFloat checkY = round(NSMidY(self.bounds) - kCheckSize / 2.0);
  NSRect boxRect = NSMakeRect(checkX, checkY, kCheckSize, kCheckSize);

  if (_checked) {
    NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:boxRect
                                                         xRadius:kCheckRadius
                                                         yRadius:kCheckRadius];
    [[NSColor accentMatchingHost] setFill];
    [fill fill];
    NSRect innerRect = NSInsetRect(boxRect, 0.25, 0.25);
    NSBezierPath *innerStroke =
        [NSBezierPath bezierPathWithRoundedRect:innerRect
                                        xRadius:kCheckRadius - 0.25
                                        yRadius:kCheckRadius - 0.25];
    [[NSColor colorWithWhite:1.0 alpha:0.15] setStroke];
    innerStroke.lineWidth = 0.25;
    [innerStroke stroke];
    // Checkmark path — y-values are flipped relative to KKCheckboxView
    // (isFlipped=YES here).
    NSBezierPath *mark = [NSBezierPath bezierPath];
    mark.lineWidth = 1.5;
    mark.lineCapStyle = NSLineCapStyleRound;
    mark.lineJoinStyle = NSLineJoinStyleBevel;
    [mark moveToPoint:NSMakePoint(checkX + 3.2, checkY + kCheckSize - 5.4)];
    [mark lineToPoint:NSMakePoint(checkX + 5.2, checkY + kCheckSize - 3.6)];
    [mark lineToPoint:NSMakePoint(checkX + 8.8, checkY + kCheckSize - 8.5)];
    [[NSColor colorWithRed:0x17 / 255.0
                     green:0x17 / 255.0
                      blue:0x17 / 255.0
                     alpha:1.0] setStroke];
    [mark stroke];
  } else {
    NSBezierPath *border =
        [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(boxRect, 0.5, 0.5)
                                        xRadius:kCheckRadius
                                        yRadius:kCheckRadius];
    [[[NSColor inspectorLabel] colorWithAlphaComponent:0.3] setStroke];
    border.lineWidth = 1.0;
    [border stroke];
  }

  NSColor *textColor =
      _checked ? [NSColor inspectorLabel]
               : [[NSColor inspectorLabel] colorWithAlphaComponent:0.6];
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : textColor,
  };
  NSSize textSz = [_rowLabel sizeWithAttributes:attrs];
  [_rowLabel drawAtPoint:NSMakePoint(KKPaddingLG + kCheckSize + 6.0,
                                     NSMidY(self.bounds) - textSz.height / 2.0)
          withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)e {
  if (_onToggle)
    _onToggle();
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kRowHeight);
}

@end

@implementation _KKManagePopoverView {
  NSSet<NSString *> *_checkedLabels;
  _KKSearchField *_searchField;
  NSMutableArray<_KKManageRow *> *_allRows;
  NSStackView *_rowStack;
}

+ (CGFloat)heightForLaneCount:(NSInteger)count {
  return KKPaddingMD + kSearchH + KKPaddingMD + count * kRowHeight +
         KKPaddingMD;
}

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                checkedLabels:(NSSet<NSString *> *)checked
                     onToggle:(void (^)(NSString *))onToggle {
  CGFloat h = [_KKManagePopoverView heightForLaneCount:lanes.count];
  self = [super initWithFrame:NSMakeRect(0, 0, kPopoverW, h)];
  if (!self)
    return nil;
  _checkedLabels = [checked copy];
  _allRows = [NSMutableArray array];

  _searchField = [[_KKSearchField alloc] init];
  _searchField.translatesAutoresizingMaskIntoConstraints = NO;
  _searchField.placeholderString = @"Search";
  _searchField.delegate = self;
  _searchField.font = [NSFont systemFontOfSize:KKFontSizeSM
                                        weight:NSFontWeightRegular];
  _searchField.focusRingType = NSFocusRingTypeNone;
  [self addSubview:_searchField];

  _rowStack = [NSStackView stackViewWithViews:@[]];
  _rowStack.translatesAutoresizingMaskIntoConstraints = NO;
  _rowStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _rowStack.spacing = 0;
  _rowStack.detachesHiddenViews = YES;
  [self addSubview:_rowStack];

  [NSLayoutConstraint activateConstraints:@[
    [_searchField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                               constant:KKPaddingMD],
    [_searchField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                constant:-KKPaddingMD],
    [_searchField.topAnchor constraintEqualToAnchor:self.topAnchor
                                           constant:KKPaddingMD],
    [_searchField.heightAnchor constraintEqualToConstant:kSearchH],

    [_rowStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_rowStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_rowStack.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor
                                        constant:KKSpacingSM],
  ]];

  for (KKLane *lane in lanes) {
    _KKManageRow *row = [[_KKManageRow alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.rowLabel = lane.label;
    row.checked = [checked containsObject:lane.label];
    NSString *label = lane.label;
    row.onToggle = ^{
      if (onToggle)
        onToggle(label);
    };
    [_rowStack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_rowStack.widthAnchor].active =
        YES;
    [_allRows addObject:row];
  }
  return self;
}

- (void)updateCheckedLabels:(NSSet<NSString *> *)checked {
  _checkedLabels = [checked copy];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  for (_KKManageRow *row in _allRows) {
    row.checked = [_checkedLabels containsObject:row.rowLabel];
    [row display];
  }
  [CATransaction commit];
  [CATransaction flush];
}

- (nullable NSView *)rowViewForLabel:(NSString *)label {
  for (_KKManageRow *row in _allRows)
    if ([row.rowLabel isEqualToString:label])
      return row;
  return nil;
}

- (void)controlTextDidChange:(NSNotification *)note {
  NSString *query = _searchField.stringValue;
  for (_KKManageRow *row in _allRows) {
    row.hidden =
        query.length > 0 && [row.rowLabel rangeOfString:query
                                                options:NSCaseInsensitiveSearch]
                                    .location == NSNotFound;
  }
}

@end

static const CGFloat kFloatRowH = 30.0;
static const CGFloat kCropRowH = 30.0; // single-line W/H/X/Y hstack
static const CGFloat kStaticFieldW = 40.0;

// Mirrors KKSeedView's field: only takes focus on an explicit click (so the
// popover doesn't steal keyboard shortcuts), accent caret/selection, and
// hands focus back to the window when editing ends.
@interface _KKStaticNumberField : NSTextField
@end

@implementation _KKStaticNumberField {
  BOOL _userClickPending;
}
- (BOOL)acceptsFirstResponder {
  return _userClickPending;
}
- (void)mouseDown:(NSEvent *)event {
  _userClickPending = YES;
  [super mouseDown:event];
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (self.currentEditor) {
    [self.currentEditor keyDown:event];
    return YES;
  }
  return [super performKeyEquivalent:event];
}
- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    [self _styleFieldEditor];
    // The field editor may not be installed yet on this runloop tick;
    // re-apply next tick so the accent caret/selection actually takes.
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weak _styleFieldEditor];
    });
  }
  return ok;
}
- (void)_styleFieldEditor {
  NSText *ed = self.currentEditor;
  if (![ed isKindOfClass:[NSTextView class]])
    return;
  NSTextView *editor = (NSTextView *)ed;
  NSColor *accent = [NSColor accentMatchingHost];
  editor.insertionPointColor = accent;
  editor.selectedTextAttributes = @{
    NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
    NSForegroundColorAttributeName : [NSColor labelColor],
  };
}
- (void)textDidEndEditing:(NSNotification *)notification {
  [super textDidEndEditing:notification];
  _userClickPending = NO;
  [self.window makeFirstResponder:nil];
}
@end

static NSTextField *_KKMakeNumberField(void) {
  _KKStaticNumberField *f = [[_KKStaticNumberField alloc] init];
  f.translatesAutoresizingMaskIntoConstraints = NO;
  f.font = [NSFont monospacedDigitSystemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular];
  f.alignment = NSTextAlignmentRight;
  f.textColor = [NSColor inspectorLabel];
  f.backgroundColor = [NSColor clearColor];
  f.bordered = NO;
  f.bezeled = NO;
  f.drawsBackground = NO;
  f.focusRingType = NSFocusRingTypeNone;
  f.editable = YES;
  f.selectable = YES;
  // Fire the action on Return *and* on focus loss, so a typed value commits
  // without a drag (the host applies it immediately — see coalescing).
  [f.cell setSendsActionOnEndEditing:YES];
  return f;
}

static NSTextField *_KKMakeCaption(NSString *s) {
  NSTextField *l = [NSTextField labelWithString:s];
  l.translatesAutoresizingMaskIntoConstraints = NO;
  l.font = [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightRegular];
  l.textColor = [NSColor inspectorLabel];
  return l;
}

@implementation _KKStaticValueRow {
  KKLaneValueType _valueType;
  NSArray<NSNumber *> *_cmin;
  NSArray<NSNumber *> *_cmax;
  KKSliderView *_slider;               // Float only
  NSArray<NSTextField *> *_fields;     // Float: 1; Crop: 4 (w,h,x,y)
  NSMutableArray<NSNumber *> *_values; // normalized, authoritative
  NSButton *_reset;                    // reset-to-default, right of the label
  NSArray<NSNumber *> *_defaultValues;
}

- (void)setDefaultValues:(NSArray<NSNumber *> *)defaultValues {
  _defaultValues = [defaultValues copy];
  [self _updateResetVisibility];
}

- (NSArray<NSNumber *> *)defaultValues {
  return _defaultValues;
}

// Reset is only meaningful when a default exists AND the current value
// differs from it — hidden otherwise so a row at default has no clutter.
- (void)_updateResetVisibility {
  BOOL atDefault =
      _defaultValues.count > 0 && _values.count == _defaultValues.count;
  for (NSInteger i = 0; atDefault && i < (NSInteger)_values.count; i++)
    if (fabs(_values[i].doubleValue - _defaultValues[i].doubleValue) > 1e-6)
      atDefault = NO;
  _reset.hidden = (_defaultValues.count == 0) || atDefault;
}

- (void)_resetTapped:(id)sender {
  if (_defaultValues.count)
    [self _setValues:_defaultValues emit:YES]; // commits like a field edit
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
  return lane.valueType == KKLaneValueTypeCrop ? kCropRowH : kFloatRowH;
}

// NSStackView sizes arranged rows by their intrinsic height; without this
// the rows collapse on top of each other (no height constraint otherwise).
- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric,
                    _valueType == KKLaneValueTypeCrop ? kCropRowH : kFloatRowH);
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
  BOOL intFmt = (scale != 1.0);
  double dv = norm * scale;
  // Round to the displayed precision first, then squash -0 → 0 so a tiny
  // negative never shows as "-0".
  dv = intFmt ? round(dv) : round(dv * 100.0) / 100.0;
  if (dv == 0.0)
    dv = 0.0;
  return [NSString stringWithFormat:(intFmt ? @"%.0f" : @"%.2f"), dv];
}

- (instancetype)initWithLane:(KKLane *)lane {
  CGFloat h = [_KKStaticValueRow heightForLane:lane];
  self = [super initWithFrame:NSMakeRect(0, 0, kCanvasPopoverW, h)];
  if (!self)
    return nil;
  _laneLabel = [lane.label copy];
  _valueType = lane.valueType;
  _cmin = lane.componentMin ?: @[];
  _cmax = lane.componentMax ?: @[];

  NSTextField *title = _KKMakeCaption(lane.label);
  [self addSubview:title];

  NSImage *resetImg =
      [[NSImage imageWithSystemSymbolName:@"arrow.counterclockwise"
                 accessibilityDescription:@"Reset to default"]
          imageWithSymbolConfiguration:
              [NSImageSymbolConfiguration
                  configurationWithPointSize:10.5
                                      weight:NSFontWeightRegular]];
  _reset = [NSButton buttonWithImage:resetImg
                              target:self
                              action:@selector(_resetTapped:)];
  _reset.bordered = NO;
  _reset.imagePosition = NSImageOnly;
  _reset.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.5];
  _reset.toolTip = @"Reset to default";
  _reset.translatesAutoresizingMaskIntoConstraints = NO;
  _reset.hidden = YES; // shown only when off-default (set after init)
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

  if (_valueType == KKLaneValueTypeCrop) {
    NSArray<NSString *> *caps = @[ @"W", @"H", @"X", @"Y" ];
    NSMutableArray<NSView *> *arranged = [NSMutableArray array];
    NSMutableArray<NSTextField *> *fs = [NSMutableArray array];
    for (NSInteger i = 0; i < 4; i++) {
      NSTextField *cap = _KKMakeCaption(caps[i]);
      NSTextField *fld = _KKMakeNumberField();
      fld.target = self;
      fld.action = @selector(_fieldCommitted:);
      fld.delegate = (id<NSTextFieldDelegate>)self; // live-typing for a guide
      [fld.widthAnchor constraintEqualToConstant:kStaticFieldW].active = YES;
      [arranged addObject:cap];
      [arranged addObject:fld];
      [fs addObject:fld];
      if (i < 3) { // divider between each W | H | X | Y group
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
    NSStackView *hs = [NSStackView stackViewWithViews:arranged];
    hs.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hs.alignment = NSLayoutAttributeCenterY;
    hs.spacing = KKPaddingMD;
    hs.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:hs];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:KKPaddingLG],
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
  } else {
    NSTextField *fld = _KKMakeNumberField();
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
    [self addSubview:fld];
    [NSLayoutConstraint activateConstraints:@[
      [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:KKPaddingLG],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [title.widthAnchor constraintEqualToConstant:54.0],
      [_slider.leadingAnchor constraintEqualToAnchor:title.trailingAnchor
                                            constant:KKPaddingSM],
      [_slider.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [fld.leadingAnchor constraintEqualToAnchor:_slider.trailingAnchor
                                        constant:KKPaddingSM],
      [fld.trailingAnchor constraintEqualToAnchor:_reset.leadingAnchor
                                         constant:-KKPaddingLG],
      [fld.widthAnchor constraintEqualToConstant:kStaticFieldW],
      [fld.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
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
// field the user is editing so typing isn't clobbered.
- (void)refreshDisplay {
  for (NSInteger i = 0;
       i < (NSInteger)_fields.count && i < (NSInteger)_values.count; i++) {
    if (_fields[i].currentEditor)
      continue;
    _fields[i].stringValue = [self _displayForNorm:_values[i].doubleValue
                                             index:i];
  }
  if (_slider && _values.count && !_fields[0].currentEditor)
    _slider.doubleValue = _values[0].doubleValue;
}

- (void)_setValues:(NSArray<NSNumber *> *)v emit:(BOOL)emit {
  _values = [v mutableCopy] ?: [NSMutableArray array];
  [self _constrain:_values];
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

- (void)_fieldCommitted:(id)sender {
  NSMutableArray<NSNumber *> *v = [_values mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)_fields.count && i < (NSInteger)v.count;
       i++)
    v[i] = @(_fields[i].doubleValue / [self _scaleAt:i]);
  [self _setValues:v emit:YES];
}

- (void)applyValues:(NSArray<NSNumber *> *)vals {
  [self _setValues:vals emit:NO];
}

- (void)applyLane:(KKLane *)lane {
  [self applyValues:lane.keyposes.firstObject.values];
}

- (NSView *)guideSliderView {
  return _slider;
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

// Live keystrokes in any field — report the parsed *display* value (the
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

// A non-editable row for a property excluded from the clicked boundary's
// phase: its name, a muted message, and an Animate button that opts it back
// in (so there's no detour to the gap popover).
@interface _KKExcludedRow : NSView
@property(nonatomic, copy) void (^onAnimate)(void);
- (instancetype)initWithLabel:(NSString *)label;
@end

@implementation _KKExcludedRow
- (BOOL)isFlipped {
  return YES;
}
- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kFloatRowH);
}
- (instancetype)initWithLabel:(NSString *)label {
  self = [super initWithFrame:NSMakeRect(0, 0, kCanvasPopoverW, kFloatRowH)];
  if (!self)
    return nil;
  NSTextField *title = _KKMakeCaption(label);
  NSTextField *msg = _KKMakeCaption(@"Excluded from this phase");
  msg.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.4];
  NSButton *btn = [NSButton buttonWithTitle:@"Animate"
                                     target:self
                                     action:@selector(_tap:)];
  btn.bordered = NO;
  btn.bezelStyle = NSBezelStyleInline;
  btn.controlSize = NSControlSizeSmall;
  NSFont *btnFont = [NSFont systemFontOfSize:KKFontSizeSM
                                      weight:NSFontWeightMedium];
  btn.font = btnFont;
  btn.attributedTitle = [[NSAttributedString alloc]
      initWithString:@"Animate"
          attributes:@{
            NSForegroundColorAttributeName : [NSColor accentMatchingHost],
            NSFontAttributeName : btnFont
          }];
  btn.translatesAutoresizingMaskIntoConstraints = NO;
  for (NSView *v in @[ title, msg, btn ])
    [self addSubview:v];
  [NSLayoutConstraint activateConstraints:@[
    [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                        constant:KKPaddingLG],
    [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [btn.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                       constant:-KKPaddingLG],
    [btn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [msg.trailingAnchor constraintEqualToAnchor:btn.leadingAnchor
                                       constant:-KKPaddingMD],
    [msg.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [msg.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                                   constant:KKPaddingSM],
  ]];
  return self;
}
- (void)_tap:(id)sender {
  if (_onAnimate)
    _onAnimate();
}
@end

@implementation _KKStaticValuesPopoverView {
  NSMutableDictionary<NSString *, _KKStaticValueRow *> *_rowsByLabel;
  NSStackView *_stack;
  KKMiniCanvasView *_miniCanvas;
  NSString *_descriptorPath;
  CGFloat _clipAspect;
  void (^_onHandleValue)(NSString *, NSArray<NSNumber *> *);
  void (^_onDragBegin)(void);
  void (^_onDragEnd)(void);
}

+ (CGFloat)_popoverWidthForDescriptor:(NSString *)descriptorPath {
  return descriptorPath.length > 0 ? kCanvasPopoverW : kPopoverW;
}

+ (CGFloat)_canvasHeightForAspect:(CGFloat)aspect width:(CGFloat)w {
  CGFloat a = aspect > 0 ? aspect : (16.0 / 9.0);
  return (w - 2 * KKPaddingMD) / a;
}

+ (CGFloat)heightForLanes:(NSArray<KKLane *> *)lanes
           descriptorPath:(NSString *)descriptorPath
               clipAspect:(CGFloat)clipAspect {
  CGFloat rows = 0;
  for (KKLane *lane in lanes)
    rows += [_KKStaticValueRow heightForLane:lane];
  CGFloat h = KKPaddingMD + rows + KKPaddingMD;
  if (descriptorPath.length > 0)
    h += [self _canvasHeightForAspect:clipAspect
                                width:[self _popoverWidthForDescriptor:
                                                descriptorPath]] +
         KKPaddingMD;
  return h;
}

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
               descriptorPath:(NSString *)descriptorPath
                   clipAspect:(CGFloat)clipAspect
               canvasDelegate:(id<KKMiniCanvasDelegate>)canvasDelegate
                onHandleValue:(void (^)(NSString *,
                                        NSArray<NSNumber *> *))onHandleValue
                  onDragBegin:(void (^)(void))onDragBegin
                    onDragEnd:(void (^)(void))onDragEnd {
  CGFloat W =
      [_KKStaticValuesPopoverView _popoverWidthForDescriptor:descriptorPath];
  CGFloat h = [_KKStaticValuesPopoverView heightForLanes:lanes
                                          descriptorPath:descriptorPath
                                              clipAspect:clipAspect];
  self = [super initWithFrame:NSMakeRect(0, 0, W, h)];
  if (!self)
    return nil;
  _descriptorPath = [descriptorPath copy];
  _clipAspect = clipAspect;
  _rowsByLabel = [NSMutableDictionary dictionary];
  _onHandleValue = [onHandleValue copy];
  _onDragBegin = [onDragBegin copy];
  _onDragEnd = [onDragEnd copy];

  NSLayoutYAxisAnchor *stackTopAnchor = self.topAnchor;
  CGFloat stackTopInset = KKPaddingMD;
  if (descriptorPath.length > 0) {
    _miniCanvas = [[KKMiniCanvasView alloc] initWithFrame:NSZeroRect];
    _miniCanvas.sourceDescriptorPath = descriptorPath;
    _miniCanvas.canvasDelegate = canvasDelegate;
    __weak typeof(self) weakSelf = self;
    _miniCanvas.onHandleValue =
        ^(NSString *label, NSArray<NSNumber *> *values) {
          // Live UI every tick (cheap); persist stays coalesced downstream.
          [weakSelf liveUpdateValues:values forLabel:label];
          if (onHandleValue)
            onHandleValue(label, values);
        };
    _miniCanvas.onHandleDragBegin = onDragBegin;
    _miniCanvas.onHandleDragEnd = onDragEnd;
    __weak typeof(self) weakSelfRes = self;
    _miniCanvas.onSourceResolved = ^{
      __strong typeof(weakSelfRes) s = weakSelfRes;
      // Media size now known → re-render pixel-scaled (crop) fields.
      for (_KKStaticValueRow *row in s->_rowsByLabel.allValues)
        [row refreshDisplay];
    };
    _miniCanvas.clipAspect = clipAspect > 0 ? clipAspect : (16.0 / 9.0);
    _miniCanvas.translatesAutoresizingMaskIntoConstraints = NO;
    _miniCanvas.wantsLayer = YES;
    _miniCanvas.layer.cornerRadius = 4.0;
    _miniCanvas.layer.masksToBounds = YES;

    // Host the canvas as the documentView of an NSScrollView — this is the
    // exact arrangement the old (working) KKStageSequencerView used to get
    // magnify/scroll events. The subclass blocks at-boundary overscroll from
    // propagating to FCP's inspector root scroll view.
    _KKMiniCanvasScrollView *sv =
        [[_KKMiniCanvasScrollView alloc] initWithFrame:NSZeroRect];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = NO;
    sv.hasHorizontalScroller = NO;
    // documentView is pinned to the clip view (no scrollable content); without
    // this, [super scrollWheel:] elastically bounces the whole canvas on
    // overscroll. We still call super first for momentum/phase coherence.
    sv.horizontalScrollElasticity = NSScrollElasticityNone;
    sv.verticalScrollElasticity = NSScrollElasticityNone;
    sv.documentView = _miniCanvas;
    [self addSubview:sv];
    NSClipView *clip = sv.contentView;
    [NSLayoutConstraint activateConstraints:@[
      [sv.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                       constant:KKPaddingMD],
      [sv.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                        constant:-KKPaddingMD],
      [sv.topAnchor constraintEqualToAnchor:self.topAnchor
                                   constant:KKPaddingMD],
      [sv.heightAnchor
          constraintEqualToConstant:[_KKStaticValuesPopoverView
                                        _canvasHeightForAspect:clipAspect
                                                         width:W]],
      [_miniCanvas.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
      [_miniCanvas.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
      [_miniCanvas.topAnchor constraintEqualToAnchor:clip.topAnchor],
      [_miniCanvas.bottomAnchor constraintEqualToAnchor:clip.bottomAnchor],
    ]];

    // The crop size readout is drawn inside the canvas at the crop's
    // bottom-right corner (see _KKMiniCanvasOverlay), matching the OSC.
    stackTopAnchor = sv.bottomAnchor;
    stackTopInset = KKPaddingMD;
  }

  _stack = [NSStackView stackViewWithViews:@[]];
  _stack.translatesAutoresizingMaskIntoConstraints = NO;
  _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _stack.spacing = 0;
  [self addSubview:_stack];
  [NSLayoutConstraint activateConstraints:@[
    [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_stack.topAnchor constraintEqualToAnchor:stackTopAnchor
                                     constant:stackTopInset],
  ]];

  for (KKLane *lane in lanes) {
    _KKStaticValueRow *row = [self _makeRowForLane:lane];
    [_stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.label] = row;
  }
  return self;
}

- (_KKStaticValueRow *)_makeRowForLane:(KKLane *)lane {
  _KKStaticValueRow *row = [[_KKStaticValueRow alloc] initWithLane:lane];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  NSString *label = lane.label;
  __weak typeof(self) weak = self;
  if (lane.valueType == KKLaneValueTypeCrop) {
    // Show crop in media pixels: W/X scale by media width, H/Y by height.
    // (≤0 until the feed resolves → row falls back to raw 0–1.)
    row.componentScale = ^double(NSInteger i) {
      __strong typeof(weak) s = weak;
      CGSize m = s ? s->_miniCanvas.sourceMediaSize : CGSizeZero;
      return (i == 0 || i == 2) ? m.width : m.height;
    };
  }
  row.onValue = ^(NSArray<NSNumber *> *values) {
    __strong typeof(weak) s = weak;
    // Live preview: feed the edit into the renderer + redraw the canvas
    // (persist stays coalesced via _onHandleValue downstream).
    id<KKMiniCanvasDelegate> del = s->_miniCanvas.canvasDelegate;
    if ([del
            respondsToSelector:@selector(
                                   miniCanvas:applyConstantValues:forLabel:)]) {
      [del miniCanvas:s->_miniCanvas applyConstantValues:values forLabel:label];
      [s->_miniCanvas setNeedsDisplay:YES];
      [s->_miniCanvas setHandlesNeedDisplay];
    }
    if (s->_onHandleValue)
      s->_onHandleValue(label, values);
  };
  row.onDragBegin = ^{
    __strong typeof(weak) s = weak;
    if (s->_onDragBegin)
      s->_onDragBegin();
  };
  row.onDragEnd = ^{
    __strong typeof(weak) s = weak;
    if (s->_onDragEnd)
      s->_onDragEnd();
  };
  return row;
}

- (void)applyDefaultsProvider:
    (NSArray<NSNumber *> * (^)(NSString *label))provider {
  if (!provider)
    return;
  for (NSString *label in _rowsByLabel)
    _rowsByLabel[label].defaultValues = provider(label);
}

- (void)applyExcludedLabels:(NSArray<NSString *> *)labels
                  onAnimate:(void (^)(NSString *))onAnimate {
  if (labels.count == 0)
    return;
  // Swap the excluded property's editable row for a message+Animate row at
  // the SAME stack position, so the original property order is preserved
  // (heights match → no resize).
  for (NSString *label in labels) {
    _KKStaticValueRow *old = _rowsByLabel[label];
    if (!old)
      continue;
    NSInteger idx = [_stack.arrangedSubviews indexOfObject:old];
    if (idx == NSNotFound)
      continue;
    [_stack removeArrangedSubview:old];
    [old removeFromSuperview];
    [_rowsByLabel removeObjectForKey:label];

    _KKExcludedRow *row = [[_KKExcludedRow alloc] initWithLabel:label];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *cap = [label copy];
    row.onAnimate = ^{
      if (onAnimate)
        onAnimate(cap);
    };
    [_stack insertArrangedSubview:row atIndex:idx];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    [row.heightAnchor constraintEqualToConstant:kFloatRowH].active = YES;
  }
}

// Live (per-tick) UI update during a mini-canvas handle drag — refresh the
// matching row's fields/slider WITHOUT persisting (the heavy timeline/FCP
// write stays coalesced to drag end). The crop size readout lives in the
// canvas overlay and redraws itself.
- (void)liveUpdateValues:(NSArray<NSNumber *> *)values
                forLabel:(NSString *)label {
  [_rowsByLabel[label] applyValues:values];
}

- (nullable NSView *)rowViewForLabel:(NSString *)label {
  return _rowsByLabel[label];
}

- (void)guideBeginConstantDrag {
  if (_onDragBegin)
    _onDragBegin();
}

- (void)guideApplyConstantValues:(NSArray<NSNumber *> *)values
                        forLabel:(NSString *)label {
  // Same body as _KKStaticValueRow.onValue: live preview into the renderer +
  // canvas redraw + move the row's knob/fields, persist coalesced downstream.
  id<KKMiniCanvasDelegate> del = _miniCanvas.canvasDelegate;
  if ([del respondsToSelector:@selector(
                                  miniCanvas:applyConstantValues:forLabel:)]) {
    [del miniCanvas:_miniCanvas applyConstantValues:values forLabel:label];
    [_miniCanvas setNeedsDisplay:YES];
    [_miniCanvas setHandlesNeedDisplay];
  }
  [self liveUpdateValues:values forLabel:label];
  if (_onHandleValue)
    _onHandleValue(label, values);
}

- (void)guideEndConstantDrag {
  if (_onDragEnd)
    _onDragEnd();
}

- (KKSliderView *)_guideSliderForLabel:(NSString *)label {
  NSView *v = [_rowsByLabel[label] guideSliderView];
  return [v isKindOfClass:[KKSliderView class]] ? (KKSliderView *)v : nil;
}

- (NSRect)guideSliderTrackScreenRectForLabel:(NSString *)label {
  return [[self _guideSliderForLabel:label] trackScreenRect];
}

- (CGFloat)guideSliderScreenXForValue:(double)value forLabel:(NSString *)label {
  return [[self _guideSliderForLabel:label] screenXForValue:value];
}

- (double)guideSliderValueForScreenX:(CGFloat)screenX
                            forLabel:(NSString *)label {
  return [[self _guideSliderForLabel:label] valueForScreenX:screenX];
}

- (NSRect)guideFieldScreenRectForLabel:(NSString *)label
                             component:(NSInteger)component {
  NSView *f = [_rowsByLabel[label] guideFieldViewForComponent:component];
  NSWindow *w = f.window;
  if (!f || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[f convertRect:f.bounds toView:nil]];
}

- (void)setGuideFieldEditHandlerForLabel:(NSString *)label
                                 handler:(void (^)(NSInteger, double))handler {
  _rowsByLabel[label].onGuideFieldEdit = handler;
}

- (void)guideCommitFieldForLabel:(NSString *)label
                       component:(NSInteger)component {
  [_rowsByLabel[label] guideCommitFieldForComponent:component];
}

- (void)updateUnoptedLanes:(NSArray<KKLane *> *)lanes {
  NSSet<NSString *> *newSet =
      [NSSet setWithArray:[lanes valueForKeyPath:@"label"]];

  NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
  for (NSString *label in _rowsByLabel)
    if (![newSet containsObject:label])
      [toRemove addObject:label];
  for (NSString *label in toRemove) {
    _KKStaticValueRow *row = _rowsByLabel[label];
    [_stack removeArrangedSubview:row];
    [row removeFromSuperview];
    [_rowsByLabel removeObjectForKey:label];
  }

  for (KKLane *lane in lanes) {
    if (_rowsByLabel[lane.label]) {
      [_rowsByLabel[lane.label] applyLane:lane]; // reflect external edits
      continue;
    }
    _KKStaticValueRow *row = [self _makeRowForLane:lane];
    NSInteger insertIdx = _stack.arrangedSubviews.count;
    for (NSInteger i = 0; i < (NSInteger)_stack.arrangedSubviews.count; i++) {
      _KKStaticValueRow *existing =
          (_KKStaticValueRow *)_stack.arrangedSubviews[i];
      if ([lane.label localizedCaseInsensitiveCompare:existing.laneLabel] ==
          NSOrderedAscending) {
        insertIdx = i;
        break;
      }
    }
    [_stack insertArrangedSubview:row atIndex:insertIdx];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _rowsByLabel[lane.label] = row;
  }

  if (lanes.count == 0 && _popover)
    [_popover close];
  else if (_popover)
    _popover.contentSize = NSMakeSize(
        [_KKStaticValuesPopoverView _popoverWidthForDescriptor:_descriptorPath],
        [_KKStaticValuesPopoverView heightForLanes:lanes
                                    descriptorPath:_descriptorPath
                                        clipAspect:_clipAspect]);
}

@end

@implementation _KKDropdownTrigger

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
  return YES;
}

- (NSString *)_summaryText {
  if (_selectedLabels.count == 0)
    return @"Add properties…";
  NSMutableString *s = [NSMutableString string];
  NSInteger shown = MIN((NSInteger)_selectedLabels.count, kMaxSummaryLabels);
  for (NSInteger i = 0; i < shown; i++) {
    if (i > 0)
      [s appendString:@", "];
    [s appendString:_selectedLabels[i]];
  }
  NSInteger overflow = (NSInteger)_selectedLabels.count - kMaxSummaryLabels;
  if (overflow > 0)
    [s appendFormat:@" +%ld", (long)overflow];
  return s;
}

- (void)drawRect:(NSRect)dirty {
  NSString *text = [self _summaryText];
  BOOL hasSelection = _selectedLabels.count > 0;
  NSColor *textColor =
      hasSelection ? [NSColor inspectorLabel]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : textColor,
  };

  NSImage *chevRaw = [[NSImage imageWithSystemSymbolName:@"chevron.down"
                                accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:KKFontSizeSM - 2.0
                                  weight:NSFontWeightMedium]];
  NSImage *chev = [chevRaw copy];
  [chev lockFocus];
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.4] set];
  NSRectFillUsingOperation(NSMakeRect(0, 0, chev.size.width, chev.size.height),
                           NSCompositingOperationSourceAtop);
  [chev unlockFocus];
  CGFloat chevW = chev.size.width, chevH = chev.size.height;
  CGFloat chevX = NSMaxX(self.bounds) - chevW;
  CGFloat chevY = NSMidY(self.bounds) - chevH / 2.0;
  [chev drawInRect:NSMakeRect(chevX, chevY, chevW, chevH)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];

  NSSize textSz = [text sizeWithAttributes:attrs];
  [text drawAtPoint:NSMakePoint(0, NSMidY(self.bounds) - textSz.height / 2.0)
      withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)e {
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

@end

@implementation _KKLaneRow {
  NSTextField *_nameLabel;
}

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _nameLabel = [NSTextField labelWithString:@""];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [NSFont systemFontOfSize:KKFontSizeSM
                                        weight:NSFontWeightRegular];
    _nameLabel.textColor = [NSColor inspectorLabel];
    [self addSubview:_nameLabel];
    [NSLayoutConstraint activateConstraints:@[
      [_nameLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                               constant:KKPaddingLG],
      [_nameLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
  }
  return self;
}

- (void)setLaneLabel:(NSString *)laneLabel {
  _laneLabel = [laneLabel copy];
  _nameLabel.stringValue = laneLabel;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kRowHeight);
}

@end
