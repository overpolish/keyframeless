/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPillToggleRowView.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import <AppKit/AppKit.h>

static const CGFloat kPillHeight = 18.0;
static const CGFloat kPillSpacing = 2.0;
static const CGFloat kPillPadX = 5.0;
static const CGFloat kPillIconSize = 10.0;
static const CGFloat kPillIconGap = 3.0;
static const CGFloat kGroupTrackInset = 2.0;
static const CGFloat kGroupPillHeight = 22.0;
static const CGFloat kGroupPillPadX = 8.0;

@implementation KKPillToggleRowView {
  NSArray<NSString *> *_labels;
  NSArray<NSImage *> *_icons;
  BOOL _iconAndLabel;
  NSInteger _count;
  BOOL _dragActive;      // a sweep is in progress
  BOOL _dragTargetState; // every pill the sweep touches is set to this
  NSMutableIndexSet *_swept;
}

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _labels = [labels copy];
    _count = labels.count;
    [self _initStates];
  }
  return self;
}

- (instancetype)initWithIcons:(NSArray<NSImage *> *)icons {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _icons = [icons copy];
    _count = icons.count;
    [self _initStates];
  }
  return self;
}

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels
                         icons:(NSArray<NSImage *> *)icons {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _labels = [labels copy];
    _icons = [icons copy];
    _iconAndLabel = YES;
    _count = labels.count;
    [self _initStates];
  }
  return self;
}

- (void)_initStates {
  NSMutableArray *s = [NSMutableArray arrayWithCapacity:_count];
  for (NSInteger i = 0; i < _count; i++)
    [s addObject:@YES];
  _states = [s copy];
}

- (BOOL)isFlipped {
  return YES;
}

- (CGFloat)pillSpacing {
  return _grouped ? 0.0 : kPillSpacing;
}

- (CGFloat)currentPillHeight {
  return _grouped ? kGroupPillHeight : kPillHeight;
}

- (CGFloat)currentPillPadX {
  return _grouped ? kGroupPillPadX : kPillPadX;
}

- (NSSize)intrinsicContentSize {
  CGFloat w = 0;
  CGFloat spacing = [self pillSpacing];
  for (NSInteger i = 0; i < _count; i++)
    w += [self pillWidthForIndex:i] + (i > 0 ? spacing : 0);
  return NSMakeSize(w, [self currentPillHeight]);
}

- (void)setState:(BOOL)on atIndex:(NSInteger)index {
  if (index < 0 || index >= _count)
    return;
  NSMutableArray *s = [_states mutableCopy];
  s[index] = @(on);
  _states = [s copy];
  [self setNeedsDisplay:YES];
}

- (void)setStates:(NSArray<NSNumber *> *)states {
  if ([_states isEqualToArray:states])
    return;
  _states = [states copy];
  [self setNeedsDisplay:YES];
}

- (NSFont *)pillFont {
  return [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightMedium];
}

- (CGFloat)pillWidthForIndex:(NSInteger)i {
  CGFloat padX = [self currentPillPadX];
  if (_iconAndLabel) {
    NSFont *font = [self pillFont];
    NSDictionary *attrs = @{NSFontAttributeName : font};
    CGFloat textW = ceil([_labels[i] sizeWithAttributes:attrs].width);
    NSImage *icon =
        [_icons[i] imageWithSymbolConfiguration:
                       [NSImageSymbolConfiguration
                           configurationWithPointSize:kPillIconSize
                                               weight:NSFontWeightMedium]];
    CGFloat iconW = ceil(icon.size.width);
    return padX + iconW + kPillIconGap + textW + padX;
  }
  if (_icons) {
    return kPillIconSize + 2 * padX;
  }
  NSFont *font = [self pillFont];
  NSDictionary *attrs = @{NSFontAttributeName : font};
  CGFloat textW = ceil([_labels[i] sizeWithAttributes:attrs].width);
  return textW + 2 * padX;
}

- (NSArray<NSValue *> *)pillRects {
  NSMutableArray<NSValue *> *rects = [NSMutableArray array];

  CGFloat spacing = [self pillSpacing];
  CGFloat h = [self currentPillHeight];
  CGFloat x = 0;
  for (NSInteger i = 0; i < _count; i++) {
    CGFloat w = [self pillWidthForIndex:i];
    [rects addObject:[NSValue valueWithRect:NSMakeRect(x, 0, w, h)]];
    x += w + spacing;
  }

  return rects;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSArray<NSValue *> *rects = [self pillRects];

  if (_grouped) {
    CGFloat h = [self currentPillHeight];
    CGFloat totalW = NSMaxX(rects.lastObject.rectValue);
    NSRect trackRect = NSMakeRect(0, 0, totalW, h);
    CGFloat trackRadius = h / 2.0;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:trackRect
                                                          xRadius:trackRadius
                                                          yRadius:trackRadius];
    [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
    [track fill];
  }

  for (NSInteger i = 0; i < _count; i++) {
    NSRect r = rects[i].rectValue;
    BOOL on = _states[i].boolValue;

    if (_grouped) {
      if (on) {
        CGFloat inset = kGroupTrackInset;
        NSRect hr = NSInsetRect(r, inset, inset);
        CGFloat hr_radius = hr.size.height / 2.0;
        NSBezierPath *highlight =
            [NSBezierPath bezierPathWithRoundedRect:hr
                                            xRadius:hr_radius
                                            yRadius:hr_radius];
        [[[NSColor accentMatchingHost] colorWithAlphaComponent:0.15] setFill];
        [highlight fill];
      }
    } else {
      NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r
                                                         xRadius:KKRadiusMD
                                                         yRadius:KKRadiusMD];
      if (on) {
        [[[NSColor accentMatchingHost] colorWithAlphaComponent:0.15] setFill];
        [bg fill];
      } else {
        [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
        [bg fill];
      }
    }

    NSColor *tint =
        on ? [NSColor accentMatchingHost]
           : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];

    if (_iconAndLabel) {
      NSImage *icon =
          [_icons[i] imageWithSymbolConfiguration:
                         [NSImageSymbolConfiguration
                             configurationWithPointSize:kPillIconSize
                                                 weight:NSFontWeightMedium]];
      NSImage *tinted = [icon copy];
      [tinted lockFocus];
      [tint set];
      NSRectFillUsingOperation(
          NSMakeRect(0, 0, tinted.size.width, tinted.size.height),
          NSCompositingOperationSourceAtop);
      [tinted unlockFocus];
      CGFloat contentX = NSMinX(r) + [self currentPillPadX];
      CGFloat iconY = NSMidY(r) - tinted.size.height / 2.0;
      [tinted drawAtPoint:NSMakePoint(contentX, iconY)
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0];
      NSDictionary *attrs = @{
        NSFontAttributeName : [self pillFont],
        NSForegroundColorAttributeName : tint,
      };
      NSSize textSize = [_labels[i] sizeWithAttributes:attrs];
      CGFloat textX = contentX + tinted.size.width + kPillIconGap;
      CGFloat textY = NSMidY(r) - textSize.height / 2.0;
      [_labels[i] drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];
    } else if (_icons) {
      NSImage *icon =
          [_icons[i] imageWithSymbolConfiguration:
                         [NSImageSymbolConfiguration
                             configurationWithPointSize:kPillIconSize
                                                 weight:NSFontWeightMedium]];
      NSImage *tinted = [icon copy];
      [tinted lockFocus];
      [tint set];
      NSRectFillUsingOperation(
          NSMakeRect(0, 0, tinted.size.width, tinted.size.height),
          NSCompositingOperationSourceAtop);
      [tinted unlockFocus];
      CGFloat iconX = NSMidX(r) - tinted.size.width / 2.0;
      CGFloat iconY = NSMidY(r) - tinted.size.height / 2.0;
      [tinted drawAtPoint:NSMakePoint(iconX, iconY)
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0];
    } else {
      NSDictionary *attrs = @{
        NSFontAttributeName : [self pillFont],
        NSForegroundColorAttributeName : tint,
      };
      NSSize textSize = [_labels[i] sizeWithAttributes:attrs];
      CGFloat textX = NSMidX(r) - textSize.width / 2.0;
      CGFloat textY = NSMidY(r) - textSize.height / 2.0;
      [_labels[i] drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];
    }
  }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (NSRect)guidePillScreenRectAtIndex:(NSInteger)index {
  if (index < 0 || index >= _count)
    return NSZeroRect;
  NSWindow *w = self.window;
  if (!w)
    return NSZeroRect;
  NSArray<NSValue *> *rects = [self pillRects];
  if (index >= (NSInteger)rects.count)
    return NSZeroRect;
  NSRect r = rects[index].rectValue;
  NSRect inWin = [self convertRect:r toView:nil];
  return [w convertRectToScreen:inWin];
}

- (NSInteger)_pillIndexAt:(NSPoint)loc {
  NSArray<NSValue *> *rects = [self pillRects];
  for (NSInteger i = 0; i < (NSInteger)rects.count; i++)
    if (NSPointInRect(loc, rects[i].rectValue))
      return i;
  return NSNotFound;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger i = [self _pillIndexAt:loc];
  if (i == NSNotFound)
    return;

  // Radio: single-select, no sweep / undo bracket (consumer-managed).
  // Clear every other pill so only the picked one ends up on (without this
  // the row drifts to all-on as the user clicks each pill in turn).
  if (_radioMode) {
    if (_states[i].boolValue)
      return;
    NSMutableArray<NSNumber *> *next =
        [NSMutableArray arrayWithCapacity:_count];
    for (NSInteger k = 0; k < _count; k++)
      [next addObject:@(k == i)];
    [self setStates:next];
    if (_onToggled)
      _onToggled(i, YES);
    return;
  }

  // Multi-select: start a sweep. Every pill the drag touches is forced to
  // the start pill's *new* state. onDragBegin/End bracket the whole gesture
  // so the consumer coalesces it to one undo entry (fires for a plain
  // click too - down then up with nothing dragged).
  _dragActive = YES;
  _dragTargetState = !_states[i].boolValue;
  _swept = [NSMutableIndexSet indexSetWithIndex:i];
  if (_onDragBegin)
    _onDragBegin();
  [self setState:_dragTargetState atIndex:i];
  if (_onToggled)
    _onToggled(i, _dragTargetState);
}

- (void)mouseDragged:(NSEvent *)event {
  if (!_dragActive)
    return;
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger i = [self _pillIndexAt:loc];
  if (i == NSNotFound || [_swept containsIndex:i])
    return;
  [_swept addIndex:i];
  if (_states[i].boolValue == _dragTargetState)
    return; // already in the target state - nothing to write
  [self setState:_dragTargetState atIndex:i];
  if (_onToggled)
    _onToggled(i, _dragTargetState);
}

- (void)mouseUp:(NSEvent *)event {
  if (!_dragActive)
    return;
  _dragActive = NO;
  _swept = nil;
  if (_onDragEnd)
    _onDragEnd();
}

@end
