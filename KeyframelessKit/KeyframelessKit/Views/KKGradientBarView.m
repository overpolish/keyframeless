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

@implementation KKGradientStop

+ (instancetype)stopWithPosition:(CGFloat)position color:(NSColor *)color {
  KKGradientStop *stop = [[KKGradientStop alloc] init];
  stop.position = position;
  stop.color = color;
  return stop;
}

- (id)copyWithZone:(NSZone *)zone {
  return [KKGradientStop stopWithPosition:_position color:[_color copy]];
}

@end

void KKDrawCheckerboard(NSRect rect) {
  NSColor *light = [NSColor colorWithWhite:0.8 alpha:1.0];
  NSColor *dark = [NSColor colorWithWhite:0.5 alpha:1.0];
  CGFloat checkSize = 4.0;
  for (CGFloat y = rect.origin.y; y < NSMaxY(rect); y += checkSize) {
    for (CGFloat x = rect.origin.x; x < NSMaxX(rect); x += checkSize) {
      BOOL isLight =
          ((int)(x / checkSize) + (int)(y / checkSize)) % 2 == 0;
      [isLight ? light : dark setFill];
      NSRectFill(NSMakeRect(x, y, checkSize, checkSize));
    }
  }
}

@implementation KKGradientBarView {
  NSInteger _dragIndex;
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
    _dragIndex = -1;
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
  NSBezierPath *barClip =
      [NSBezierPath bezierPathWithRoundedRect:bar
                                      xRadius:KKRadiusSM
                                      yRadius:KKRadiusSM];

  // Checkerboard background for transparency
  [NSGraphicsContext saveGraphicsState];
  [barClip addClip];
  KKDrawCheckerboard(bar);
  [NSGraphicsContext restoreGraphicsState];

  // Gradient fill
  NSMutableArray<KKGradientStop *> *sorted =
      [[_stops sortedArrayUsingComparator:^(KKGradientStop *a,
                                            KKGradientStop *b) {
        if (a.position < b.position) return NSOrderedAscending;
        if (a.position > b.position) return NSOrderedDescending;
        return NSOrderedSame;
      }] mutableCopy];

  if (sorted.count >= 2) {
    CGFloat *locations = malloc(sizeof(CGFloat) * sorted.count);
    for (NSUInteger i = 0; i < sorted.count; i++)
      locations[i] = sorted[i].position;

    NSGradient *gradient = [[NSGradient alloc]
        initWithColors:[sorted valueForKey:@"color"]
           atLocations:locations
            colorSpace:[NSColorSpace sRGBColorSpace]];
    free(locations);

    NSBezierPath *barPath =
        [NSBezierPath bezierPathWithRoundedRect:bar
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
        NSMakeRect(x - kStopDiameter * 0.5, y,
                   kStopDiameter, kStopDiameter);

    // Color swatch
    [stop.color setFill];
    NSBezierPath *handle =
        [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(handleRect, 1, 1)];
    [handle fill];

    // Handle border
    NSColor *borderColor = (i == _selectedIndex)
                               ? [NSColor accentMatchingHost]
                               : [NSColor.inspectorLabel
                                     colorWithAlphaComponent:0.4];
    [borderColor setStroke];
    NSBezierPath *ring =
        [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(handleRect, 0.5, 0.5)];
    ring.lineWidth = (i == _selectedIndex) ? KKBorderWidthSM : KKBorderWidthXS;
    [ring stroke];
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

- (void)resetCursorRects {
  if (!_interactionEnabled) {
    [self addCursorRect:self.bounds cursor:[NSCursor operationNotAllowedCursor]];
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
    _dragStarted = NO;
    _dragOrigin = point;
    [self _selectIndex:hitIndex];
  } else {
    NSRect bar = [self _barRect];
    if (NSPointInRect(point, NSInsetRect(bar, 0, -kStopDiameter))) {
      CGFloat pos = [self _positionForX:point.x];
      [self _addStopAtPosition:pos];
    }
  }
}

- (void)mouseDragged:(NSEvent *)event {
  if (_dragIndex < 0)
    return;

  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];

  if (!_dragStarted) {
    if (hypot(point.x - _dragOrigin.x, point.y - _dragOrigin.y) < 3.0)
      return;
    _dragStarted = YES;
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
                                 color:_stops[_dragIndex].color];
  _stops = [mutable copy];
  [self setNeedsDisplay:YES];
  if (_onStopsChanged)
    _onStopsChanged(_stops);
}

- (void)mouseUp:(NSEvent *)event {
  _dragIndex = -1;
  _dragStarted = NO;
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
  KKGradientStop *newStop =
      [KKGradientStop stopWithPosition:position color:color];

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
  NSArray<KKGradientStop *> *sorted =
      [_stops sortedArrayUsingComparator:^(KKGradientStop *a,
                                           KKGradientStop *b) {
        if (a.position < b.position) return NSOrderedAscending;
        if (a.position > b.position) return NSOrderedDescending;
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
      return [a.color blendedColorWithFraction:t ofColor:b.color];
    }
  }
  return sorted.lastObject.color;
}

- (void)setColor:(NSColor *)color forStopAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)_stops.count)
    return;
  NSMutableArray *mutable = [_stops mutableCopy];
  mutable[index] =
      [KKGradientStop stopWithPosition:_stops[index].position color:color];
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
  mutable[index] =
      [KKGradientStop stopWithPosition:position color:_stops[index].color];
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
