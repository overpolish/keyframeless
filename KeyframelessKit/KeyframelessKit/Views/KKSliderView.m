/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKSliderView.h"
#import "KKHostInfo.h"
#import <AppKit/AppKit.h>

static const CGFloat kTrackHeight = 2.0;
static const CGFloat kTrackCornerRadius = 1.0;

static const CGFloat kKnobWidth = 9.5;
static const CGFloat kKnobHeight = 10.0;
static const CGFloat kKnobCornerRadius = 1.5;
static const CGFloat kKnobPointHeightRatio = 0.5;
static const CGFloat kKnobOutlineWidth = 0.5;

static const CGFloat kKnobPointCurveOffset = 0.5;
static const CGFloat kKnobPointCurveControl = 1.0;
static const CGFloat kKnobSideCurveRatio = 0.3;

static NSColor *sliderTrackBackground(void) {
  if ([KKHostInfo isRunningInFinalCut]) {
    return [NSColor colorWithRed:0x2D / 255.0
                           green:0x2D / 255.0
                            blue:0x2D / 255.0
                           alpha:1.0];
  }
  return [NSColor colorWithRed:0x16 / 255.0
                         green:0x16 / 255.0
                          blue:0x16 / 255.0
                         alpha:1.0];
}

static NSColor *sliderKnobFill(void) {
  return [NSColor colorWithRed:0x80 / 255.0
                         green:0x80 / 255.0
                          blue:0x80 / 255.0
                         alpha:1.0];
}

static NSColor *sliderKnobOutline(void) {
  return [NSColor colorWithRed:0x14 / 255.0
                         green:0x14 / 255.0
                          blue:0x14 / 255.0
                         alpha:1.0];
}

static inline CGFloat ClampValue(CGFloat value, CGFloat min, CGFloat max) {
  return fmax(min, fmin(max, value));
}

static inline CGFloat NormalizeValue(double value, double min, double max) {
  return ClampValue((value - min) / (max - min), 0.0, 1.0);
}

@interface KKSliderCell : NSSliderCell
@property(nonatomic, strong, nullable) NSColor *trackFillColor;
/// Piecewise scale break. When scaleBreakValue > 0, the range
/// [minValue, scaleBreakValue] occupies the first scaleBreakPosition fraction
/// of the track, and [scaleBreakValue, maxValue] occupies the rest.
@property(nonatomic) double scaleBreakValue;
@property(nonatomic) double scaleBreakPosition;
@end

@implementation KKSliderCell

- (instancetype)init {
  self = [super init];
  if (self) {
    self.sliderType = NSSliderTypeLinear;
  }
  return self;
}

- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
  NSRect trackRect = [self trackRectForBarRect:rect];
  [self drawTrackBackground:trackRect];
  if (_trackFillColor)
    [self drawTrackFill:trackRect];
}

- (NSRect)trackRectForBarRect:(NSRect)barRect {
  CGFloat trackY = NSMidY(barRect) - kTrackHeight / 2.0;
  CGFloat inset = kKnobWidth / 2.0;
  return NSMakeRect(barRect.origin.x + inset, trackY,
                    barRect.size.width - (inset * 2.0), kTrackHeight);
}

- (void)drawTrackBackground:(NSRect)trackRect {
  NSBezierPath *trackPath =
      [NSBezierPath bezierPathWithRoundedRect:trackRect
                                      xRadius:kTrackCornerRadius
                                      yRadius:kTrackCornerRadius];
  [sliderTrackBackground() setFill];
  [trackPath fill];
}

- (void)drawTrackFill:(NSRect)trackRect {
  CGFloat normalizedValue = [self normalizedValue];
  CGFloat filledWidth = trackRect.size.width * normalizedValue;
  if (filledWidth < 1.0)
    return;

  NSRect filledRect = NSMakeRect(trackRect.origin.x, trackRect.origin.y,
                                 filledWidth, kTrackHeight);
  NSBezierPath *filledPath =
      [NSBezierPath bezierPathWithRoundedRect:filledRect
                                      xRadius:kTrackCornerRadius
                                      yRadius:kTrackCornerRadius];
  [_trackFillColor setFill];
  [filledPath fill];
}

- (void)drawKnob:(NSRect)knobRect {
  NSRect actualKnobRect = [self centeredKnobRect:knobRect];
  NSBezierPath *knobPath = [self createKnobPath:actualKnobRect];
  [self fillKnob:knobPath];
  [self strokeKnob:knobPath];
}

- (NSRect)centeredKnobRect:(NSRect)knobRect {
  CGFloat knobX = NSMidX(knobRect) - kKnobWidth / 2.0;
  CGFloat knobY = NSMidY(knobRect) - kKnobHeight / 2.0;
  return NSMakeRect(knobX, knobY, kKnobWidth, kKnobHeight);
}

- (NSBezierPath *)createKnobPath:(NSRect)rect {
  NSBezierPath *path = [NSBezierPath bezierPath];

  CGFloat left = rect.origin.x;
  CGFloat right = NSMaxX(rect);
  CGFloat top = NSMaxY(rect);
  CGFloat bottom = rect.origin.y;
  CGFloat midX = NSMidX(rect);
  CGFloat pointHeight = kKnobHeight * kKnobPointHeightRatio;
  CGFloat pointBaseY = bottom + (kKnobHeight - pointHeight);

  [path moveToPoint:NSMakePoint(left + kKnobCornerRadius, bottom)];
  [path lineToPoint:NSMakePoint(right - kKnobCornerRadius, bottom)];

  [path appendBezierPathWithArcFromPoint:NSMakePoint(right, bottom)
                                 toPoint:NSMakePoint(right,
                                                     bottom + kKnobCornerRadius)
                                  radius:kKnobCornerRadius];

  [path lineToPoint:NSMakePoint(right, pointBaseY)];

  [path curveToPoint:NSMakePoint(midX, top)
       controlPoint1:NSMakePoint(right - kKnobPointCurveOffset,
                                 pointBaseY + pointHeight * kKnobSideCurveRatio)
       controlPoint2:NSMakePoint(midX + kKnobPointCurveControl,
                                 top - kKnobPointCurveOffset)];

  [path curveToPoint:NSMakePoint(left, pointBaseY)
       controlPoint1:NSMakePoint(midX - kKnobPointCurveControl,
                                 top - kKnobPointCurveOffset)
       controlPoint2:NSMakePoint(left + kKnobPointCurveOffset,
                                 pointBaseY +
                                     pointHeight * kKnobSideCurveRatio)];

  [path lineToPoint:NSMakePoint(left, bottom + kKnobCornerRadius)];

  [path appendBezierPathWithArcFromPoint:NSMakePoint(left, bottom)
                                 toPoint:NSMakePoint(left + kKnobCornerRadius,
                                                     bottom)
                                  radius:kKnobCornerRadius];

  [path closePath];
  return path;
}

- (void)fillKnob:(NSBezierPath *)path {
  [sliderKnobFill() setFill];
  [path fill];
}

- (void)strokeKnob:(NSBezierPath *)path {
  [sliderKnobOutline() setStroke];
  [path setLineWidth:kKnobOutlineWidth];
  [path stroke];
}

- (NSRect)knobRectFlipped:(BOOL)flipped {
  NSRect barRect = [self barRectFlipped:flipped];
  CGFloat normalizedValue = [self normalizedValue];
  CGFloat knobPosition = [self knobPositionForBarRect:barRect
                                      normalizedValue:normalizedValue];

  return NSMakeRect(knobPosition - kKnobWidth / 2.0,
                    NSMidY(barRect) - kKnobHeight / 2.0, kKnobWidth,
                    kKnobHeight);
}

- (CGFloat)knobPositionForBarRect:(NSRect)barRect
                  normalizedValue:(CGFloat)normalizedValue {
  CGFloat usableWidth = barRect.size.width - kKnobWidth;
  return barRect.origin.x + (kKnobWidth / 2.0) +
         (usableWidth * normalizedValue);
}

- (BOOL)continueTracking:(NSPoint)lastPoint
                      at:(NSPoint)currentPoint
                  inView:(NSView *)controlView {
  if (_scaleBreakValue > 0 && _scaleBreakPosition > 0) {
    [self jumpToPosition:currentPoint];
    [NSApp sendAction:self.action to:self.target from:controlView];
    return YES;
  }
  return [super continueTracking:lastPoint at:currentPoint inView:controlView];
}

- (BOOL)startTrackingAt:(NSPoint)startPoint inView:(NSView *)controlView {
  if (_scaleBreakValue > 0 && _scaleBreakPosition > 0) {
    [self jumpToPosition:startPoint];
    [NSApp sendAction:self.action to:self.target from:controlView];
    return YES;
  }

  NSRect knobRect = [self knobRectFlipped:NO];

  if (NSPointInRect(startPoint, knobRect))
    return [super startTrackingAt:startPoint inView:controlView];

  [self jumpToPosition:startPoint];
  return [super startTrackingAt:startPoint inView:controlView];
}

- (CGFloat)valueToNormalized:(double)value {
  double lo = self.minValue, hi = self.maxValue;
  if (_scaleBreakValue > 0 && _scaleBreakPosition > 0) {
    double bv = _scaleBreakValue, bp = _scaleBreakPosition;
    if (value <= bv)
      return ClampValue(bp * (value - lo) / (bv - lo), 0.0, 1.0);
    return ClampValue(bp + (1.0 - bp) * (value - bv) / (hi - bv), 0.0, 1.0);
  }
  return NormalizeValue(value, lo, hi);
}

- (double)normalizedToValue:(CGFloat)norm {
  double lo = self.minValue, hi = self.maxValue;
  if (_scaleBreakValue > 0 && _scaleBreakPosition > 0) {
    double bv = _scaleBreakValue, bp = _scaleBreakPosition;
    if (norm <= bp)
      return lo + (bv - lo) * (norm / bp);
    return bv + (hi - bv) * ((norm - bp) / (1.0 - bp));
  }
  return lo + (hi - lo) * norm;
}

- (void)jumpToPosition:(NSPoint)point {
  NSRect barRect = [self barRectFlipped:NO];
  CGFloat usableWidth = barRect.size.width - kKnobWidth;
  CGFloat relativeX = point.x - barRect.origin.x - (kKnobWidth / 2.0);
  CGFloat norm = ClampValue(relativeX / usableWidth, 0.0, 1.0);
  self.doubleValue = [self normalizedToValue:norm];
}

- (CGFloat)normalizedValue {
  return [self valueToNormalized:self.doubleValue];
}

@end

@implementation KKSliderView

+ (instancetype)styledSlider {
  return [[KKSliderView alloc] initWithFrame:NSZeroRect];
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _slider = [[NSSlider alloc] init];
    _slider.cell = [[KKSliderCell alloc] init];
    _slider.minValue = 0.0;
    _slider.maxValue = 100.0;
    _slider.doubleValue = 50.0;
    _slider.continuous = YES;
    _slider.sliderType = NSSliderTypeLinear;
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_slider];

    [NSLayoutConstraint activateConstraints:@[
      [_slider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_slider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_slider.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_slider.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
  }
  return self;
}

- (void)setMinValue:(double)minValue {
  _slider.minValue = minValue;
}

- (double)minValue {
  return _slider.minValue;
}

- (void)setMaxValue:(double)maxValue {
  _slider.maxValue = maxValue;
}

- (double)maxValue {
  return _slider.maxValue;
}

- (void)setDoubleValue:(double)doubleValue {
  _slider.doubleValue = doubleValue;
}

- (double)doubleValue {
  return _slider.doubleValue;
}

- (void)setContinuous:(BOOL)continuous {
  _slider.continuous = continuous;
}

- (BOOL)continuous {
  return _slider.continuous;
}

- (void)setTarget:(id)target {
  _slider.target = target;
}

- (id)target {
  return _slider.target;
}

- (void)setAction:(SEL)action {
  _slider.action = action;
}

- (SEL)action {
  return _slider.action;
}

- (void)setTrackFillColor:(NSColor *)trackFillColor {
  ((KKSliderCell *)_slider.cell).trackFillColor = trackFillColor;
  [_slider setNeedsDisplay:YES];
}

- (NSColor *)trackFillColor {
  return ((KKSliderCell *)_slider.cell).trackFillColor;
}

- (void)setScaleBreakValue:(double)scaleBreakValue {
  ((KKSliderCell *)_slider.cell).scaleBreakValue = scaleBreakValue;
  [_slider setNeedsDisplay:YES];
}

- (double)scaleBreakValue {
  return ((KKSliderCell *)_slider.cell).scaleBreakValue;
}

- (void)setScaleBreakPosition:(double)scaleBreakPosition {
  ((KKSliderCell *)_slider.cell).scaleBreakPosition = scaleBreakPosition;
  [_slider setNeedsDisplay:YES];
}

- (double)scaleBreakPosition {
  return ((KKSliderCell *)_slider.cell).scaleBreakPosition;
}

@end
