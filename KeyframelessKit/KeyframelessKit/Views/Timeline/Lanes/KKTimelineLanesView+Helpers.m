/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKFieldEditorSupport.h"
#import "KKLocalized.h"
#import "KKMiniViewerView.h"
#import "KKPopoverBackground.h"
#import "KKPopoverHeaderView.h"
#import "KKSliderView.h"
#import "KKTimelineInspectorButtons.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTokens.h"
#import "KKValueTextField.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/QuartzCore.h>

@implementation _KKLVPopoverContentView
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window)
    KKApplyPopoverBackground(self);
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

@implementation _KKSearchField {
  id _outsideClickMon; // blurs the field on an outside click while editing
}
+ (Class)cellClass {
  return [_KKSearchFieldCell class];
}

// Focus from a real click only, never the window's key-view loop when the
// popover opens - so a freshly-shown checklist (lane filter, OSC, "Applies to")
// doesn't auto-grab focus. That auto-focus would leave the field editor as
// first responder, which swallows spacebar (playback) and Esc (close popover).
// Same approach as KKCodeEditorView: gate on the CURRENT EVENT being a
// mouse-down in OUR window landing on the field; the popover's opening click is
// in the host window, so the key-loop auto-focus is rejected while a genuine
// click focuses.
- (BOOL)acceptsFirstResponder {
  NSEvent *cur = NSApp.currentEvent;
  BOOL fromClick = cur && (cur.type == NSEventTypeLeftMouseDown ||
                           cur.type == NSEventTypeRightMouseDown);
  if (!fromClick || cur.window != self.window)
    return NO;
  NSPoint p = [self convertPoint:cur.locationInWindow fromView:nil];
  return NSPointInRect(p, self.bounds);
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES; // focus on the first click even when the popover isn't key yet
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
    KKStyleFieldEditorAccent([self currentEditor]);
    // Blur on a click anywhere off the field: a ViewBridge popover won't resign
    // a field on a click that lands on a non-responder (a checklist row), so
    // wire the shared field monitor - same as every other field.
    if (!_outsideClickMon)
      _outsideClickMon = KKMakeFieldOutsideClickMonitor(self);
  }
  return r;
}

- (void)dealloc {
  if (_outsideClickMon)
    [NSEvent removeMonitor:_outsideClickMon];
}
@end

// Horizontal shift per indent level for a nested (child) manage row.
static const CGFloat kManageRowIndentStep = 14.0;

@implementation _KKManageRow

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
  return YES;
}

- (void)setIndentLevel:(NSInteger)indentLevel {
  _indentLevel = indentLevel;
  [self setNeedsDisplay:YES];
}

- (void)setChecked:(BOOL)checked {
  _checked = checked;
  [self setNeedsDisplay:YES];
}

- (void)setRadio:(BOOL)radio {
  _radio = radio;
  [self setNeedsDisplay:YES];
}

- (void)setWarning:(BOOL)warning {
  _warning = warning;
  [self setNeedsDisplay:YES];
}

- (void)setDisplayOverride:(NSString *)displayOverride {
  _displayOverride = [displayOverride copy];
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty {
  // Square checkbox - Bezier path approach (coordinate-system independent
  // shape). Child rows shift right by their indent depth.
  CGFloat indent = (CGFloat)_indentLevel * kManageRowIndentStep;
  CGFloat checkX = KKPaddingLG + indent;
  CGFloat checkY = round(NSMidY(self.bounds) - kCheckSize / 2.0);
  NSRect boxRect = NSMakeRect(checkX, checkY, kCheckSize, kCheckSize);

  // Nested rows draw a vertical guide aligned to the PARENT checkbox centre, so
  // a child reads as belonging to the group above it. Uses the same border tone
  // as the unchecked checkbox outline (the typical field-border colour).
  if (_indentLevel > 0) {
    CGFloat guideX = KKPaddingLG +
                     (CGFloat)(_indentLevel - 1) * kManageRowIndentStep +
                     kCheckSize / 2.0;
    NSBezierPath *guide = [NSBezierPath bezierPath];
    guide.lineWidth = 1.0;
    [guide moveToPoint:NSMakePoint(guideX, 0)];
    [guide lineToPoint:NSMakePoint(guideX, NSHeight(self.bounds))];
    [[[NSColor inspectorLabel] colorWithAlphaComponent:0.3] setStroke];
    [guide stroke];
  }

  NSColor *fillColor =
      _warning ? [NSColor warning] : [NSColor accentMatchingHost];
  // A full-height radius rounds the same square into a circle, so radio and
  // checkbox share one path and stay pixel-identical in size and alignment.
  CGFloat radius = _radio ? kCheckSize / 2.0 : kCheckRadius;
  if (_checked) {
    NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:boxRect
                                                         xRadius:radius
                                                         yRadius:radius];
    [fillColor setFill];
    [fill fill];
    NSRect innerRect = NSInsetRect(boxRect, 0.25, 0.25);
    NSBezierPath *innerStroke =
        [NSBezierPath bezierPathWithRoundedRect:innerRect
                                        xRadius:radius - 0.25
                                        yRadius:radius - 0.25];
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
                                        xRadius:radius
                                        yRadius:radius];
    [[[NSColor inspectorLabel] colorWithAlphaComponent:0.3] setStroke];
    border.lineWidth = 1.0;
    [border stroke];
  }

  NSColor *baseText = _warning ? [NSColor warning] : [NSColor inspectorLabel];
  NSColor *textColor =
      _checked ? baseText : [baseText colorWithAlphaComponent:0.6];
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : textColor,
  };
  NSString *display = _displayOverride.length ? _displayOverride
                                              : KKLocalizedParamName(_rowLabel);
  NSSize textSz = [display sizeWithAttributes:attrs];
  [display drawAtPoint:NSMakePoint(KKPaddingLG + indent + kCheckSize + 6.0,
                                   NSMidY(self.bounds) - textSz.height / 2.0)
        withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)e {
  if ((e.modifierFlags & NSEventModifierFlagOption) && _onOptionToggle) {
    _onOptionToggle();
    return;
  }
  if (_onToggle)
    _onToggle();
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kRowHeight);
}

@end

@implementation _KKManagePopoverView {
  NSSet<NSString *> *_checkedLabels;
  void (^_onToggle)(NSString *);
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                checkedLabels:(NSSet<NSString *> *)checked
                minimumHeight:(CGFloat)minimumHeight
                     onToggle:(void (^)(NSString *))onToggle {
  // Only animatable lanes get a row - value-only params (e.g. a seed) can't be
  // added to the timeline.
  NSMutableArray<KKLane *> *animatable = [NSMutableArray array];
  for (KKLane *lane in lanes)
    if (lane.animatable)
      [animatable addObject:lane];
  self = [super initWithLanes:animatable minimumHeight:minimumHeight];
  if (!self)
    return nil;
  _checkedLabels = [checked copy];
  _onToggle = [onToggle copy];
  [self rebuildRows];
  return self;
}

- (void)configureRow:(_KKManageRow *)row forLane:(KKLane *)lane {
  row.checked = [_checkedLabels containsObject:lane.key];
  NSString *label = lane.key;
  void (^onToggle)(NSString *) = _onToggle;
  row.onToggle = ^{
    if (onToggle)
      onToggle(label);
  };
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

@end
