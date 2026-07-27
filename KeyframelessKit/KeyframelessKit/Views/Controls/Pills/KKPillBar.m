/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPillBar.h"
#import "KKPillToggleRowView.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kEdgeW = 16.0; // overflow-shadow gradient width

// Draw-only, hit-transparent edge fade so the scrolled-out pills read as
// "more, scroll for it" without intercepting clicks/drags on the pills.
@interface _KKPillEdgeShadow : NSView
@end
@implementation _KKPillEdgeShadow
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation KKPillBar {
  NSScrollView *_scroll;
  KKPillToggleRowView *_row;
  _KKPillEdgeShadow *_leftShadow;
  _KKPillEdgeShadow *_rightShadow;
  CAGradientLayer *_leftGrad;
  CAGradientLayer *_rightGrad;
}

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels {
  return [self
      initWithPillRow:[[KKPillToggleRowView alloc] initWithLabels:labels]];
}

- (instancetype)initWithPillRow:(KKPillToggleRowView *)row {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _row = row;
    // The row is framed manually as the scroll's documentView.
    _row.translatesAutoresizingMaskIntoConstraints = YES;

    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.drawsBackground = NO;
    _scroll.hasHorizontalScroller = NO;
    _scroll.hasVerticalScroller = NO;
    _scroll.horizontalScrollElasticity = NSScrollElasticityAllowed;
    _scroll.verticalScrollElasticity = NSScrollElasticityNone;
    _scroll.documentView = _row;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [self addSubview:_scroll];

    _leftShadow = [_KKPillEdgeShadow new];
    _rightShadow = [_KKPillEdgeShadow new];
    for (_KKPillEdgeShadow *s in @[ _leftShadow, _rightShadow ]) {
      s.wantsLayer = YES;
      [self addSubview:s];
    }
    NSColor *c0 = [[NSColor blackColor] colorWithAlphaComponent:0.3];
    id opaque = (__bridge id)c0.CGColor;
    id clear = (__bridge id)[NSColor clearColor].CGColor;
    _leftGrad = [CAGradientLayer layer];
    _leftGrad.colors = @[ opaque, clear ];
    _leftGrad.startPoint = CGPointMake(0, 0.5);
    _leftGrad.endPoint = CGPointMake(1, 0.5);
    _leftShadow.layer = _leftGrad;
    _rightGrad = [CAGradientLayer layer];
    _rightGrad.colors = @[ clear, opaque ];
    _rightGrad.startPoint = CGPointMake(0, 0.5);
    _rightGrad.endPoint = CGPointMake(1, 0.5);
    _rightShadow.layer = _rightGrad;
    // Layer-hosting views ignore NSView.alphaValue - drive the gradient
    // layer's opacity directly so the shadows actually hide at offset 0.
    _leftGrad.opacity = 0.0;
    _rightGrad.opacity = 0.0;

    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_scrolled)
               name:NSViewBoundsDidChangeNotification
             object:_scroll.contentView];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSSize)intrinsicContentSize {
  // Hug the pill content so the bar can be right-aligned by Auto Layout
  // (label-left / control-right, matching the rest of the popover). When
  // the host pins it narrower than this, `layout` falls back to scrolling.
  NSSize s = _row.intrinsicContentSize;
  // Never advertise more than the host can give: an over-wide intrinsic
  // inflates the host's fitting width (see maxIntrinsicWidth).
  if (_maxIntrinsicWidth > 0)
    s.width = MIN(s.width, _maxIntrinsicWidth);
  return s;
}

- (void)setMaxIntrinsicWidth:(CGFloat)maxIntrinsicWidth {
  if (fabs(_maxIntrinsicWidth - maxIntrinsicWidth) < 0.5)
    return;
  _maxIntrinsicWidth = maxIntrinsicWidth;
  [self invalidateIntrinsicContentSize];
  self.needsLayout = YES;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)layout {
  [super layout];
  _scroll.frame = self.bounds;
  NSSize clip = _scroll.contentSize;
  CGFloat rowW = MAX(_row.intrinsicContentSize.width, clip.width);
  _row.frame = NSMakeRect(0, 0, rowW, clip.height);
  // _leftGrad / _rightGrad are the shadow views' backing layers - the view
  // frame setter syncs their geometry. Setting the gradient layer's frame
  // again would clobber that with bounds (origin 0,0), collapsing the right
  // shadow's layer onto the left edge.
  _leftShadow.frame = NSMakeRect(0, 0, kEdgeW, NSHeight(self.bounds));
  _rightShadow.frame = NSMakeRect(NSWidth(self.bounds) - kEdgeW, 0, kEdgeW,
                                  NSHeight(self.bounds));
  [self _scrolled];
}

- (void)_scrolled {
  CGFloat docW = NSWidth(_row.frame);
  CGFloat visW = _scroll.contentView.bounds.size.width;
  CGFloat offX = _scroll.contentView.bounds.origin.x;
  CGFloat scrollable = docW - visW;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (scrollable <= 0.5) {
    _leftGrad.opacity = 0.0;
    _rightGrad.opacity = 0.0;
  } else {
    _leftGrad.opacity = (float)MAX(0.0, MIN(1.0, offX / kEdgeW));
    _rightGrad.opacity =
        (float)MAX(0.0, MIN(1.0, (scrollable - offX) / kEdgeW));
  }
  [CATransaction commit];
}

- (void)setStates:(NSArray<NSNumber *> *)states {
  _row.states = states;
}
- (NSArray<NSNumber *> *)states {
  return _row.states;
}
- (void)setState:(BOOL)on atIndex:(NSInteger)index {
  [_row setState:on atIndex:index];
}
- (void)setGrouped:(BOOL)grouped {
  _row.grouped = grouped;
  [self invalidateIntrinsicContentSize];
  self.needsLayout = YES;
}
- (BOOL)grouped {
  return _row.grouped;
}
- (void)setOnToggled:(void (^)(NSInteger, BOOL))onToggled {
  _row.onToggled = onToggled;
}
- (void (^)(NSInteger, BOOL))onToggled {
  return _row.onToggled;
}
- (void)setOnDragBegin:(void (^)(void))onDragBegin {
  _row.onDragBegin = onDragBegin;
}
- (void (^)(void))onDragBegin {
  return _row.onDragBegin;
}
- (void)setOnDragEnd:(void (^)(void))onDragEnd {
  _row.onDragEnd = onDragEnd;
}
- (void (^)(void))onDragEnd {
  return _row.onDragEnd;
}

@end
