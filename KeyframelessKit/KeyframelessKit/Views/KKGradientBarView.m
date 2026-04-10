/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKGradientBarView.h"
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

static const CGFloat kBarHeight = 14.0;
static const CGFloat kStopDiameter = 10.0;
static const CGFloat kStopHitRadius = 8.0;
static const CGFloat kDeleteDragDistance = 30.0;
static const NSInteger kMinStops = 2;
static const CGFloat kMidpointSize = 7.0;
static const CGFloat kMidpointHitRadius = 6.0;

@implementation KKGradientStop

+ (instancetype)stopWithPosition:(CGFloat)position color:(NSColor *)color {
  return [self stopWithPosition:position color:color midpoint:0.5];
}

+ (instancetype)stopWithPosition:(CGFloat)position
                           color:(NSColor *)color
                        midpoint:(CGFloat)midpoint {
  KKGradientStop *stop = [[KKGradientStop alloc] init];
  stop.position = position;
  stop.color = color;
  stop.midpoint = midpoint;
  return stop;
}

- (instancetype)init {
  self = [super init];
  if (self)
    _midpoint = 0.5;
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  return [KKGradientStop stopWithPosition:_position
                                    color:[_color copy]
                                 midpoint:_midpoint];
}

@end

void KKDrawCheckerboard(NSRect rect) {
  NSColor *light = [NSColor colorWithWhite:0.8 alpha:1.0];
  NSColor *dark = [NSColor colorWithWhite:0.5 alpha:1.0];
  CGFloat checkSize = 4.0;
  for (CGFloat y = rect.origin.y; y < NSMaxY(rect); y += checkSize) {
    for (CGFloat x = rect.origin.x; x < NSMaxX(rect); x += checkSize) {
      BOOL isLight = ((int)(x / checkSize) + (int)(y / checkSize)) % 2 == 0;
      [isLight ? light : dark setFill];
      NSRectFill(NSMakeRect(x, y, checkSize, checkSize));
    }
  }
}

@implementation KKGradientBarView {
  NSInteger _dragIndex;
  NSInteger _dragMidpointIndex; // sorted index of midpoint being dragged
  BOOL _dragStarted;
  NSPoint _dragOrigin;
  NSInteger _colorPickerStopIndex;
  BOOL _ignoreNextColorPanel;
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _stops = @[
      [KKGradientStop stopWithPosition:0.0 color:[NSColor whiteColor]],
      [KKGradientStop stopWithPosition:1.0 color:[NSColor whiteColor]]
    ];
    _selectedIndex = 0;
    _selectedMidpointIndex = -1;
    _dragIndex = -1;
    _dragMidpointIndex = -1;
    _interactionEnabled = YES;
  }
  return self;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window) {
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    [panel setTarget:nil];
    [panel setAction:nil];
  }
}

- (BOOL)isFlipped {
  return YES;
}

- (NSRect)_barRect {
  CGFloat y = kStopDiameter * 0.5;
  return NSMakeRect(kStopDiameter * 0.5, y,
                    self.bounds.size.width - kStopDiameter, kBarHeight);
}

- (CGFloat)_xForPosition:(CGFloat)position {
  NSRect bar = [self _barRect];
  return bar.origin.x + position * bar.size.width;
}

- (CGFloat)_positionForX:(CGFloat)x {
  NSRect bar = [self _barRect];
  CGFloat p = (x - bar.origin.x) / bar.size.width;
  return fmax(0.0, fmin(1.0, p));
}

- (void)drawRect:(NSRect)dirtyRect {
  NSRect bar = [self _barRect];
  NSBezierPath *barClip = [NSBezierPath bezierPathWithRoundedRect:bar
                                                          xRadius:KKRadiusSM
                                                          yRadius:KKRadiusSM];

  // Checkerboard background for transparency
  [NSGraphicsContext saveGraphicsState];
  [barClip addClip];
  KKDrawCheckerboard(bar);
  [NSGraphicsContext restoreGraphicsState];

  // Gradient fill
  NSMutableArray<KKGradientStop *> *sorted = [[_stops
      sortedArrayUsingComparator:^(KKGradientStop *a, KKGradientStop *b) {
        if (a.position < b.position)
          return NSOrderedAscending;
        if (a.position > b.position)
          return NSOrderedDescending;
        return NSOrderedSame;
      }] mutableCopy];

  if (sorted.count >= 2) {
    NSMutableArray<NSColor *> *colors = [NSMutableArray new];
    NSMutableArray<NSNumber *> *locs = [NSMutableArray new];
    for (NSUInteger i = 0; i < sorted.count; i++) {
      [colors addObject:sorted[i].color];
      [locs addObject:@(sorted[i].position)];
      if (i < sorted.count - 1) {
        CGFloat m = sorted[i].midpoint;
        CGFloat midPos = sorted[i].position +
                         m * (sorted[i + 1].position - sorted[i].position);
        NSColor *midColor =
            [sorted[i].color blendedColorWithFraction:0.5
                                              ofColor:sorted[i + 1].color];
        [colors addObject:midColor];
        [locs addObject:@(midPos)];
      }
    }
    CGFloat *locations = malloc(sizeof(CGFloat) * locs.count);
    for (NSUInteger i = 0; i < locs.count; i++)
      locations[i] = locs[i].doubleValue;

    NSGradient *gradient =
        [[NSGradient alloc] initWithColors:colors
                               atLocations:locations
                                colorSpace:[NSColorSpace sRGBColorSpace]];
    free(locations);

    NSBezierPath *barPath = [NSBezierPath bezierPathWithRoundedRect:bar
                                                            xRadius:KKRadiusSM
                                                            yRadius:KKRadiusSM];
    [gradient drawInBezierPath:barPath angle:0];
  }

  // Bar border
  [[NSColor.inspectorLabel colorWithAlphaComponent:0.2] setStroke];
  NSBezierPath *borderPath =
      [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bar, 0.5, 0.5)
                                      xRadius:KKRadiusSM
                                      yRadius:KKRadiusSM];
  borderPath.lineWidth = KKBorderWidthXS;
  [borderPath stroke];

  // Stop handles
  for (NSInteger i = 0; i < (NSInteger)_stops.count; i++) {
    KKGradientStop *stop = _stops[i];
    CGFloat x = [self _xForPosition:stop.position];
    CGFloat y = NSMaxY(bar) + KKSpacingXS;

    NSRect handleRect =
        NSMakeRect(x - kStopDiameter * 0.5, y, kStopDiameter, kStopDiameter);

    // Color swatch
    [stop.color setFill];
    NSBezierPath *handle =
        [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(handleRect, 1, 1)];
    [handle fill];

    // Handle border
    NSColor *borderColor =
        (i == _selectedIndex)
            ? [NSColor accentMatchingHost]
            : [NSColor.inspectorLabel colorWithAlphaComponent:0.4];
    [borderColor setStroke];
    NSBezierPath *ring = [NSBezierPath
        bezierPathWithOvalInRect:NSInsetRect(handleRect, 0.5, 0.5)];
    ring.lineWidth = (i == _selectedIndex) ? KKBorderWidthSM : KKBorderWidthXS;
    [ring stroke];
  }

  // Midpoint diamonds
  for (NSUInteger i = 0; i < sorted.count - 1; i++) {
    CGFloat m = sorted[i].midpoint;
    CGFloat midPos =
        sorted[i].position + m * (sorted[i + 1].position - sorted[i].position);
    CGFloat mx = [self _xForPosition:midPos];
    CGFloat my = NSMaxY(bar) + KKSpacingXS + kStopDiameter * 0.5;
    CGFloat half = kMidpointSize * 0.5;

    NSBezierPath *diamond = [NSBezierPath bezierPath];
    [diamond moveToPoint:NSMakePoint(mx, my - half)];
    [diamond lineToPoint:NSMakePoint(mx + half, my)];
    [diamond lineToPoint:NSMakePoint(mx, my + half)];
    [diamond lineToPoint:NSMakePoint(mx - half, my)];
    [diamond closePath];

    BOOL selected = ((NSInteger)i == _selectedMidpointIndex);
    [[NSColor.inspectorLabel colorWithAlphaComponent:selected ? 0.6 : 0.3]
        setFill];
    [diamond fill];

    NSColor *dmBorder =
        selected ? [NSColor accentMatchingHost]
                 : [NSColor.inspectorLabel colorWithAlphaComponent:0.4];
    [dmBorder setStroke];
    diamond.lineWidth = selected ? KKBorderWidthSM : KKBorderWidthXS;
    [diamond stroke];
  }
}

- (NSInteger)_stopIndexAtPoint:(NSPoint)point {
  NSRect bar = [self _barRect];
  for (NSInteger i = (NSInteger)_stops.count - 1; i >= 0; i--) {
    CGFloat x = [self _xForPosition:_stops[i].position];
    CGFloat y = NSMaxY(bar) + KKSpacingXS + kStopDiameter * 0.5;
    CGFloat dist = hypot(point.x - x, point.y - y);
    if (dist <= kStopHitRadius)
      return i;
  }
  return -1;
}

- (NSArray<KKGradientStop *> *)_sortedStops {
  return [_stops
      sortedArrayUsingComparator:^(KKGradientStop *a, KKGradientStop *b) {
        if (a.position < b.position)
          return NSOrderedAscending;
        if (a.position > b.position)
          return NSOrderedDescending;
        return NSOrderedSame;
      }];
}

- (NSInteger)_midpointIndexAtPoint:(NSPoint)point {
  NSRect bar = [self _barRect];
  NSArray<KKGradientStop *> *sorted = [self _sortedStops];
  CGFloat cy = NSMaxY(bar) + KKSpacingXS + kStopDiameter * 0.5;
  for (NSUInteger i = 0; i < sorted.count - 1; i++) {
    CGFloat m = sorted[i].midpoint;
    CGFloat midPos =
        sorted[i].position + m * (sorted[i + 1].position - sorted[i].position);
    CGFloat mx = [self _xForPosition:midPos];
    CGFloat dist = hypot(point.x - mx, point.y - cy);
    if (dist <= kMidpointHitRadius)
      return (NSInteger)i;
  }
  return -1;
}

- (void)resetCursorRects {
  if (!_interactionEnabled) {
    [self addCursorRect:self.bounds
                 cursor:[NSCursor operationNotAllowedCursor]];
  }
}

- (void)setInteractionEnabled:(BOOL)interactionEnabled {
  _interactionEnabled = interactionEnabled;
  [self.window invalidateCursorRectsForView:self];
}

- (void)mouseDown:(NSEvent *)event {
  if (!_interactionEnabled)
    return;
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger hitIndex = [self _stopIndexAtPoint:point];

  if (event.clickCount == 2 && hitIndex >= 0) {
    [self _selectIndex:hitIndex];
    [self _openColorPickerForStopAtIndex:hitIndex];
    return;
  }

  if (hitIndex >= 0) {
    _dragIndex = hitIndex;
    _dragMidpointIndex = -1;
    _dragStarted = NO;
    _dragOrigin = point;
    _selectedMidpointIndex = -1;
    [self _selectIndex:hitIndex];
    if ([NSColorPanel sharedColorPanel].visible)
      [self _openColorPickerForStopAtIndex:hitIndex];
    return;
  }

  NSInteger midHit = [self _midpointIndexAtPoint:point];
  if (event.clickCount == 2 && midHit >= 0) {
    NSArray<KKGradientStop *> *sorted = [self _sortedStops];
    KKGradientStop *owner = sorted[midHit];
    NSInteger origIdx = [_stops indexOfObjectIdenticalTo:owner];
    if (origIdx != NSNotFound)
      [self setMidpoint:0.5 forStopAtIndex:origIdx];
    return;
  }
  if (midHit >= 0) {
    _dragMidpointIndex = midHit;
    _dragIndex = -1;
    _dragStarted = NO;
    _dragOrigin = point;
    _selectedMidpointIndex = midHit;
    [self _selectIndex:-1];
    [self setNeedsDisplay:YES];
    return;
  }

  NSRect bar = [self _barRect];
  if (NSPointInRect(point, NSInsetRect(bar, 0, -kStopDiameter))) {
    _selectedMidpointIndex = -1;
    CGFloat pos = [self _positionForX:point.x];
    [self _addStopAtPosition:pos];
  }
}

- (void)mouseDragged:(NSEvent *)event {
  if (_dragIndex < 0 && _dragMidpointIndex < 0)
    return;

  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];

  if (!_dragStarted) {
    if (hypot(point.x - _dragOrigin.x, point.y - _dragOrigin.y) < 3.0)
      return;
    _dragStarted = YES;
  }

  if (_dragMidpointIndex >= 0) {
    NSArray<KKGradientStop *> *sorted = [self _sortedStops];
    NSUInteger idx = (NSUInteger)_dragMidpointIndex;
    if (idx >= sorted.count - 1)
      return;
    KKGradientStop *lo = sorted[idx];
    KKGradientStop *hi = sorted[idx + 1];
    CGFloat segLen = hi.position - lo.position;
    if (segLen <= 0)
      return;
    CGFloat pos = [self _positionForX:point.x];
    CGFloat m = (pos - lo.position) / segLen;
    m = fmax(0.05, fmin(0.95, m));
    NSInteger origIdx = [_stops indexOfObjectIdenticalTo:lo];
    if (origIdx == NSNotFound)
      return;
    NSMutableArray *mutable = [_stops mutableCopy];
    mutable[origIdx] = [KKGradientStop stopWithPosition:lo.position
                                                  color:lo.color
                                               midpoint:m];
    _stops = [mutable copy];
    [self setNeedsDisplay:YES];
    if (_onStopsChanged)
      _onStopsChanged(_stops);
    return;
  }

  NSRect bar = [self _barRect];
  CGFloat verticalDist = fabs(point.y - (NSMaxY(bar) + kStopDiameter * 0.5));

  if (verticalDist > kDeleteDragDistance &&
      (NSInteger)_stops.count > kMinStops) {
    [self _removeStopAtIndex:_dragIndex];
    _dragIndex = -1;
    return;
  }

  CGFloat pos = [self _positionForX:point.x];
  NSMutableArray *mutable = [_stops mutableCopy];
  mutable[_dragIndex] =
      [KKGradientStop stopWithPosition:pos
                                 color:_stops[_dragIndex].color
                              midpoint:_stops[_dragIndex].midpoint];
  _stops = [mutable copy];
  [self setNeedsDisplay:YES];
  if (_onStopsChanged)
    _onStopsChanged(_stops);
}

- (void)mouseUp:(NSEvent *)event {
  _dragIndex = -1;
  _dragMidpointIndex = -1;
  _dragStarted = NO;
}

- (void)rightMouseDown:(NSEvent *)event {
  if (!_interactionEnabled)
    return;
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger hitIndex = [self _stopIndexAtPoint:point];
  if (hitIndex < 0)
    return;

  NSArray<KKGradientStop *> *sorted = [self _sortedStops];
  KKGradientStop *hitStop = _stops[hitIndex];
  NSInteger sortedIdx = [sorted indexOfObjectIdenticalTo:hitStop];
  if (sortedIdx == NSNotFound)
    return;

  CGFloat newPos;
  if (sortedIdx == 0) {
    newPos = 0.0;
  } else if (sortedIdx == (NSInteger)sorted.count - 1) {
    newPos = 1.0;
  } else {
    newPos =
        (sorted[sortedIdx - 1].position + sorted[sortedIdx + 1].position) * 0.5;
  }

  [self setPosition:newPos forStopAtIndex:hitIndex];
}

- (void)_openColorPickerForStopAtIndex:(NSInteger)index {
  if (!self.window)
    return;

  _colorPickerStopIndex = index;
  _ignoreNextColorPanel = YES;

  NSColorPanel *panel = [NSColorPanel sharedColorPanel];
  panel.target = self;
  panel.action = @selector(_stopColorPanelChanged:);
  panel.continuous = YES;
  panel.color = _stops[index].color;

  if (panel.parentWindow != self.window) {
    [panel.parentWindow removeChildWindow:panel];
    [self.window addChildWindow:panel ordered:NSWindowAbove];
  }

  [panel orderFront:nil];
  _ignoreNextColorPanel = NO;
}

- (void)_stopColorPanelChanged:(NSColorPanel *)panel {
  if (_ignoreNextColorPanel)
    return;
  if (_colorPickerStopIndex < 0 ||
      _colorPickerStopIndex >= (NSInteger)_stops.count)
    return;
  if (!self.window)
    return;
  [self setColor:panel.color forStopAtIndex:_colorPickerStopIndex];
}

- (void)_selectIndex:(NSInteger)index {
  if (_selectedIndex == index)
    return;
  _selectedIndex = index;
  [self setNeedsDisplay:YES];
  if (_onSelectionChanged)
    _onSelectionChanged(index);
}

- (void)_addStopAtPosition:(CGFloat)position {
  NSColor *color = [self _interpolatedColorAtPosition:position];
  KKGradientStop *newStop = [KKGradientStop stopWithPosition:position
                                                       color:color];

  NSMutableArray *mutable = [_stops mutableCopy];
  [mutable addObject:newStop];
  _stops = [mutable copy];

  NSInteger newIndex = (NSInteger)_stops.count - 1;
  _selectedIndex = newIndex;
  [self setNeedsDisplay:YES];
  if (_onStopsChanged)
    _onStopsChanged(_stops);
  if (_onSelectionChanged)
    _onSelectionChanged(newIndex);
}

- (void)_removeStopAtIndex:(NSInteger)index {
  if ((NSInteger)_stops.count <= kMinStops)
    return;

  NSMutableArray *mutable = [_stops mutableCopy];
  [mutable removeObjectAtIndex:index];
  _stops = [mutable copy];

  if (_selectedIndex >= (NSInteger)_stops.count)
    _selectedIndex = (NSInteger)_stops.count - 1;
  if (_selectedIndex == index)
    _selectedIndex = MAX(0, index - 1);

  [self setNeedsDisplay:YES];
  if (_onStopsChanged)
    _onStopsChanged(_stops);
  if (_onSelectionChanged)
    _onSelectionChanged(_selectedIndex);
}

- (NSColor *)_interpolatedColorAtPosition:(CGFloat)position {
  NSArray<KKGradientStop *> *sorted = [_stops
      sortedArrayUsingComparator:^(KKGradientStop *a, KKGradientStop *b) {
        if (a.position < b.position)
          return NSOrderedAscending;
        if (a.position > b.position)
          return NSOrderedDescending;
        return NSOrderedSame;
      }];

  if (sorted.count == 0)
    return [NSColor whiteColor];
  if (position <= sorted.firstObject.position)
    return sorted.firstObject.color;
  if (position >= sorted.lastObject.position)
    return sorted.lastObject.color;

  for (NSUInteger i = 0; i < sorted.count - 1; i++) {
    KKGradientStop *a = sorted[i];
    KKGradientStop *b = sorted[i + 1];
    if (position >= a.position && position <= b.position) {
      CGFloat t = (position - a.position) / (b.position - a.position);
      CGFloat m = a.midpoint;
      if (m > 0.0 && m < 1.0) {
        if (t <= m)
          t = 0.5 * (t / m);
        else
          t = 0.5 + 0.5 * ((t - m) / (1.0 - m));
      }
      return [a.color blendedColorWithFraction:t ofColor:b.color];
    }
  }
  return sorted.lastObject.color;
}

- (void)setColor:(NSColor *)color forStopAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)_stops.count)
    return;
  NSMutableArray *mutable = [_stops mutableCopy];
  mutable[index] = [KKGradientStop stopWithPosition:_stops[index].position
                                              color:color
                                           midpoint:_stops[index].midpoint];
  _stops = [mutable copy];
  [self setNeedsDisplay:YES];
  if (_onStopsChanged)
    _onStopsChanged(_stops);
}

- (void)setPosition:(CGFloat)position forStopAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)_stops.count)
    return;
  position = fmax(0.0, fmin(1.0, position));
  NSMutableArray *mutable = [_stops mutableCopy];
  mutable[index] = [KKGradientStop stopWithPosition:position
                                              color:_stops[index].color
                                           midpoint:_stops[index].midpoint];
  _stops = [mutable copy];
  [self setNeedsDisplay:YES];
  if (_onStopsChanged)
    _onStopsChanged(_stops);
}

- (void)setMidpoint:(CGFloat)midpoint forStopAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)_stops.count)
    return;
  midpoint = fmax(0.05, fmin(0.95, midpoint));
  NSMutableArray *mutable = [_stops mutableCopy];
  mutable[index] = [KKGradientStop stopWithPosition:_stops[index].position
                                              color:_stops[index].color
                                           midpoint:midpoint];
  _stops = [mutable copy];
  [self setNeedsDisplay:YES];
  if (_onStopsChanged)
    _onStopsChanged(_stops);
}

- (void)setStops:(NSArray<KKGradientStop *> *)stops {
  _stops = [stops copy];
  if (_selectedIndex >= (NSInteger)_stops.count)
    _selectedIndex = MAX(0, (NSInteger)_stops.count - 1);
  [self setNeedsDisplay:YES];
}

@end
