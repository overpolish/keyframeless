/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneCategoryNav.h"
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
  // Square checkbox - Bezier path approach (coordinate-system independent
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
    // Checkmark path - y-values are flipped relative to KKCheckboxView
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
  NSString *display = KKLocalizedParamName(_rowLabel);
  NSSize textSz = [display sizeWithAttributes:attrs];
  [display drawAtPoint:NSMakePoint(KKPaddingLG + kCheckSize + 6.0,
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

static const CGFloat kManagePillH = 24.0;

@implementation _KKManagePopoverView {
  NSSet<NSString *> *_checkedLabels;
  _KKSearchField *_searchField;
  NSMutableArray<_KKManageRow *> *_allRows;
  NSStackView *_rowStack;
  // Category nav pill between the search field and the rows (same control as
  // the value popover). Filters rows to the selected category, EXCEPT while a
  // search query is active - search spans every category so a param is always
  // findable.
  KKPillToggleRowView *_categoryPill;
  NSString *_selectedCategory;
  NSDictionary<NSString *, NSString *> *_rowCategoryByLabel;
  BOOL _hasPill;
}

+ (CGFloat)heightForLaneCount:(NSInteger)count {
  return [self heightForRowCount:count hasPill:NO];
}

+ (CGFloat)heightForRowCount:(NSInteger)count hasPill:(BOOL)hasPill {
  CGFloat h = KKPaddingMD + kSearchH + KKPaddingMD;
  if (hasPill)
    h += kManagePillH + KKSpacingSM;
  return h + count * kRowHeight + KKPaddingMD;
}

- (BOOL)isFlipped {
  return YES;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                checkedLabels:(NSSet<NSString *> *)checked
                     onToggle:(void (^)(NSString *))onToggle {
  // Only animatable lanes get a row (value-only params like a seed can't be
  // added to the timeline), so categories + sizing are derived from that
  // subset. Computed into locals before super init, then stored on self
  // afterwards.
  NSMutableArray<KKLane *> *animatable = [NSMutableArray array];
  for (KKLane *lane in lanes)
    if (lane.animatable)
      [animatable addObject:lane];

  NSDictionary<NSString *, NSString *> *catByLabel =
      KKLaneCategoryByLabel(animatable);
  NSArray<NSString *> *keys = KKLaneCategoryKeys(animatable);
  BOOL hasPill = keys.count > 1;
  NSString *selected = hasPill ? keys.firstObject : nil;

  // Initial visible rows = the first category's rows (or all when no pill), so
  // the popover opens hugging that page; it resizes as the pill/search narrows.
  NSInteger initialVisible = 0;
  for (KKLane *lane in animatable)
    if (!hasPill || catByLabel[lane.label] == nil ||
        [catByLabel[lane.label] isEqualToString:selected])
      initialVisible++;
  CGFloat h = [_KKManagePopoverView heightForRowCount:initialVisible
                                              hasPill:hasPill];
  self = [super initWithFrame:NSMakeRect(0, 0, kPopoverW, h)];
  if (!self)
    return nil;
  _checkedLabels = [checked copy];
  _allRows = [NSMutableArray array];
  _rowCategoryByLabel = catByLabel;
  _hasPill = hasPill;
  _selectedCategory = selected;

  _searchField = [[_KKSearchField alloc] init];
  _searchField.translatesAutoresizingMaskIntoConstraints = NO;
  _searchField.placeholderString =
      KKLoc(@"Search", @"Placeholder: search properties.");
  _searchField.delegate = self;
  _searchField.font = [NSFont systemFontOfSize:KKFontSizeSM
                                        weight:NSFontWeightRegular];
  _searchField.focusRingType = NSFocusRingTypeNone;
  // Category pill on top, then the search field, then the rows.
  NSLayoutYAxisAnchor *searchTop = self.topAnchor;
  CGFloat searchTopInset = KKPaddingMD;
  if (_hasPill) {
    __weak typeof(self) weak = self;
    _categoryPill =
        KKMakeLaneCategoryPill(animatable, selected, ^(NSString *categoryKey) {
          __strong typeof(weak) ss = weak;
          if (!ss)
            return;
          ss->_selectedCategory = categoryKey;
          [ss _applyFilterAndResize];
        });
    [self addSubview:_categoryPill];
    [NSLayoutConstraint activateConstraints:@[
      [_categoryPill.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [_categoryPill.topAnchor constraintEqualToAnchor:self.topAnchor
                                              constant:KKPaddingMD],
      [_categoryPill.heightAnchor constraintEqualToConstant:kManagePillH],
    ]];
    searchTop = _categoryPill.bottomAnchor;
    searchTopInset = KKSpacingSM;
  }

  [self addSubview:_searchField];
  [NSLayoutConstraint activateConstraints:@[
    [_searchField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                               constant:KKPaddingMD],
    [_searchField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                constant:-KKPaddingMD],
    [_searchField.topAnchor constraintEqualToAnchor:searchTop
                                           constant:searchTopInset],
    [_searchField.heightAnchor constraintEqualToConstant:kSearchH],
  ]];

  NSLayoutYAxisAnchor *rowsTop = _searchField.bottomAnchor;
  _rowStack = [NSStackView stackViewWithViews:@[]];
  _rowStack.translatesAutoresizingMaskIntoConstraints = NO;
  _rowStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _rowStack.spacing = 0;
  _rowStack.detachesHiddenViews = YES;
  [self addSubview:_rowStack];
  [NSLayoutConstraint activateConstraints:@[
    [_rowStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_rowStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_rowStack.topAnchor constraintEqualToAnchor:rowsTop constant:KKSpacingSM],
  ]];

  for (KKLane *lane in animatable) {
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
  [self _applyFilter];
  return self;
}

// Hide rows outside the selected category, and within it hide rows that don't
// match the search query - search is scoped to the current category. Returns
// the visible row count so the caller can resize the popover to hug it.
- (NSInteger)_applyFilter {
  NSString *query = _searchField.stringValue;
  BOOL searching = query.length > 0;
  NSInteger visible = 0;
  for (_KKManageRow *row in _allRows) {
    BOOL matchSearch =
        !searching || [row.rowLabel rangeOfString:query
                                          options:NSCaseInsensitiveSearch]
                              .location != NSNotFound;
    NSString *cat = _rowCategoryByLabel[row.rowLabel];
    BOOL matchCategory =
        !_hasPill || cat.length == 0 || [cat isEqualToString:_selectedCategory];
    BOOL show = matchSearch && matchCategory;
    row.hidden = !show;
    if (show)
      visible++;
  }
  return visible;
}

- (void)_applyFilterAndResize {
  NSInteger visible = [self _applyFilter];
  if (!self.popover)
    return;
  self.popover.contentSize = NSMakeSize(
      kPopoverW, [_KKManagePopoverView heightForRowCount:MAX(visible, 1)
                                                 hasPill:_hasPill]);
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
  [self _applyFilterAndResize];
}

@end
