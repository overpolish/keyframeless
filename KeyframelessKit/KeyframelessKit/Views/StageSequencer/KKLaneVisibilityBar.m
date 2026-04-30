/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneVisibilityBar.h"
#import "../../Style/KKTokens.h"
#import "../../Style/NSColor+KKColors.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kBarHeight = 22.0;
static const CGFloat kPillHeight = 18.0;
static const CGFloat kPillSpacing = 4.0;
static const CGFloat kPillPadX = 6.0;
static const CGFloat kEdgeShadowW = 16.0;

@class KKLaneVisibilityPillsView;

@interface KKLaneVisibilityPillsView : NSView
@property(nonatomic, copy) NSArray<NSString *> *labels;
@property(nonatomic, copy) NSArray<NSNumber *> *visibleStates;
@property(nonatomic, copy, nullable) void (^onPillClicked)
    (NSInteger laneIndex, BOOL optionDown);
@property(nonatomic, copy, nullable) void (^onPillDraggedToVisible)
    (NSInteger laneIndex, BOOL visible);
- (CGFloat)intrinsicContentWidth;
@end

@interface KKLaneVisibilityEdgeShadowView : NSView
@end

@implementation KKLaneVisibilityEdgeShadowView
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return NO;
}
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation KKLaneVisibilityBar {
  NSScrollView *_scroll;
  KKLaneVisibilityPillsView *_pills;
  KKLaneVisibilityEdgeShadowView *_leftShadow;
  KKLaneVisibilityEdgeShadowView *_rightShadow;
  id _boundsObserver;
}

+ (CGFloat)preferredHeight {
  return kBarHeight;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _labels = @[];
    _visibleStates = @[];

    _scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.hasVerticalScroller = NO;
    _scroll.hasHorizontalScroller = NO;
    _scroll.drawsBackground = NO;
    _scroll.borderType = NSNoBorder;
    _scroll.horizontalScrollElasticity = NSScrollElasticityAllowed;
    _scroll.verticalScrollElasticity = NSScrollElasticityNone;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [self addSubview:_scroll];

    _pills = [[KKLaneVisibilityPillsView alloc] initWithFrame:NSZeroRect];
    _pills.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.documentView = _pills;

    _leftShadow =
        [[KKLaneVisibilityEdgeShadowView alloc] initWithFrame:NSZeroRect];
    _leftShadow.translatesAutoresizingMaskIntoConstraints = NO;
    _leftShadow.wantsLayer = YES;
    CAGradientLayer *leftGrad = [CAGradientLayer layer];
    leftGrad.colors = @[
      (__bridge id)[NSColor colorWithWhite:0 alpha:0.35].CGColor,
      (__bridge id)[NSColor clearColor].CGColor,
    ];
    leftGrad.startPoint = CGPointMake(0.0, 0.5);
    leftGrad.endPoint = CGPointMake(1.0, 0.5);
    _leftShadow.layer = leftGrad;
    _leftShadow.alphaValue = 0.0;
    [self addSubview:_leftShadow];

    _rightShadow =
        [[KKLaneVisibilityEdgeShadowView alloc] initWithFrame:NSZeroRect];
    _rightShadow.translatesAutoresizingMaskIntoConstraints = NO;
    _rightShadow.wantsLayer = YES;
    CAGradientLayer *rightGrad = [CAGradientLayer layer];
    rightGrad.colors = @[
      (__bridge id)[NSColor clearColor].CGColor,
      (__bridge id)[NSColor colorWithWhite:0 alpha:0.35].CGColor,
    ];
    rightGrad.startPoint = CGPointMake(0.0, 0.5);
    rightGrad.endPoint = CGPointMake(1.0, 0.5);
    _rightShadow.layer = rightGrad;
    _rightShadow.alphaValue = 0.0;
    [self addSubview:_rightShadow];

    [NSLayoutConstraint activateConstraints:@[
      [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

      [_pills.topAnchor constraintEqualToAnchor:_scroll.contentView.topAnchor],
      [_pills.bottomAnchor
          constraintEqualToAnchor:_scroll.contentView.bottomAnchor],
      [_pills.heightAnchor
          constraintEqualToAnchor:_scroll.contentView.heightAnchor],

      [_leftShadow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_leftShadow.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_leftShadow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [_leftShadow.widthAnchor constraintEqualToConstant:kEdgeShadowW],

      [_rightShadow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_rightShadow.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_rightShadow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [_rightShadow.widthAnchor constraintEqualToConstant:kEdgeShadowW],
    ]];

    __weak typeof(self) weakSelf = self;
    _pills.onPillClicked = ^(NSInteger laneIndex, BOOL optionDown) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf && strongSelf->_onPillClicked)
        strongSelf->_onPillClicked(laneIndex, optionDown);
    };
    _pills.onPillDraggedToVisible = ^(NSInteger laneIndex, BOOL visible) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf && strongSelf->_onPillDraggedToVisible)
        strongSelf->_onPillDraggedToVisible(laneIndex, visible);
    };

    _boundsObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSViewBoundsDidChangeNotification
                    object:_scroll.contentView
                     queue:nil
                usingBlock:^(NSNotification *_) {
                  [weakSelf _updateShadows];
                }];
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf _updateShadows];
    });
  }
  return self;
}

- (void)dealloc {
  if (_boundsObserver)
    [[NSNotificationCenter defaultCenter] removeObserver:_boundsObserver];
}

- (void)setLabels:(NSArray<NSString *> *)labels {
  _labels = [labels copy];
  _pills.labels = _labels;
  [self invalidateIntrinsicContentSize];
  [self _updateShadows];
}

- (void)setVisibleStates:(NSArray<NSNumber *> *)visibleStates {
  _visibleStates = [visibleStates copy];
  _pills.visibleStates = _visibleStates;
}

- (void)layout {
  [super layout];
  [self _updateShadows];
}

- (void)_updateShadows {
  NSRect vr = _scroll.documentVisibleRect;
  CGFloat docW = [_pills intrinsicContentWidth];
  CGFloat scrollable = docW - vr.size.width;
  if (scrollable <= 0.5) {
    _leftShadow.alphaValue = 0.0;
    _rightShadow.alphaValue = 0.0;
    return;
  }
  CGFloat fromLeft = vr.origin.x;
  CGFloat percent = fromLeft / scrollable;
  percent = MAX(0.0, MIN(1.0, percent));
  _leftShadow.alphaValue = percent;
  _rightShadow.alphaValue = 1.0 - percent;
}

@end

@implementation KKLaneVisibilityPillsView {
  BOOL _dragActive;
  BOOL _dragTargetVisible;
  NSMutableIndexSet *_draggedIndices;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _labels = @[];
    _visibleStates = @[];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)setLabels:(NSArray<NSString *> *)labels {
  _labels = [labels copy];
  [self invalidateIntrinsicContentSize];
  [self setNeedsDisplay:YES];
}

- (void)setVisibleStates:(NSArray<NSNumber *> *)visibleStates {
  _visibleStates = [visibleStates copy];
  [self setNeedsDisplay:YES];
}

- (NSFont *)pillFont {
  return [NSFont systemFontOfSize:8.0 weight:NSFontWeightMedium];
}

- (CGFloat)pillWidthForIndex:(NSInteger)i {
  if (i < 0 || (NSUInteger)i >= _labels.count)
    return 0;
  NSDictionary *attrs = @{NSFontAttributeName : [self pillFont]};
  CGFloat textW = [_labels[i] sizeWithAttributes:attrs].width;
  return textW + 2 * kPillPadX;
}

- (CGFloat)intrinsicContentWidth {
  CGFloat x = 0;
  for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
    x += [self pillWidthForIndex:i];
    if (i + 1 < (NSInteger)_labels.count)
      x += kPillSpacing;
  }
  return x;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize([self intrinsicContentWidth], kBarHeight);
}

- (NSArray<NSValue *> *)pillRects {
  NSMutableArray<NSValue *> *rects =
      [NSMutableArray arrayWithCapacity:_labels.count];
  CGFloat x = 0;
  CGFloat y = (kBarHeight - kPillHeight) / 2.0;
  for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
    CGFloat w = [self pillWidthForIndex:i];
    [rects addObject:[NSValue valueWithRect:NSMakeRect(x, y, w, kPillHeight)]];
    x += w + kPillSpacing;
  }
  return rects;
}

- (BOOL)_isSoloed:(NSInteger)i {
  if (i < 0 || (NSUInteger)i >= _visibleStates.count)
    return NO;
  if (!_visibleStates[i].boolValue)
    return NO;
  NSInteger onCount = 0;
  for (NSNumber *n in _visibleStates)
    if (n.boolValue)
      onCount++;
  return onCount == 1 && _labels.count > 1;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSArray<NSValue *> *rects = [self pillRects];
  for (NSInteger i = 0; i < (NSInteger)rects.count; i++) {
    NSRect r = rects[i].rectValue;
    BOOL on =
        (i < (NSInteger)_visibleStates.count) && _visibleStates[i].boolValue;
    BOOL solo = [self _isSoloed:i];

    NSColor *bgColor;
    NSColor *tint;
    if (solo) {
      bgColor = [[NSColor warning] colorWithAlphaComponent:0.18];
      tint = [NSColor warning];
    } else if (on) {
      bgColor = [[NSColor accentMatchingHost] colorWithAlphaComponent:0.15];
      tint = [NSColor accentMatchingHost];
    } else {
      bgColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.06];
      tint = [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
    }

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r
                                                       xRadius:KKRadiusMD
                                                       yRadius:KKRadiusMD];
    [bgColor setFill];
    [bg fill];

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

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (NSInteger)_pillIndexAtPoint:(NSPoint)loc {
  NSArray<NSValue *> *rects = [self pillRects];
  for (NSInteger i = 0; i < (NSInteger)rects.count; i++) {
    if (NSPointInRect(loc, rects[i].rectValue))
      return i;
  }
  return NSNotFound;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger idx = [self _pillIndexAtPoint:loc];
  if (idx == NSNotFound)
    return;
  BOOL optDown = (event.modifierFlags & NSEventModifierFlagOption) != 0;
  BOOL wasVisible =
      (idx < (NSInteger)_visibleStates.count) && _visibleStates[idx].boolValue;
  if (_onPillClicked)
    _onPillClicked(idx, optDown);
  if (optDown)
    return;
  // Begin drag-paint: subsequent pills get set to the new state of the
  // start pill (i.e. its toggled value).
  _dragActive = YES;
  _dragTargetVisible = !wasVisible;
  _draggedIndices = [NSMutableIndexSet indexSetWithIndex:idx];
}

- (void)mouseDragged:(NSEvent *)event {
  if (!_dragActive)
    return;
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger idx = [self _pillIndexAtPoint:loc];
  if (idx == NSNotFound || [_draggedIndices containsIndex:idx])
    return;
  [_draggedIndices addIndex:idx];
  if (_onPillDraggedToVisible)
    _onPillDraggedToVisible(idx, _dragTargetVisible);
}

- (void)mouseUp:(NSEvent *)event {
  _dragActive = NO;
  _draggedIndices = nil;
}

@end
