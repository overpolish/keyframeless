/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFGapGraph.h"
@import InspectorControls;
@import MotionTiming;

NSImage *KFTimingMenuGlyph(BOOL addedMotion, NSInteger type) {
  double startValue=addedMotion ? 1 : 0, endValue=1;
  MTDestination poses[2]={
    {.arrival=0,.values=&startValue,.addedMotion=addedMotion ? (MTAddedMotion)type : MTAddedMotionNone},
    {.arrival=1,.duration=addedMotion ? 0 : 1,.values=&endValue,.easing=addedMotion ? MTEasingSmooth : (MTEasing)type}
  };
  NSMutableArray<NSNumber *> *samples=[NSMutableArray new];
  double low=INFINITY,high=-INFINITY;
  for (NSUInteger i=0;i<65;i++) {
    double value=0;
    MTSample(poses,2,1,(double)i/64,&value);
    [samples addObject:@(value)];
    low=fmin(low,value); high=fmax(high,value);
  }
  double span=high-low;
  NSImage *image=[NSImage imageWithSize:NSMakeSize(28,16) flipped:NO drawingHandler:^BOOL(NSRect rect) {
    NSBezierPath *line=[NSBezierPath bezierPath];
    line.lineWidth=1.25;
    line.lineCapStyle=NSLineCapStyleRound;
    line.lineJoinStyle=NSLineJoinStyleRound;
    for (NSUInteger i=0;i<samples.count;i++) {
      double y=span>1e-6 ? (samples[i].doubleValue-low)/span : 0.5;
      NSPoint point=NSMakePoint(2+(NSWidth(rect)-4)*i/(samples.count-1),3+(NSHeight(rect)-6)*y);
      if (i) [line lineToPoint:point]; else [line moveToPoint:point];
    }
    [NSColor.blackColor setStroke]; [line stroke]; return YES;
  }];
  image.template=YES;
  return image;
}

@implementation KFGapGraph
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)scrubEvent:(NSEvent *)event {
  NSRect plot=NSInsetRect(self.bounds,8,8);
  if (NSWidth(plot)<=0 || !self.onScrub) return;
  NSPoint point=[self convertPoint:event.locationInWindow fromView:nil];
  self.onScrub(fmax(0,fmin(1,(point.x-NSMinX(plot))/NSWidth(plot))));
}
- (void)mouseDown:(NSEvent *)event {
  if (self.points.count<2 || !self.onScrub) return;
  self.scrubbing=YES;
  [self scrubEvent:event];
}
- (void)mouseDragged:(NSEvent *)event {
  if (self.scrubbing) [self scrubEvent:event];
}
- (void)mouseUp:(NSEvent *)event {
  if (!self.scrubbing) return;
  [self scrubEvent:event];
  self.scrubbing=NO;
  if (self.onScrubEnd) self.onScrubEnd();
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window) self.scrubbing=NO;
}
- (void)setPoints:(NSArray<NSArray<NSNumber *> *> *)points {
  if (_points == points)
    return;
  _points = [points copy];
  self.curvePaths = nil;
  self.needsDisplay = YES;
}
- (void)setStartFractions:(NSArray<NSNumber *> *)starts {
  if ([_startFractions isEqualToArray:starts]) return;
  _startFractions=[starts copy]; self.curvePaths=nil; self.needsDisplay=YES;
}
- (void)setComponentColors:(NSArray<NSColor *> *)componentColors {
  if([_componentColors isEqualToArray:componentColors]) return;
  _componentColors=[componentColors copy]; self.needsDisplay=YES;
}
- (void)setProgress:(double)progress {
  if (_progress == progress)
    return;
  _progress = progress;
  self.needsDisplay = YES;
}
- (void)prepareCurves {
  if (self.curvePaths && NSEqualRects(self.curveBounds, self.bounds))
    return;
  self.curveBounds = self.bounds;
  NSMutableArray *paths = [NSMutableArray array];
  NSRect plot = NSInsetRect(self.bounds, 8, 8);
  if (self.points.count < 2) {
    self.curvePaths = paths;
    return;
  }
  double low = INFINITY, high = -INFINITY;
  for(NSArray<NSNumber *> *sample in self.points) for(NSNumber *value in sample) {
    low=fmin(low,value.doubleValue); high=fmax(high,value.doubleValue);
  }
  double span = high - low;
  if (span < 1e-6) {
    low -= 0.5;
    span = 1;
  }
  low -= span * 0.08;
  span *= 1.16;
  for (NSUInteger axis = 0; axis < self.points.firstObject.count; axis++) {
    NSBezierPath *line = [NSBezierPath bezierPath];
    line.lineWidth = 1.5;
    for (NSUInteger i = 0; i < self.points.count; i++) {
      double sample = self.points[i][axis].doubleValue;
      NSPoint p = NSMakePoint(
          NSMinX(plot) + NSWidth(plot) * ((axis<self.startFractions.count ? self.startFractions[axis].doubleValue : 0) +
              (1-(axis<self.startFractions.count ? self.startFractions[axis].doubleValue : 0))*i/(self.points.count-1)),
          NSMinY(plot) +
              NSHeight(plot) * (sample - low) / span);
      if (i)
        [line lineToPoint:p];
      else
        [line moveToPoint:p];
    }
    [paths addObject:line];
  }
  self.curvePaths = paths;
}
- (void)drawRect:(NSRect)dirtyRect {
  NSRect plot = NSInsetRect(self.bounds, 8, 8);
  [[NSColor colorWithWhite:0 alpha:0.15] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4
                                   yRadius:4] fill];
  [[NSColor colorWithWhite:1 alpha:0.04] setStroke];
  NSBezierPath *grid = [NSBezierPath bezierPath];
  const CGFloat spacing = 16;
  grid.lineWidth = 0.5;
  for (CGFloat x = NSMinX(plot); x <= NSMaxX(plot); x += spacing) {
    [grid moveToPoint:NSMakePoint(x, NSMinY(plot))];
    [grid lineToPoint:NSMakePoint(x, NSMaxY(plot))];
  }
  for (CGFloat y = NSMinY(plot); y < NSMaxY(plot); y += spacing) {
    [grid moveToPoint:NSMakePoint(NSMinX(plot), y)];
    [grid lineToPoint:NSMakePoint(NSMaxX(plot), y)];
  }
  // Close the top even when the plot height is not a multiple of the grid spacing.
  [grid moveToPoint:NSMakePoint(NSMinX(plot), NSMaxY(plot))];
  [grid lineToPoint:NSMakePoint(NSMaxX(plot), NSMaxY(plot))];
  [grid stroke];
  if (self.points.count < 2)
    return;
  [self prepareCurves];
  for (NSUInteger axis = 0; axis < self.curvePaths.count; axis++) {
    [(axis<self.componentColors.count ? self.componentColors[axis]
           : ICInspectorTokens.accentMatchingHost) setStroke];
    [self.curvePaths[axis] stroke];
    if (self.startFractions.count && self.curvePaths[axis].elementCount) {
      NSBezierPath *path=self.curvePaths[axis];
      NSPoint start,end;
      [path elementAtIndex:0 associatedPoints:&start];
      [path elementAtIndex:path.elementCount-1 associatedPoints:&end];
      [(axis<self.componentColors.count ? self.componentColors[axis] : ICInspectorTokens.accentMatchingHost) setFill];
      for (NSValue *value in @[[NSValue valueWithPoint:start],[NSValue valueWithPoint:end]]) {
        NSPoint point=value.pointValue;
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(point.x-2,point.y-2,4,4)] fill];
      }
    }
  }
  [NSColor.whiteColor setStroke];
  NSBezierPath *cursor = [NSBezierPath bezierPath];
  CGFloat x = NSMinX(plot) + NSWidth(plot) * fmax(0, fmin(1, self.progress));
  [cursor moveToPoint:NSMakePoint(x, NSMinY(plot))];
  [cursor lineToPoint:NSMakePoint(x, NSMaxY(plot))];
  [cursor stroke];
}
@end
