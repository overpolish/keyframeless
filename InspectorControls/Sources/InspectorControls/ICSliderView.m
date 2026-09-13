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

static inline CGFloat ICClamp(CGFloat value, CGFloat low, CGFloat high) {
  return fmax(low, fmin(high, value));
}

@interface ICSliderCell : NSSliderCell
@property(nonatomic, strong, nullable) NSColor *trackFillColor;
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
  CGFloat inset = kKnobWidth / 2.0;
  return NSMakeRect(NSMinX(barRect) + inset,
                    NSMidY(barRect) - kTrackHeight / 2.0,
                    MAX(0, NSWidth(barRect) - inset * 2.0), kTrackHeight);
}
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
  NSRect track = [self trackRectForBarRect:rect];
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:track
                                                         xRadius:1 yRadius:1];
  [ICInspectorTokens.sliderTrackColor setFill]; [path fill];
  CGFloat normalized = self.maxValue > self.minValue
      ? (self.doubleValue - self.minValue) / (self.maxValue - self.minValue) : 0;
  NSRect fill = NSMakeRect(NSMinX(track), NSMinY(track), NSWidth(track) * ICClamp(normalized, 0, 1), NSHeight(track));
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
  CGFloat usable = MAX(0, NSWidth(bar) - kKnobWidth);
  CGFloat n = self.maxValue > self.minValue
      ? (self.doubleValue-self.minValue)/(self.maxValue-self.minValue) : 0;
  CGFloat x = NSMinX(bar)+kKnobWidth/2+usable*ICClamp(n,0,1);
  return NSMakeRect(x-kKnobWidth/2, NSMidY(bar)-kKnobHeight/2, kKnobWidth, kKnobHeight);
}
- (void)jumpToPoint:(NSPoint)point {
  NSRect bar=[self barRectFlipped:NO];
  CGFloat usable=NSWidth(bar)-kKnobWidth;
  CGFloat n=usable>0 ? (point.x-NSMinX(bar)-kKnobWidth/2)/usable : 0;
  self.doubleValue=self.minValue+(self.maxValue-self.minValue)*ICClamp(n,0,1);
}
- (BOOL)startTrackingAt:(NSPoint)p inView:(NSView *)view {
  if (!NSPointInRect(p, [self knobRectFlipped:NO])) [self jumpToPoint:p];
  return [super startTrackingAt:p inView:view];
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
