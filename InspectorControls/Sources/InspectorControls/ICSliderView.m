/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import "ICSliderView.h"
#import "InspectorTokens.h"

static const CGFloat kTrackHeight = 2.0;
static const CGFloat kKnobWidth = 9.5;
static const CGFloat kKnobHeight = 10.0;
static const CGFloat kKnobCornerRadius = 1.5;
static const CGFloat kKnobPointHeightRatio = 0.5;
static const CGFloat kKnobOutlineWidth = 0.5;
static const CGFloat kKnobPointCurveOffset = 0.5;
static const CGFloat kKnobPointCurveControl = 1.0;
static const CGFloat kKnobSideCurveRatio = 0.3;
// AppKit's bar rect includes a small amount of trailing cell space. Keep one
// geometry model for the painted track, thumb travel, and pointer mapping so
// the control remains aligned at both ends of compact inspector rows.
static const CGFloat kTrackLeadingOffset = -0.25;
static const CGFloat kTrackTrailingInset = 4.75;
static const CGFloat kMinimumThumbCenter = 3.75;
static const CGFloat kMaximumThumbTrailingInset = 4.0;

static inline CGFloat ICClamp(CGFloat value, CGFloat low, CGFloat high) {
  return fmax(low, fmin(high, value));
}

@interface ICSliderCell : NSSliderCell
@property(nonatomic, strong, nullable) NSColor *trackFillColor;
- (NSRect)icTrackRectForBarRect:(NSRect)barRect;
- (CGFloat)icThumbCenterForBarRect:(NSRect)barRect normalizedValue:(CGFloat)n;
@property(nonatomic) CGFloat icTrackingOffset;
@end

@interface ICDragSlider : NSSlider
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
@end

@implementation ICSliderCell
- (instancetype)init {
  if ((self = [super init])) self.sliderType = NSSliderTypeLinear;
  return self;
}
- (NSRect)trackRectForBarRect:(NSRect)barRect {
  return [self icTrackRectForBarRect:barRect];
}
- (NSRect)icTrackRectForBarRect:(NSRect)barRect {
  return NSMakeRect(NSMinX(barRect) + kTrackLeadingOffset,
                    NSMidY(barRect) - kTrackHeight / 2.0,
                    MAX(0, NSWidth(barRect) - kTrackTrailingInset - kTrackLeadingOffset), kTrackHeight);
}
- (CGFloat)icThumbCenterForBarRect:(NSRect)barRect normalizedValue:(CGFloat)n {
  CGFloat minX = NSMinX(barRect) + kMinimumThumbCenter;
  CGFloat maxX = MAX(minX, NSMaxX(barRect) - kMaximumThumbTrailingInset - kKnobWidth / 2.0);
  return minX + (maxX - minX) * ICClamp(n, 0, 1);
}
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
  NSRect track = [self trackRectForBarRect:rect];
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:track
                                                         xRadius:1 yRadius:1];
  [ICInspectorTokens.sliderTrackColor setFill]; [path fill];
  CGFloat normalized = self.maxValue > self.minValue
      ? (self.doubleValue - self.minValue) / (self.maxValue - self.minValue) : 0;
  CGFloat knobCenter = [self icThumbCenterForBarRect:rect normalizedValue:normalized];
  CGFloat fillWidth=normalized<=0 ? 0 : normalized>=1 ? NSWidth(track) : ICClamp(knobCenter-NSMinX(track),0,NSWidth(track));
  NSRect fill = NSMakeRect(NSMinX(track), NSMinY(track),fillWidth,NSHeight(track));
  if (NSWidth(fill) > 0) {
    NSBezierPath *fillPath = [NSBezierPath bezierPathWithRoundedRect:fill xRadius:1 yRadius:1];
    [(_trackFillColor ?: ICInspectorTokens.accentMatchingHost) setFill]; [fillPath fill];
  }
}
- (void)drawKnob:(NSRect)knobRect {
  NSRect r = NSMakeRect(NSMidX(knobRect) - kKnobWidth / 2,
                        NSMidY(knobRect) - kKnobHeight / 2,
                        kKnobWidth, kKnobHeight);
  CGFloat left=NSMinX(r), right=NSMaxX(r), top=NSMaxY(r), bottom=NSMinY(r);
  CGFloat midX=NSMidX(r), pointHeight=kKnobHeight*kKnobPointHeightRatio;
  CGFloat pointBaseY=bottom+(kKnobHeight-pointHeight);
  NSBezierPath *p=[NSBezierPath bezierPath];
  [p moveToPoint:NSMakePoint(left+kKnobCornerRadius,bottom)];
  [p lineToPoint:NSMakePoint(right-kKnobCornerRadius,bottom)];
  [p appendBezierPathWithArcFromPoint:NSMakePoint(right,bottom)
                              toPoint:NSMakePoint(right,bottom+kKnobCornerRadius)
                               radius:kKnobCornerRadius];
  [p lineToPoint:NSMakePoint(right,pointBaseY)];
  [p curveToPoint:NSMakePoint(midX,top)
     controlPoint1:NSMakePoint(right-kKnobPointCurveOffset,pointBaseY+pointHeight*kKnobSideCurveRatio)
     controlPoint2:NSMakePoint(midX+kKnobPointCurveControl,top-kKnobPointCurveOffset)];
  [p curveToPoint:NSMakePoint(left,pointBaseY)
     controlPoint1:NSMakePoint(midX-kKnobPointCurveControl,top-kKnobPointCurveOffset)
     controlPoint2:NSMakePoint(left+kKnobPointCurveOffset,pointBaseY+pointHeight*kKnobSideCurveRatio)];
  [p lineToPoint:NSMakePoint(left,bottom+kKnobCornerRadius)];
  [p appendBezierPathWithArcFromPoint:NSMakePoint(left,bottom)
                              toPoint:NSMakePoint(left+kKnobCornerRadius,bottom)
                               radius:kKnobCornerRadius];
  [p closePath];
  [ICInspectorTokens.sliderKnobColor setFill]; [p fill];
  [ICInspectorTokens.sliderKnobOutlineColor setStroke]; p.lineWidth=kKnobOutlineWidth; [p stroke];
}
- (NSRect)knobRectFlipped:(BOOL)flipped {
  NSRect bar = [self barRectFlipped:flipped];
  CGFloat n = self.maxValue > self.minValue
      ? (self.doubleValue-self.minValue)/(self.maxValue-self.minValue) : 0;
  CGFloat x = [self icThumbCenterForBarRect:bar normalizedValue:n];
  return NSMakeRect(x-kKnobWidth/2, NSMidY(bar)-kKnobHeight/2, kKnobWidth, kKnobHeight);
}
- (void)jumpToPoint:(NSPoint)point {
  NSRect bar=[self barRectFlipped:NO];
  CGFloat minX = [self icThumbCenterForBarRect:bar normalizedValue:0];
  CGFloat maxX = [self icThumbCenterForBarRect:bar normalizedValue:1];
  CGFloat n=(maxX>minX) ? (point.x-minX)/(maxX-minX) : 0;
  self.doubleValue=self.minValue+(self.maxValue-self.minValue)*ICClamp(n,0,1);
}
- (void)icSendActionFromView:(NSView *)view {
  if (self.action)
    [NSApp sendAction:self.action to:self.target from:view];
}
- (BOOL)startTrackingAt:(NSPoint)p inView:(NSView *)view {
  double previous=self.doubleValue;
  NSRect knob=[self knobRectFlipped:NO];
  self.icTrackingOffset = NSPointInRect(p, knob) ? p.x - NSMidX(knob) : 0;
  if (!NSPointInRect(p, knob)) [self jumpToPoint:p];
  // Own pointer mapping as the legacy slider did for its custom scale;
  // AppKit continues to own the surrounding mouse tracking lifecycle.
  if(self.doubleValue!=previous) [self icSendActionFromView:view];
  return YES;
}
- (BOOL)continueTracking:(NSPoint)lastPoint at:(NSPoint)currentPoint inView:(NSView *)view {
  double previous=self.doubleValue;
  [self jumpToPoint:NSMakePoint(currentPoint.x-self.icTrackingOffset,currentPoint.y)];
  if(self.doubleValue!=previous) [self icSendActionFromView:view];
  return YES;
}
@end

@implementation ICDragSlider
- (void)mouseDown:(NSEvent *)event {
  if (!self.enabled) return;
  if (self.onDragBegin) self.onDragBegin();
  @try {
    [super mouseDown:event];
  } @finally {
    if (self.onDragEnd) self.onDragEnd();
  }
}
@end

@implementation ICSliderView
+ (instancetype)styledSlider { return [[self alloc] initWithFrame:NSZeroRect]; }
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self=[super initWithFrame:frame])) {
    ICDragSlider *slider=[[ICDragSlider alloc] initWithFrame:NSZeroRect];
    slider.cell=[[ICSliderCell alloc] init]; slider.minValue=0; slider.maxValue=100;
    slider.doubleValue=100; slider.continuous=YES; slider.sliderType=NSSliderTypeLinear;
    slider.translatesAutoresizingMaskIntoConstraints=NO;
    __weak typeof(self) weakSelf=self;
    slider.onDragBegin=^{ if (weakSelf.onDragBegin) weakSelf.onDragBegin(); };
    slider.onDragEnd=^{ if (weakSelf.onDragEnd) weakSelf.onDragEnd(); };
    _slider=slider; [self addSubview:slider];
    [NSLayoutConstraint activateConstraints:@[
      [slider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [slider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [slider.topAnchor constraintEqualToAnchor:self.topAnchor],
      [slider.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
  }
  return self;
}
- (double)minValue { return self.slider.minValue; }
- (void)setMinValue:(double)v { self.slider.minValue=v; }
- (double)maxValue { return self.slider.maxValue; }
- (void)setMaxValue:(double)v { self.slider.maxValue=v; }
- (double)doubleValue { return self.slider.doubleValue; }
- (void)setDoubleValue:(double)v { self.slider.doubleValue=ICClamp(v,self.minValue,self.maxValue); }
- (BOOL)continuous { return self.slider.continuous; }
- (void)setContinuous:(BOOL)v { self.slider.continuous=v; }
- (BOOL)enabled { return self.slider.enabled; }
- (void)setEnabled:(BOOL)v { self.slider.enabled=v; }
- (id)target { return self.slider.target; }
- (void)setTarget:(id)v { self.slider.target=v; }
- (SEL)action { return self.slider.action; }
- (void)setAction:(SEL)v { self.slider.action=v; }
- (void)setTrackFillColor:(NSColor *)v { ((ICSliderCell *)self.slider.cell).trackFillColor=v; [self.slider setNeedsDisplay:YES]; }
- (NSColor *)trackFillColor { return ((ICSliderCell *)self.slider.cell).trackFillColor; }
@end
