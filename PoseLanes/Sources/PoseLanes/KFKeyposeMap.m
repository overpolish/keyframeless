/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFKeyposeMap.h"
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

@interface KFKeyposeMap ()
@property(nonatomic) NSInteger hoveredIndex;
@property(nonatomic, strong) NSTrackingArea *tracking;
@end

@implementation KFKeyposeMap
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _activeIndex = -1;
    _hoveredIndex = -1;
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

- (void)hoverAtPoint:(NSPoint)point {
  self.hoveredIndex = [self indexAtPoint:point];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.tracking) [self removeTrackingArea:self.tracking];
  self.tracking = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                   NSTrackingActiveAlways | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:self.tracking];
}
- (void)mouseEntered:(NSEvent *)event { [self mouseMoved:event]; }
- (void)mouseMoved:(NSEvent *)event {
  [self hoverAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}
- (void)mouseExited:(NSEvent *)event { self.hoveredIndex = -1; }
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window) self.hoveredIndex = -1;
}
- (void)mouseDown:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger index = [self indexAtPoint:point];
  [self hoverAtPoint:point];
  if (index < 0 || !self.onSelect) return;
  self.onSelect(self.stops[index].time);
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  return self.menuProvider ? self.menuProvider() : [super menuForEvent:event];
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
    [clip appendBezierPath:[self diamondAtX:[self positionForIndex:i]
                                    centerY:centerY
                                     radius:radius + KFKeyposeStroke / 2 + KFKeyposeClearance]];
  clip.windingRule = NSWindingRuleEvenOdd;
  [clip addClip];
  for (NSInteger i = 1; i < count; i++) {
    CGFloat from = [self positionForIndex:i - 1], to = [self positionForIndex:i];
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
    NSBezierPath *diamond = [self diamondAtX:[self positionForIndex:i]
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
    NSString *label = self.stops[i].label;
    if (!label.length) continue;
    BOOL current = i == self.activeIndex || i == self.playheadIndex ||
                   (self.activeIndex > 0 && i == self.activeIndex - 1);
    NSDictionary *attributes = @{
      NSFontAttributeName : font,
      NSForegroundColorAttributeName :
          current ? ICInspectorTokens.labelColor : KFKeyposeDimColor()
    };
    NSSize size = [label sizeWithAttributes:attributes];
    CGFloat x = fmax(0, fmin(NSWidth(self.bounds) - size.width,
                             [self positionForIndex:i] - size.width / 2));
    [label drawAtPoint:NSMakePoint(round(x), 2) withAttributes:attributes];
  }
}
@end
