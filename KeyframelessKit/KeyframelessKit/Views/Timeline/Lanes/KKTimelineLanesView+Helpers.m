/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKMiniCanvasView.h"
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
  _searchField.placeholderString =
      KKLoc(@"Search", @"Placeholder: search properties.");
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
