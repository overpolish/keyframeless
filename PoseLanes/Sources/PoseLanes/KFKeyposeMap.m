/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFKeyposeMap_Private.h"
@import InspectorControls;

// Host geometry and states, measured from Final Cut's inspector keyframe
// marker: an 11pt diamond that never changes size, hollow until it is the one
// being edited, and flat grey under the pointer whatever it was showing.
static const CGFloat KFKeyposeBead = 11;
static const CGFloat KFKeyposeStroke = 1;
// Rails and the playhead stop short of a keypose instead of crossing it.
static const CGFloat KFKeyposeClearance = 1;
static const CGFloat KFKeyposeHitSlop = 3;
static const CGFloat KFKeyposeLabelHeight = 12;
static const CGFloat KFKeyposeInset = 8;

// The timecodes are supporting information, not a reading of the curve.
static NSFont *KFKeyposeLabelFont(void) {
  return [NSFont systemFontOfSize:9 weight:NSFontWeightLight];
}

static NSColor *KFKeyposeHoverColor(void) {
  return [NSColor colorWithSRGBRed:0xB2 / 255.0 green:0xB2 / 255.0 blue:0xB2 / 255.0 alpha:1];
}
static NSColor *KFKeyposeActiveColor(void) {
  return [NSColor colorWithSRGBRed:1 green:0xC3 / 255.0 blue:0 alpha:1];
}
static NSColor *KFKeyposeIdleColor(void) {
  return [NSColor colorWithSRGBRed:0x95 / 255.0 green:0x95 / 255.0 blue:0x95 / 255.0 alpha:1];
}
// Everything outside the gap being edited is drawn disabled. The map sits under
// the graph with the same horizontal extent, and at equal weight it reads as
// that graph's axis rather than as a separate map of the whole lane. Hover
// still lifts a keypose, so quiet does not mean unreachable.
static NSColor *KFKeyposeDimColor(void) { return ICInspectorTokens.disabledTextColor; }

@implementation KFKeyposeStop
- (BOOL)isEqual:(id)other {
  if (other == self) return YES;
  if (![other isKindOfClass:KFKeyposeStop.class]) return NO;
  KFKeyposeStop *stop = other;
  return CMTimeCompare(_time, stop.time) == 0 && _transitionFraction == stop.transitionFraction &&
         (_label == stop.label || [_label isEqualToString:stop.label]) &&
         (_linkColor == stop.linkColor || [_linkColor isEqual:stop.linkColor]);
}
- (NSUInteger)hash { return (NSUInteger)CMTimeGetSeconds(_time) ^ _label.hash; }
@end

@implementation KFKeyposeMap
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _activeIndex = -1;
    _hoveredIndex = -1;
    _dragIndex = -1;
    _pressedIndex = -1;
    _playheadIndex = -1;
    _playheadFraction = -1;
  }
  return self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 30); }

- (void)setStops:(NSArray<KFKeyposeStop *> *)stops {
  if (_stops == stops || [_stops isEqualToArray:stops]) return;
  _stops = [stops copy];
  self.needsDisplay = YES;
}
- (void)setActiveIndex:(NSInteger)activeIndex {
  if (_activeIndex == activeIndex) return;
  _activeIndex = activeIndex;
  self.needsDisplay = YES;
}
- (void)setPlayheadIndex:(NSInteger)playheadIndex {
  if (_playheadIndex == playheadIndex) return;
  _playheadIndex = playheadIndex;
  self.needsDisplay = YES;
}
- (void)setPlayheadFraction:(double)fraction {
  if (_playheadFraction == fraction) return;
  _playheadFraction = fraction;
  self.needsDisplay = YES;
}
- (void)setSourceHighlighted:(BOOL)highlighted {
  if (_sourceHighlighted == highlighted) return;
  _sourceHighlighted = highlighted;
  self.needsDisplay = YES;
}
- (void)setHoveredIndex:(NSInteger)hoveredIndex {
  if (_hoveredIndex == hoveredIndex) return;
  _hoveredIndex = hoveredIndex;
  self.needsDisplay = YES;
}
- (void)setDragIndex:(NSInteger)dragIndex {
  if (_dragIndex == dragIndex) return;
  _dragIndex = dragIndex;
  self.needsDisplay = YES;
}
- (void)setDragPosition:(CGFloat)dragPosition {
  if (_dragPosition == dragPosition) return;
  _dragPosition = dragPosition;
  self.needsDisplay = YES;
}
- (void)setDragLabel:(NSString *)dragLabel {
  if (_dragLabel == dragLabel || [_dragLabel isEqualToString:dragLabel]) return;
  _dragLabel = [dragLabel copy];
  self.needsDisplay = YES;
}
- (void)endDrag {
  self.pressedIndex = -1;
  self.dragIndex = -1;
  self.dragLabel = nil;
}

- (CGFloat)centerYForBead {
  return KFKeyposeLabelHeight + (NSHeight(self.bounds) - KFKeyposeLabelHeight) / 2;
}
- (CGFloat)positionForIndex:(NSInteger)index {
  CGFloat content = MAX(0, NSWidth(self.bounds) - 2 * KFKeyposeInset);
  if (self.stops.count < 2) return KFKeyposeInset;
  return KFKeyposeInset + content * index / (CGFloat)(self.stops.count - 1);
}
- (NSInteger)indexAtPoint:(NSPoint)point {
  if (self.stops.count < 2) return -1;
  CGFloat centerY = [self centerYForBead];
  CGFloat reach = KFKeyposeBead / 2 + KFKeyposeHitSlop;
  if (fabs(point.y - centerY) > reach) return -1;
  // Nearest bead within reach, so adjacent hit areas cannot overlap-steal.
  NSInteger best = -1;
  CGFloat bestDistance = reach;
  for (NSInteger i = 0; i < (NSInteger)self.stops.count; i++) {
    CGFloat distance = fabs(point.x - [self positionForIndex:i]);
    if (distance <= bestDistance) {
      best = i;
      bestDistance = distance;
    }
  }
  return best;
}
// While a keypose is dragged it leaves its ordinal slot and the rails either
// side of it reflow, so the corridor it is being retimed in is what moves.
- (CGFloat)drawnPositionForIndex:(NSInteger)index {
  return index == self.dragIndex ? self.dragPosition : [self positionForIndex:index];
}
- (double)fractionAtX:(CGFloat)x {
  CGFloat content = MAX(0, NSWidth(self.bounds) - 2 * KFKeyposeInset);
  if (content <= 0) return 0;
  return fmax(0, fmin(1, (x - KFKeyposeInset) / content));
}
- (BOOL)isScrubPoint:(NSPoint)point {
  return self.stops.count > 1 && point.y >= KFKeyposeLabelHeight;
}
- (CGFloat)draggablePosition:(CGFloat)x forIndex:(NSInteger)index {
  NSInteger last = (NSInteger)self.stops.count - 1;
  if (index < 0 || index > last || last < 1) return x;
  return fmax([self positionForIndex:MAX(0, index - 1)],
              fmin([self positionForIndex:MIN(last, index + 1)], x));
}
static CMTime KFKeyposeLerp(CMTime from, CMTime to, double fraction) {
  if (fraction <= 0) return from;
  if (fraction >= 1) return to;
  return CMTimeAdd(from,
                   CMTimeMultiplyByFloat64(CMTimeSubtract(to, from), fraction));
}
- (CMTime)timeAtPosition:(CGFloat)x forIndex:(NSInteger)index {
  NSInteger last = (NSInteger)self.stops.count - 1;
  if (index < 0 || index > last) return kCMTimeInvalid;
  CGFloat here = [self positionForIndex:index];
  if (x < here && index > 0) {
    CGFloat from = [self positionForIndex:index - 1];
    return KFKeyposeLerp(self.stops[index - 1].time, self.stops[index].time,
                         here > from ? (x - from) / (here - from) : 1);
  }
  if (x > here && index < last) {
    CGFloat to = [self positionForIndex:index + 1];
    return KFKeyposeLerp(self.stops[index].time, self.stops[index + 1].time,
                         to > here ? (x - here) / (to - here) : 0);
  }
  return self.stops[index].time;
}
// The time any rail position falls on, for the gap it lands in rather than a
// keypose's corridor. Invalid until the lane has two keyposes to span.
- (CMTime)timeAtPosition:(CGFloat)x {
  NSInteger last = (NSInteger)self.stops.count - 1;
  if (last < 1) return kCMTimeInvalid;
  double position = [self fractionAtX:x] * last;
  NSInteger index = (NSInteger)fmin(last - 1, floor(position));
  return KFKeyposeLerp(self.stops[index].time, self.stops[index + 1].time,
                       position - (double)index);
}

- (void)hoverAtPoint:(NSPoint)point {
  self.hoveredIndex = [self indexAtPoint:point];
}

// Amber marks exactly what the panel's controls write: the transition into the
// active keypose, that keypose, and any other pose currently receiving an edit.
// A link group substitutes its own tint, since an edit there travels to the
// group's other properties, dimmed where that keypose is not being edited so
// group identity survives without competing with the active gap.
- (NSColor *)colorForIndex:(NSInteger)index filled:(BOOL)filled {
  if (index == self.hoveredIndex) return KFKeyposeHoverColor();
  NSColor *link = self.stops[index].linkColor;
  if (filled) return link ?: KFKeyposeActiveColor();
  return link ? [link colorWithAlphaComponent:0.5] : KFKeyposeDimColor();
}
- (BOOL)isFilledIndex:(NSInteger)index {
  if (index == self.playheadIndex) return YES;
  // A filled diamond is the keypose being edited, so it follows the playhead.
  // Standing on a keypose the active gap does not arrive at, which is what the
  // first keypose of a lane always does, the gap keeps its transition highlight
  // but its arrival stays unfilled: the playhead is not on it.
  BOOL displaced = self.playheadIndex >= 0 && self.playheadIndex != self.activeIndex;
  if (!displaced && index == self.activeIndex) return YES;
  return self.sourceHighlighted && self.activeIndex > 0 && index == self.activeIndex - 1;
}
- (NSBezierPath *)diamondAtX:(CGFloat)x centerY:(CGFloat)centerY radius:(CGFloat)radius {
  NSBezierPath *diamond = [NSBezierPath bezierPath];
  [diamond moveToPoint:NSMakePoint(x, centerY + radius)];
  [diamond lineToPoint:NSMakePoint(x + radius, centerY)];
  [diamond lineToPoint:NSMakePoint(x, centerY - radius)];
  [diamond lineToPoint:NSMakePoint(x - radius, centerY)];
  [diamond closePath];
  return diamond;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSInteger count = (NSInteger)self.stops.count;
  CGFloat centerY = [self centerYForBead];
  CGFloat content = MAX(0, NSWidth(self.bounds) - 2 * KFKeyposeInset);
  CGFloat radius = (KFKeyposeBead - KFKeyposeStroke) / 2;

  // Nothing keyed yet: the rail alone, so the panel keeps its shape and the
  // map reads as empty rather than missing.
  if (count < 2) {
    [[KFKeyposeDimColor() colorWithAlphaComponent:0.6] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(KFKeyposeInset, centerY - 1, content, 2)
                                     xRadius:1
                                     yRadius:1] fill];
    return;
  }

  // Rails and the playhead are clipped out of every bead, so a hollow keypose
  // stays hollow instead of being crossed by what it sits on.
  [NSGraphicsContext saveGraphicsState];
  NSBezierPath *clip = [NSBezierPath bezierPathWithRect:self.bounds];
  for (NSInteger i = 0; i < count; i++)
    [clip appendBezierPath:[self diamondAtX:[self drawnPositionForIndex:i]
                                    centerY:centerY
                                     radius:radius + KFKeyposeStroke / 2 + KFKeyposeClearance]];
  clip.windingRule = NSWindingRuleEvenOdd;
  [clip addClip];
  for (NSInteger i = 1; i < count; i++) {
    CGFloat from = [self drawnPositionForIndex:i - 1], to = [self drawnPositionForIndex:i];
    double fraction = fmax(0, fmin(1, self.stops[i].transitionFraction));
    CGFloat split = to - (to - from) * fraction;
    NSColor *hue = self.stops[i].linkColor ?: KFKeyposeActiveColor();
    BOOL active = i == self.activeIndex;
    if (split > from) {
      [(active ? [KFKeyposeIdleColor() colorWithAlphaComponent:0.35]
               : [KFKeyposeDimColor() colorWithAlphaComponent:0.6]) setFill];
      [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(from, centerY - 1, split - from, 2)
                                       xRadius:1
                                       yRadius:1] fill];
    }
    if (to > split) {
      [(active ? hue : KFKeyposeDimColor()) setFill];
      [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(split, centerY - 2, to - split, 4)
                                       xRadius:2
                                       yRadius:2] fill];
    }
  }
  if (self.playheadFraction >= 0) {
    CGFloat x = KFKeyposeInset + content * fmin(1, self.playheadFraction);
    [[NSColor colorWithWhite:1 alpha:0.55] setFill];
    NSRectFill(NSMakeRect(round(x) - 0.5, centerY - KFKeyposeBead / 2 - 2, 1, KFKeyposeBead + 4));
  }
  [NSGraphicsContext restoreGraphicsState];

  for (NSInteger i = 0; i < count; i++) {
    NSBezierPath *diamond = [self diamondAtX:[self drawnPositionForIndex:i]
                                     centerY:centerY
                                      radius:radius];
    diamond.lineWidth = KFKeyposeStroke;
    BOOL filled = [self isFilledIndex:i];
    NSColor *color = [self colorForIndex:i filled:filled];
    [color setStroke];
    if (filled) {
      [color setFill];
      [diamond fill];
    }
    [diamond stroke];
  }

  NSFont *font = KFKeyposeLabelFont();
  for (NSInteger i = 0; i < count; i++) {
    BOOL dragged = i == self.dragIndex;
    NSString *label = dragged ? self.dragLabel : self.stops[i].label;
    if (!label.length) continue;
    BOOL current = dragged || i == self.activeIndex || i == self.playheadIndex ||
                   (self.activeIndex > 0 && i == self.activeIndex - 1);
    NSDictionary *attributes = @{
      NSFontAttributeName : font,
      NSForegroundColorAttributeName :
          current ? ICInspectorTokens.labelColor : KFKeyposeDimColor()
    };
    NSSize size = [label sizeWithAttributes:attributes];
    CGFloat x = fmax(0, fmin(NSWidth(self.bounds) - size.width,
                             [self drawnPositionForIndex:i] - size.width / 2));
    [label drawAtPoint:NSMakePoint(round(x), 2) withAttributes:attributes];
  }
}
@end
