/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKTimingGraphView.h"
#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCheckboxView.h"
#import "KKSliderView.h"
#import <AppKit/AppKit.h>

static const CGFloat kGraphHeight = 60.0;
static const CGFloat kLabelRowHeight = 20.0;
static const CGFloat kSliderRowHeight = 28.0;
static const CGFloat kTickHeight = 16.0;
static const CGFloat kTickWidth = 22.0;
static const CGFloat kCurvePadding = KKPaddingLG;
static const NSInteger kCurveSegments = 40;
static const NSInteger kTickSegments = 16;
static const NSInteger kGridRows = 4;
static const CGFloat kCheckboxSize = 12.0;

@implementation KKTimingGraphView {
  NSImageView *_graphImageView;
  KKCheckboxView *_inCheckbox;
  KKCheckboxView *_outCheckbox;
  KKSliderView *_curveSlider;
  NSImageView *_tickImageView;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _inEnabled = NO;
    _outEnabled = NO;
    _inCurve = KKEasingCurveEaseOut;
    _outCurve = KKEasingCurveEaseOut;
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

    _curveSlider = [KKSliderView styledSlider];
    _curveSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _curveSlider.minValue = 0;
    _curveSlider.maxValue = KKEasingCurveCount - 1;
    _curveSlider.doubleValue = KKEasingCurveEaseOut;
    _curveSlider.continuous = YES;
    _curveSlider.slider.allowsTickMarkValuesOnly = YES;
    _curveSlider.slider.numberOfTickMarks = KKEasingCurveCount;
    _curveSlider.hidden = YES;
    _curveSlider.target = self;
    _curveSlider.action = @selector(curveSliderChanged:);
    [self addSubview:_curveSlider];

    CGFloat sliderTop = kGraphHeight + kLabelRowHeight;
    [NSLayoutConstraint activateConstraints:@[
      [_curveSlider.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset +
                                  kTickWidth / 2.0],
      [_curveSlider.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-(KKInspectorHorizontalInset +
                                    kTickWidth / 2.0)],
      [_curveSlider.topAnchor constraintEqualToAnchor:self.topAnchor
                                             constant:sliderTop],
      [_curveSlider.heightAnchor constraintEqualToConstant:kSliderRowHeight],
    ]];

    _tickImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _tickImageView.imageScaling = NSImageScaleNone;
    _tickImageView.translatesAutoresizingMaskIntoConstraints = NO;
    _tickImageView.hidden = YES;
    [self addSubview:_tickImageView];

    CGFloat tickTop = sliderTop + kSliderRowHeight;
    [NSLayoutConstraint activateConstraints:@[
      [_tickImageView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_tickImageView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],
      [_tickImageView.topAnchor constraintEqualToAnchor:self.topAnchor
                                               constant:tickTop],
      [_tickImageView.heightAnchor constraintEqualToConstant:kTickHeight],
    ]];
  }
  return self;
}

- (void)curveSliderChanged:(id)sender {
  KKEasingCurve curve = (KKEasingCurve)lround(_curveSlider.doubleValue);
  if (_selectedSection == KKTimingGraphSectionIn) {
    _inCurve = curve;
    [self renderGraph];
    [self renderTicks];
    if (self.onInCurveChanged)
      self.onInCurveChanged(curve);
  } else if (_selectedSection == KKTimingGraphSectionOut) {
    _outCurve = curve;
    [self renderGraph];
    [self renderTicks];
    if (self.onOutCurveChanged)
      self.onOutCurveChanged(curve);
  }
}

- (void)updateCurveSlider {
  BOOL showIn = _selectedSection == KKTimingGraphSectionIn && _inEnabled;
  BOOL showOut = _selectedSection == KKTimingGraphSectionOut && _outEnabled;
  BOOL show = showIn || showOut;

  _curveSlider.hidden = !show;
  _tickImageView.hidden = !show;
  if (showIn)
    _curveSlider.doubleValue = _inCurve;
  else if (showOut)
    _curveSlider.doubleValue = _outCurve;

  if (show)
    [self renderTicks];
}

- (void)setInEnabled:(BOOL)inEnabled {
  _inEnabled = inEnabled;
  _inCheckbox.isChecked = inEnabled;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setOutEnabled:(BOOL)outEnabled {
  _outEnabled = outEnabled;
  _outCheckbox.isChecked = outEnabled;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setInCurve:(KKEasingCurve)inCurve {
  _inCurve = inCurve;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setOutCurve:(KKEasingCurve)outCurve {
  _outCurve = outCurve;
  [self updateCurveSlider];
  [self renderGraph];
}

- (void)setSelectedSection:(KKTimingGraphSection)selectedSection {
  _selectedSection = selectedSection;
  [self updateCurveSlider];
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
  CGFloat x = (CGFloat)section * sectionWidth;
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

  [self updateCurveSlider];
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

- (void)globalCurveRangeMin:(CGFloat *)outMin max:(CGFloat *)outMax {
  CGFloat minVal = 0.0, maxVal = 1.0;
  KKEasingCurve curves[] = {_inCurve, _outCurve};
  BOOL enabled[] = {_inEnabled, _outEnabled};
  for (int c = 0; c < 2; c++) {
    if (!enabled[c])
      continue;
    for (NSInteger i = 0; i <= kCurveSegments; i++) {
      CGFloat t = (CGFloat)i / (CGFloat)kCurveSegments;
      CGFloat v = (c == 1) ? KKApplyEasing(1.0 - t, curves[c])
                           : KKApplyEasing(t, curves[c]);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
  }
  *outMin = minVal;
  *outMax = maxVal;
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
  CGFloat yBottom = kCurvePadding;
  CGFloat yTop = kGraphHeight - kCurvePadding;

  // Use global range across both curves so all sections share the same scale
  CGFloat minVal = 0.0, maxVal = 1.0;
  [self globalCurveRangeMin:&minVal max:&maxVal];
  CGFloat range = maxVal - minVal;

  for (NSInteger i = 0; i <= kCurveSegments; i++) {
    CGFloat rawT = (CGFloat)i / (CGFloat)kCurveSegments;
    CGFloat easedT;

    switch (section) {
    case KKTimingGraphSectionIn:
      easedT = enabled ? KKApplyEasing(rawT, _inCurve) : 1.0;
      break;
    case KKTimingGraphSectionMid:
      easedT = 1.0;
      break;
    case KKTimingGraphSectionOut:
      easedT = enabled ? KKApplyEasing(1.0 - rawT, _outCurve) : 1.0;
      break;
    }

    CGFloat normalized = (range > 0) ? (easedT - minVal) / range : easedT;
    CGFloat px = x0 + rawT * w;
    CGFloat py = yBottom + normalized * (yTop - yBottom);

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

- (void)renderTicks {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat tickPad = kTickWidth / 2.0;
  CGFloat tickAreaWidth = NSWidth(self.bounds) - 2 * inset;
  if (tickAreaWidth < 1)
    return;

  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(tickAreaWidth, kTickHeight)];
  [image lockFocus];

  CGFloat sliderWidth = tickAreaWidth - 2 * tickPad;
  CGFloat knobInset = 9.5 / 2.0;
  CGFloat usableWidth = sliderWidth - 2 * knobInset;
  KKEasingCurve activeCurve = (KKEasingCurve)lround(_curveSlider.doubleValue);

  BOOL isOut = _selectedSection == KKTimingGraphSectionOut;
  for (NSInteger i = 0; i < KKEasingCurveCount; i++) {
    CGFloat frac = (CGFloat)i / (CGFloat)(KKEasingCurveCount - 1);
    CGFloat centerX = tickPad + knobInset + frac * usableWidth;
    NSRect tickRect =
        NSMakeRect(centerX - kTickWidth / 2.0, 0, kTickWidth, kTickHeight);
    [self renderTickCurve:(KKEasingCurve)i
                   inRect:tickRect
                   active:(i == activeCurve)
                 mirrored:isOut];
  }

  [image unlockFocus];
  _tickImageView.image = image;
}

- (NSRect)tickHitRectForIndex:(NSInteger)index {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat tickPad = kTickWidth / 2.0;
  CGFloat sliderWidth = NSWidth(self.bounds) - 2 * inset - 2 * tickPad;
  CGFloat knobInset = 9.5 / 2.0;
  CGFloat usableWidth = sliderWidth - 2 * knobInset;
  CGFloat tickY = kGraphHeight + kLabelRowHeight + kSliderRowHeight;

  CGFloat frac = (CGFloat)index / (CGFloat)(KKEasingCurveCount - 1);
  CGFloat centerX = inset + tickPad + knobInset + frac * usableWidth;
  return NSMakeRect(centerX - kTickWidth / 2.0, tickY, kTickWidth, kTickHeight);
}

- (void)renderTickCurve:(KKEasingCurve)curve
                 inRect:(NSRect)rect
                 active:(BOOL)active
               mirrored:(BOOL)mirrored {
  NSColor *color =
      active ? [NSColor accent]
             : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  [color setStroke];

  CGFloat pad = 2.0;
  CGFloat x0 = NSMinX(rect) + pad;
  CGFloat x1 = NSMaxX(rect) - pad;
  CGFloat yBot = NSMinY(rect) + pad;
  CGFloat yTop = NSMaxY(rect) - pad;
  CGFloat w = x1 - x0;

  // Find the full range of the curve to scale it to fit
  CGFloat minVal = 0.0, maxVal = 1.0;
  for (NSInteger i = 0; i <= kTickSegments; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)kTickSegments;
    CGFloat eased =
        mirrored ? KKApplyEasing(1.0 - t, curve) : KKApplyEasing(t, curve);
    if (eased < minVal)
      minVal = eased;
    if (eased > maxVal)
      maxVal = eased;
  }
  CGFloat range = maxVal - minVal;
  CGFloat h = yTop - yBot;

  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineWidth = active ? 1.5 : 1.0;

  for (NSInteger i = 0; i <= kTickSegments; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)kTickSegments;
    CGFloat eased =
        mirrored ? KKApplyEasing(1.0 - t, curve) : KKApplyEasing(t, curve);
    CGFloat normalized = (eased - minVal) / range;
    CGFloat px = x0 + t * w;
    CGFloat py = yBot + normalized * h;

    if (i == 0)
      [path moveToPoint:NSMakePoint(px, py)];
    else
      [path lineToPoint:NSMakePoint(px, py)];
  }

  [path stroke];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

  if (!_curveSlider.hidden) {
    for (NSInteger i = 0; i < KKEasingCurveCount; i++) {
      if (NSPointInRect(loc, [self tickHitRectForIndex:i])) {
        _curveSlider.doubleValue = i;
        [self curveSliderChanged:_curveSlider];
        return;
      }
    }
  }

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
