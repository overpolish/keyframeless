/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPillToggleRowView.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>

static const CGFloat kPillHeight = 18.0;
static const CGFloat kPillSpacing = 2.0;
static const CGFloat kPillPadX = 5.0;
static const CGFloat kPillIconSize = 12.0;
static const CGFloat kPillIconGap = 4.0;
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

- (void)setWarningStates:(NSArray<NSNumber *> *)warningStates {
  if (_warningStates == warningStates ||
      [_warningStates isEqualToArray:warningStates])
    return;
  _warningStates = [warningStates copy];
  [self setNeedsDisplay:YES];
}

- (BOOL)_warningAtIndex:(NSInteger)i {
  return i >= 0 && i < (NSInteger)_warningStates.count &&
         _warningStates[i].boolValue;
}

- (NSFont *)pillFont {
  return [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightMedium];
}

// The icon to draw for segment `i`: an SF Symbol gets the pill's point-size /
// weight applied; a custom-drawn (non-symbol) template image - e.g. the stroke
// Line Cap / Join glyphs - returns nil from imageWithSymbolConfiguration:, so
// fall back to the raw image at its own size.
- (NSImage *)resolvedIconAtIndex:(NSInteger)i {
  NSImage *raw = _icons[i];
  NSImage *sym = [raw
      imageWithSymbolConfiguration:[NSImageSymbolConfiguration
                                       configurationWithPointSize:kPillIconSize
                                                           weight:
                                                               NSFontWeightMedium]];
  return sym ?: raw;
}

- (CGFloat)pillWidthForIndex:(NSInteger)i {
  CGFloat padX = [self currentPillPadX];
  if (_iconAndLabel) {
    NSFont *font = [self pillFont];
    NSDictionary *attrs = @{NSFontAttributeName : font};
    CGFloat textW = ceil([_labels[i] sizeWithAttributes:attrs].width);
    NSImage *icon = [self resolvedIconAtIndex:i];
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

  if (_grouped && !_hidesGroupTrack) {
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
    // A soloed pill reads in the warning tint instead of the accent.
    NSColor *onColor = [self _warningAtIndex:i] ? [NSColor warning]
                                                : [NSColor accentMatchingHost];

    if (_grouped) {
      if (on) {
        CGFloat inset = kGroupTrackInset;
        NSRect hr = NSInsetRect(r, inset, inset);
        CGFloat hr_radius = hr.size.height / 2.0;
        NSBezierPath *highlight =
            [NSBezierPath bezierPathWithRoundedRect:hr
                                            xRadius:hr_radius
                                            yRadius:hr_radius];
        [[onColor colorWithAlphaComponent:0.28] setFill];
        [highlight fill];
      }
    } else {
      NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r
                                                         xRadius:KKRadiusMD
                                                         yRadius:KKRadiusMD];
      if (on) {
        [[onColor colorWithAlphaComponent:0.15] setFill];
        [bg fill];
      } else {
        [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
        [bg fill];
      }
    }

    // Selected reads in the host accent (or warning when soloed); unselected
    // stays legible (not a faint ghost) so multi-pill rows like the category
    // nav are easy to scan.
    NSColor *tint =
        on ? onColor : [[NSColor inspectorLabel] colorWithAlphaComponent:0.6];

    if (_iconAndLabel) {
      NSImage *icon = [self resolvedIconAtIndex:i];
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
      NSImage *icon = [self resolvedIconAtIndex:i];
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

- (NSInteger)pillIndexAtViewPoint:(NSPoint)point {
  return [self _pillIndexAt:point];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger i = [self _pillIndexAt:loc];
  if (i == NSNotFound)
    return;

  // Option-click is a distinct action (the lane filter uses it to solo). Only
  // diverts when a handler is wired, so every other pill keeps normal clicks.
  if ((event.modifierFlags & NSEventModifierFlagOption) && _onOptionToggled) {
    _onOptionToggled(i);
    return;
  }

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

  // Sweep-excluded pill (e.g. a group master): plain toggle, never a drag
  // origin, so dragging off it doesn't paint the whole group.
  if ([_dragExcludedIndices containsIndex:i]) {
    BOOL target = !_states[i].boolValue;
    [self setState:target atIndex:i];
    if (_onToggled)
      _onToggled(i, target);
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
  if (i == NSNotFound) {
    // Cursor left this capsule - let the container continue the paint into a
    // neighbouring capsule at the same target state (cross-capsule sweep).
    if (_onSweepToWindowPoint)
      _onSweepToWindowPoint(event.locationInWindow, _dragTargetState);
    return;
  }
  if ([_swept containsIndex:i] || [_dragExcludedIndices containsIndex:i])
    return; // already painted, or a sweep-excluded master pill
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
