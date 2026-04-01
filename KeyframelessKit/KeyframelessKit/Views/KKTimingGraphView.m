/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKTimingGraphView.h"
#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCheckboxView.h"
#import <AppKit/AppKit.h>

static const CGFloat kGraphHeight = 60.0;
static const CGFloat kLabelRowHeight = 20.0;
static const CGFloat kCurvePadding = KKPaddingLG;
static const NSInteger kCurveSegments = 40;
static const NSInteger kGridRows = 4;
static const CGFloat kCheckboxSize = 12.0;

@implementation KKTimingGraphView {
  NSImageView *_graphImageView;
  KKCheckboxView *_inCheckbox;
  KKCheckboxView *_outCheckbox;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _inEnabled = NO;
    _outEnabled = NO;
    _inCurve = KKEasingCurveCubic;
    _outCurve = KKEasingCurveCubic;
    _selectedSection = KKTimingGraphSectionMid;

    _graphImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _graphImageView.imageScaling = NSImageScaleNone;
    _graphImageView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_graphImageView];

    [NSLayoutConstraint activateConstraints:@[
      [_graphImageView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_graphImageView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
      [_graphImageView.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_graphImageView.heightAnchor
          constraintEqualToConstant:kGraphHeight + kLabelRowHeight],
    ]];

    _inCheckbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
    _inCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_inCheckbox];

    _outCheckbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
    _outCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_outCheckbox];

    [NSLayoutConstraint activateConstraints:@[
      [_inCheckbox.widthAnchor constraintEqualToConstant:kCheckboxSize],
      [_inCheckbox.heightAnchor constraintEqualToConstant:kCheckboxSize],
      [_outCheckbox.widthAnchor constraintEqualToConstant:kCheckboxSize],
      [_outCheckbox.heightAnchor constraintEqualToConstant:kCheckboxSize],
    ]];

    __weak typeof(self) weakSelf = self;
    _inCheckbox.onToggle = ^(BOOL isChecked) {
      if (weakSelf.onInToggled)
        weakSelf.onInToggled(isChecked);
    };
    _outCheckbox.onToggle = ^(BOOL isChecked) {
      if (weakSelf.onOutToggled)
        weakSelf.onOutToggled(isChecked);
    };
  }
  return self;
}

- (void)setInEnabled:(BOOL)inEnabled {
  _inEnabled = inEnabled;
  _inCheckbox.isChecked = inEnabled;
  [self renderGraph];
}

- (void)setOutEnabled:(BOOL)outEnabled {
  _outEnabled = outEnabled;
  _outCheckbox.isChecked = outEnabled;
  [self renderGraph];
}

- (void)setInCurve:(KKEasingCurve)inCurve {
  _inCurve = inCurve;
  [self renderGraph];
}

- (void)setOutCurve:(KKEasingCurve)outCurve {
  _outCurve = outCurve;
  [self renderGraph];
}

- (void)setSelectedSection:(KKTimingGraphSection)selectedSection {
  _selectedSection = selectedSection;
  [self renderGraph];
}

- (BOOL)isFlipped {
  return YES;
}

// Section rects relative to the graph image (no outer inset — that's on the
// image view).
- (NSRect)sectionRectForSection:(KKTimingGraphSection)section
                          width:(CGFloat)totalWidth {
  CGFloat sectionWidth = floor(totalWidth / 3.0);
  CGFloat x = section * sectionWidth;
  if (section == KKTimingGraphSectionOut)
    sectionWidth = totalWidth - x;
  return NSMakeRect(x, 0, sectionWidth, kGraphHeight);
}

// Section rects relative to self (includes inset offset for hit testing).
- (NSRect)graphRectForSection:(KKTimingGraphSection)section {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat graphWidth = NSWidth(self.bounds) - 2 * inset;
  NSRect r = [self sectionRectForSection:section width:graphWidth];
  r.origin.x += inset;
  return r;
}

- (void)layout {
  [super layout];

  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightMedium],
  };
  CGFloat cbY = kGraphHeight + (kLabelRowHeight - kCheckboxSize) / 2.0;

  NSSize inSize = [@"In" sizeWithAttributes:attrs];
  NSRect inRect = [self graphRectForSection:KKTimingGraphSectionIn];
  CGFloat inGroupX =
      NSMidX(inRect) - (inSize.width + KKSpacingSM + kCheckboxSize) / 2.0;
  _inCheckbox.frame = NSMakeRect(inGroupX + inSize.width + KKSpacingSM, cbY,
                                 kCheckboxSize, kCheckboxSize);

  NSSize outSize = [@"Out" sizeWithAttributes:attrs];
  NSRect outRect = [self graphRectForSection:KKTimingGraphSectionOut];
  CGFloat outGroupX =
      NSMidX(outRect) - (outSize.width + KKSpacingSM + kCheckboxSize) / 2.0;
  _outCheckbox.frame = NSMakeRect(outGroupX + outSize.width + KKSpacingSM, cbY,
                                  kCheckboxSize, kCheckboxSize);

  [self renderGraph];
}

- (void)renderGraph {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat graphWidth = NSWidth(self.bounds) - 2 * inset;
  if (graphWidth < 1)
    return;

  CGFloat totalHeight = kGraphHeight + kLabelRowHeight;
  // NSImage draws in non-flipped coordinates (y=0 at bottom).
  // Label row is at bottom (y=0..kLabelRowHeight), graph above it.
  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(graphWidth, totalHeight)];
  [image lockFocus];

  [[NSColor inspectorBackground] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, kLabelRowHeight,
                                                      graphWidth, kGraphHeight)
                                   xRadius:KKRadiusMD
                                   yRadius:KKRadiusMD] fill];

  // Offset grid and sections up by kLabelRowHeight for non-flipped coords
  NSAffineTransform *xform = [NSAffineTransform transform];
  [xform translateXBy:0 yBy:kLabelRowHeight];
  [xform concat];

  [self renderGridWithWidth:graphWidth];

  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    [self renderSection:s width:graphWidth];
  }

  // Reset transform for labels
  NSAffineTransform *reset = [NSAffineTransform transform];
  [reset translateXBy:0 yBy:-kLabelRowHeight];
  [reset concat];

  [self renderLabelsWithWidth:graphWidth];

  [image unlockFocus];
  _graphImageView.image = image;
}

- (void)renderGridWithWidth:(CGFloat)totalWidth {
  NSColor *gridColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.08];
  [gridColor setStroke];

  NSBezierPath *grid = [NSBezierPath bezierPath];
  grid.lineWidth = 0.5;

  CGFloat drawHeight = kGraphHeight - 2 * kCurvePadding;
  CGFloat drawWidth = totalWidth - 2 * kCurvePadding;
  CGFloat cellSize = drawHeight / (CGFloat)kGridRows;
  NSInteger cols = (NSInteger)floor(drawWidth / cellSize);
  CGFloat right = kCurvePadding + drawWidth;

  for (NSInteger i = 0; i <= kGridRows; i++) {
    CGFloat y = kCurvePadding + i * cellSize;
    [grid moveToPoint:NSMakePoint(kCurvePadding, y)];
    [grid lineToPoint:NSMakePoint(right, y)];
  }

  for (NSInteger i = 0; i <= cols; i++) {
    CGFloat x = kCurvePadding + i * cellSize;
    if (x > right)
      break;
    [grid moveToPoint:NSMakePoint(x, kCurvePadding)];
    [grid lineToPoint:NSMakePoint(x, kCurvePadding + drawHeight)];
  }

  [grid stroke];
}

- (void)renderSection:(KKTimingGraphSection)section width:(CGFloat)totalWidth {
  NSRect rect = [self sectionRectForSection:section width:totalWidth];
  BOOL selected = (section == _selectedSection);

  if (selected) {
    NSColor *selColor = [[NSColor accent] colorWithAlphaComponent:0.1];
    [selColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect
                                     xRadius:KKRadiusMD
                                     yRadius:KKRadiusMD] fill];
  }

  BOOL enabled;
  switch (section) {
  case KKTimingGraphSectionIn:
    enabled = _inEnabled;
    break;
  case KKTimingGraphSectionOut:
    enabled = _outEnabled;
    break;
  default:
    enabled = YES;
    break;
  }

  NSColor *curveColor =
      enabled ? [NSColor accent]
              : [[NSColor inspectorLabel] colorWithAlphaComponent:0.3];
  [curveColor setStroke];

  NSBezierPath *curve = [NSBezierPath bezierPath];
  curve.lineWidth = enabled ? 2.0 : 1.0;

  if (!enabled) {
    CGFloat pattern[] = {4.0, 3.0};
    [curve setLineDash:pattern count:2 phase:0];
  }

  CGFloat curveLeft = NSMinX(rect);
  CGFloat curveRight = NSMaxX(rect);
  if (section == KKTimingGraphSectionIn)
    curveLeft = kCurvePadding;
  if (section == KKTimingGraphSectionOut)
    curveRight = totalWidth - kCurvePadding;
  CGFloat x0 = curveLeft;
  CGFloat w = curveRight - curveLeft;
  // Non-flipped: y=0 bottom, y increases upward
  CGFloat yBottom = kCurvePadding;
  CGFloat yTop = kGraphHeight - kCurvePadding;

  for (NSInteger i = 0; i <= kCurveSegments; i++) {
    CGFloat rawT = (CGFloat)i / (CGFloat)kCurveSegments;
    CGFloat easedT;

    switch (section) {
    case KKTimingGraphSectionIn:
      easedT = enabled ? KKApplyCurveIn(rawT, _inCurve) : 1.0;
      break;
    case KKTimingGraphSectionMid:
      easedT = 1.0;
      break;
    case KKTimingGraphSectionOut:
      easedT = enabled ? KKApplyCurveOut(1.0 - rawT, _outCurve) : 1.0;
      break;
    }

    CGFloat px = x0 + rawT * w;
    CGFloat py = yBottom + easedT * (yTop - yBottom);

    if (i == 0)
      [curve moveToPoint:NSMakePoint(px, py)];
    else
      [curve lineToPoint:NSMakePoint(px, py)];
  }

  [curve stroke];
}

- (void)renderLabelsWithWidth:(CGFloat)totalWidth {
  NSString *labels[] = {@"In", @"Mid", @"Out"};

  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    NSRect sRect = [self sectionRectForSection:s width:totalWidth];
    BOOL selected = (s == _selectedSection);

    NSDictionary *attrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : selected
          ? [NSColor inspectorLabel]
          : [[NSColor inspectorLabel] colorWithAlphaComponent:0.5],
    };
    NSSize labelSize = [labels[s] sizeWithAttributes:attrs];
    // Non-flipped: label row is at y=0..kLabelRowHeight
    CGFloat labelY = (kLabelRowHeight - labelSize.height) / 2.0;

    CGFloat labelX;
    if (s == KKTimingGraphSectionMid) {
      labelX = NSMidX(sRect) - labelSize.width / 2.0;
    } else {
      CGFloat groupWidth = labelSize.width + KKSpacingSM + kCheckboxSize;
      labelX = NSMidX(sRect) - groupWidth / 2.0;
    }
    [labels[s] drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:attrs];
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    if (NSPointInRect(loc, [self graphRectForSection:s])) {
      if (self.onSectionSelected)
        self.onSectionSelected(s);
      return;
    }
  }
}

@end
