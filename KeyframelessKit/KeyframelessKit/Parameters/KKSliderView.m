//
//  KKSliderView.m
//  KeyframelessKit
//
//  Created by Dom on 27/02/2026.
//

#import "KKSliderView.h"

#pragma mark - Constants

// Track styling
static const CGFloat kTrackHeight = 2.0;
static const CGFloat kTrackCornerRadius = 1.0; // trackHeight / 2.0

// Knob dimensions
static const CGFloat kKnobWidth = 9.5;
static const CGFloat kKnobHeight = 10.0;
static const CGFloat kKnobCornerRadius = 1.5;
static const CGFloat kKnobPointHeightRatio = 0.5; // Percentage of knob height for the top point
static const CGFloat kKnobOutlineWidth = 0.5;

// Colors (hex values for clarity)
static const CGFloat kTrackBackgroundColor[] = {0x17 / 255.0, 0x17 / 255.0, 0x17 / 255.0}; // #171717
static const CGFloat kTrackFillColor[] = {0x61 / 255.0, 0x68 / 255.0, 0xF5 / 255.0};       // #6168F5 (blue)
static const CGFloat kKnobFillColor[] = {0x80 / 255.0, 0x80 / 255.0, 0x80 / 255.0};        // #808080 (gray)
static const CGFloat kKnobOutlineColor[] = {0x17 / 255.0, 0x17 / 255.0, 0x17 / 255.0};     // #171717

// Curve control points for knob shape
static const CGFloat kKnobPointCurveOffset = 0.5;
static const CGFloat kKnobPointCurveControl = 1.0;
static const CGFloat kKnobSideCurveRatio = 0.3;

static inline NSColor *ColorFromRGB(const CGFloat rgb[3]) {
    return [NSColor colorWithRed:rgb[0] green:rgb[1] blue:rgb[2] alpha:1.0];
}

static inline CGFloat ClampValue(CGFloat value, CGFloat min, CGFloat max) { return fmax(min, fmin(max, value)); }

static inline CGFloat NormalizeValue(double value, double min, double max) {
    return ClampValue((value - min) / (max - min), 0.0, 1.0);
}

@interface KKSliderCell : NSSliderCell
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
    [self drawTrackFill:trackRect];
}

- (NSRect)trackRectForBarRect:(NSRect)barRect {
    CGFloat trackY = NSMidY(barRect) - kTrackHeight / 2.0;
    CGFloat inset = kKnobWidth / 2.0;
    return NSMakeRect(barRect.origin.x + inset, trackY, barRect.size.width - (inset * 2.0), kTrackHeight);
}

- (void)drawTrackBackground:(NSRect)trackRect {
    NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:trackRect
                                                              xRadius:kTrackCornerRadius
                                                              yRadius:kTrackCornerRadius];
    [ColorFromRGB(kTrackBackgroundColor) setFill];
    [trackPath fill];
}

- (void)drawTrackFill:(NSRect)trackRect {
    CGFloat normalizedValue = [self normalizedValue];
    CGFloat filledWidth = trackRect.size.width * normalizedValue;

    NSRect filledRect = NSMakeRect(trackRect.origin.x, trackRect.origin.y, filledWidth, kTrackHeight);
    NSBezierPath *filledPath = [NSBezierPath bezierPathWithRoundedRect:filledRect
                                                               xRadius:kTrackCornerRadius
                                                               yRadius:kTrackCornerRadius];
    [ColorFromRGB(kTrackFillColor) setFill];
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

    // Calculate key positions
    CGFloat left = rect.origin.x;
    CGFloat right = NSMaxX(rect);
    CGFloat top = NSMaxY(rect);
    CGFloat bottom = rect.origin.y;
    CGFloat midX = NSMidX(rect);
    CGFloat pointHeight = kKnobHeight * kKnobPointHeightRatio;
    CGFloat pointBaseY = bottom + (kKnobHeight - pointHeight);

    // Build shield/chevron shape pointing upward (clockwise from bottom-left)
    [path moveToPoint:NSMakePoint(left + kKnobCornerRadius, bottom)];

    // Bottom edge to bottom-right
    [path lineToPoint:NSMakePoint(right - kKnobCornerRadius, bottom)];

    // Bottom-right corner (rounded)
    [path appendBezierPathWithArcFromPoint:NSMakePoint(right, bottom)
                                   toPoint:NSMakePoint(right, bottom + kKnobCornerRadius)
                                    radius:kKnobCornerRadius];

    // Right edge up to point base
    [path lineToPoint:NSMakePoint(right, pointBaseY)];

    // Right side of top point (curved to tip)
    [path curveToPoint:NSMakePoint(midX, top)
         controlPoint1:NSMakePoint(right - kKnobPointCurveOffset, pointBaseY + pointHeight * kKnobSideCurveRatio)
         controlPoint2:NSMakePoint(midX + kKnobPointCurveControl, top - kKnobPointCurveOffset)];

    // Left side of top point (curved from tip)
    [path curveToPoint:NSMakePoint(left, pointBaseY)
         controlPoint1:NSMakePoint(midX - kKnobPointCurveControl, top - kKnobPointCurveOffset)
         controlPoint2:NSMakePoint(left + kKnobPointCurveOffset, pointBaseY + pointHeight * kKnobSideCurveRatio)];

    // Left edge down to corner
    [path lineToPoint:NSMakePoint(left, bottom + kKnobCornerRadius)];

    // Bottom-left corner (rounded)
    [path appendBezierPathWithArcFromPoint:NSMakePoint(left, bottom)
                                   toPoint:NSMakePoint(left + kKnobCornerRadius, bottom)
                                    radius:kKnobCornerRadius];

    [path closePath];
    return path;
}

- (void)fillKnob:(NSBezierPath *)path {
    [ColorFromRGB(kKnobFillColor) setFill];
    [path fill];
}

- (void)strokeKnob:(NSBezierPath *)path {
    [ColorFromRGB(kKnobOutlineColor) setStroke];
    [path setLineWidth:kKnobOutlineWidth];
    [path stroke];
}

- (NSRect)knobRectFlipped:(BOOL)flipped {
    NSRect barRect = [self barRectFlipped:flipped];
    CGFloat normalizedValue = [self normalizedValue];
    CGFloat knobPosition = [self knobPositionForBarRect:barRect normalizedValue:normalizedValue];

    return NSMakeRect(knobPosition - kKnobWidth / 2.0, NSMidY(barRect) - kKnobHeight / 2.0, kKnobWidth, kKnobHeight);
}

- (CGFloat)knobPositionForBarRect:(NSRect)barRect normalizedValue:(CGFloat)normalizedValue {
    CGFloat usableWidth = barRect.size.width - kKnobWidth;
    return barRect.origin.x + (kKnobWidth / 2.0) + (usableWidth * normalizedValue);
}

- (BOOL)startTrackingAt:(NSPoint)startPoint inView:(NSView *)controlView {
    NSRect knobRect = [self knobRectFlipped:NO];

    // If clicking on knob, use default tracking
    if (NSPointInRect(startPoint, knobRect)) {
        return [super startTrackingAt:startPoint inView:controlView];
    }

    // If clicking on track, jump to that position
    [self jumpToPosition:startPoint];
    return [super startTrackingAt:startPoint inView:controlView];
}

- (void)jumpToPosition:(NSPoint)point {
    NSRect barRect = [self barRectFlipped:NO];
    CGFloat usableWidth = barRect.size.width - kKnobWidth;
    CGFloat relativeX = point.x - barRect.origin.x - (kKnobWidth / 2.0);
    CGFloat normalizedValue = ClampValue(relativeX / usableWidth, 0.0, 1.0);

    double newValue = self.minValue + (normalizedValue * (self.maxValue - self.minValue));
    self.doubleValue = newValue;
}

- (CGFloat)normalizedValue {
    return NormalizeValue(self.doubleValue, self.minValue, self.maxValue);
}

@end

@implementation KKSliderView

+ (instancetype)styledSlider {
    return [[KKSliderView alloc] initWithFrame:NSZeroRect];
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupSlider];
    }
    return self;
}

- (void)setupSlider {
    CGFloat numberFieldWidth = [KKNumberField preferredWidth];
    CGFloat numberFieldHeight = 17.0;
    CGFloat spacing = 8.0;

    // Number field on the right with fixed width
    CGFloat numberFieldY = (NSHeight(self.bounds) - numberFieldHeight) / 2.0;
    CGRect numberFieldFrame =
        NSMakeRect(NSWidth(self.bounds) - numberFieldWidth, numberFieldY, numberFieldWidth, numberFieldHeight);
    self.numberField = [[KKNumberField alloc] initWithFrame:numberFieldFrame apiManager:_apiManager];
    self.numberField.suffix = @"%";
    self.numberField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin | NSViewHeightSizable;

    [self addSubview:self.numberField];

    // Slider grows to fill remaining space
    CGRect sliderFrame = NSMakeRect(0, 0, NSWidth(self.bounds) - numberFieldWidth - spacing, NSHeight(self.bounds));
    self.slider = [[NSSlider alloc] initWithFrame:sliderFrame];
    self.slider.cell = [[KKSliderCell alloc] init];
    self.slider.minValue = 0.0;
    self.slider.maxValue = 100.0;
    self.slider.doubleValue = 50.0;
    self.slider.continuous = YES;
    self.slider.sliderType = NSSliderTypeLinear;
    self.slider.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [self addSubview:self.slider];
}

- (void)setMinValue:(double)minValue {
    self.slider.minValue = minValue;
}

- (double)minValue {
    return self.slider.minValue;
}

- (void)setMaxValue:(double)maxValue {
    self.slider.maxValue = maxValue;
}

- (double)maxValue {
    return self.slider.maxValue;
}

- (void)setDoubleValue:(double)doubleValue {
    self.slider.doubleValue = doubleValue;
}

- (double)doubleValue {
    return self.slider.doubleValue;
}

- (void)setContinuous:(BOOL)continuous {
    self.slider.continuous = continuous;
}

- (BOOL)continuous {
    return self.slider.continuous;
}

- (void)setTarget:(id)target {
    self.slider.target = target;
}

- (id)target {
    return self.slider.target;
}

- (void)setAction:(SEL)action {
    self.slider.action = action;
}

- (SEL)action {
    return self.slider.action;
}

@end
