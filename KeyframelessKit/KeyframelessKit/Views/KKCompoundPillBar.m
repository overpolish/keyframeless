/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCompoundPillBar.h"
#import "KKPillToggleRowView.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kEdgeW = 16.0;
static const CGFloat kCompoundGap = 6.0;

@interface _KKCompoundEdgeShadow : NSView
@end
@implementation _KKCompoundEdgeShadow
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation KKCompoundPillBar {
  NSScrollView *_scroll;
  NSStackView *_stack;
  NSArray<KKPillToggleRowView *> *_rows;
  _KKCompoundEdgeShadow *_leftShadow;
  _KKCompoundEdgeShadow *_rightShadow;
  CAGradientLayer *_leftGrad;
  CAGradientLayer *_rightGrad;
}

- (instancetype)initWithCompounds:(NSArray<NSArray<NSString *> *> *)compounds {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;

  NSMutableArray<KKPillToggleRowView *> *rows =
      [NSMutableArray arrayWithCapacity:compounds.count];
  __weak typeof(self) weakSelf = self;
  for (NSInteger ci = 0; ci < (NSInteger)compounds.count; ci++) {
    KKPillToggleRowView *row =
        [[KKPillToggleRowView alloc] initWithLabels:compounds[ci]];
    row.grouped = YES;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.onToggled = ^(NSInteger segIdx, BOOL on) {
      __strong typeof(weakSelf) s = weakSelf;
      if (s && s->_onToggled)
        s->_onToggled(ci, segIdx, on);
    };
    row.onDragBegin = ^{
      __strong typeof(weakSelf) s = weakSelf;
      if (s && s->_onDragBegin)
        s->_onDragBegin();
    };
    row.onDragEnd = ^{
      __strong typeof(weakSelf) s = weakSelf;
      if (s && s->_onDragEnd)
        s->_onDragEnd();
    };
    [rows addObject:row];
  }
  _rows = rows;

  _stack = [NSStackView stackViewWithViews:rows];
  _stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _stack.spacing = kCompoundGap;
  _stack.alignment = NSLayoutAttributeCenterY;
  _stack.translatesAutoresizingMaskIntoConstraints = NO;

  _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  _scroll.drawsBackground = NO;
  _scroll.hasHorizontalScroller = NO;
  _scroll.hasVerticalScroller = NO;
  _scroll.horizontalScrollElasticity = NSScrollElasticityAllowed;
  _scroll.verticalScrollElasticity = NSScrollElasticityNone;
  NSView *doc = [[NSView alloc] init];
  doc.translatesAutoresizingMaskIntoConstraints = NO;
  [doc addSubview:_stack];
  [NSLayoutConstraint activateConstraints:@[
    [_stack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
    [_stack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
    [_stack.topAnchor constraintEqualToAnchor:doc.topAnchor],
    [_stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
  ]];
  _scroll.documentView = doc;
  _scroll.contentView.postsBoundsChangedNotifications = YES;
  [self addSubview:_scroll];

  _leftShadow = [_KKCompoundEdgeShadow new];
  _rightShadow = [_KKCompoundEdgeShadow new];
  NSColor *c0 = [[NSColor blackColor] colorWithAlphaComponent:0.18];
  id opaque = (__bridge id)c0.CGColor;
  id clear = (__bridge id)[NSColor clearColor].CGColor;
  _leftGrad = [CAGradientLayer layer];
  _leftGrad.colors = @[ opaque, clear ];
  _leftGrad.startPoint = CGPointMake(0, 0.5);
  _leftGrad.endPoint = CGPointMake(1, 0.5);
  _leftShadow.wantsLayer = YES;
  _leftShadow.layer = _leftGrad;
  _rightGrad = [CAGradientLayer layer];
  _rightGrad.colors = @[ clear, opaque ];
  _rightGrad.startPoint = CGPointMake(0, 0.5);
  _rightGrad.endPoint = CGPointMake(1, 0.5);
  _rightShadow.wantsLayer = YES;
  _rightShadow.layer = _rightGrad;
  _leftShadow.alphaValue = 0.0;
  _rightShadow.alphaValue = 0.0;
  [self addSubview:_leftShadow];
  [self addSubview:_rightShadow];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(_scrolled)
             name:NSViewBoundsDidChangeNotification
           object:_scroll.contentView];
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isFlipped {
  return YES;
}

- (NSSize)intrinsicContentSize {
  CGFloat w = _stack.fittingSize.width;
  CGFloat h = _stack.fittingSize.height;
  return NSMakeSize(w, h);
}

- (void)layout {
  [super layout];
  _scroll.frame = self.bounds;
  // Force the document view to take the stack's natural width — when wider
  // than the clip, NSScrollView scrolls; the shadows hint at the overflow.
  NSSize fitting = _stack.fittingSize;
  CGFloat docW = MAX(fitting.width, _scroll.contentView.bounds.size.width);
  CGFloat docH = NSHeight(self.bounds);
  _scroll.documentView.frame = NSMakeRect(0, 0, docW, docH);
  _leftShadow.frame = NSMakeRect(0, 0, kEdgeW, docH);
  _rightShadow.frame =
      NSMakeRect(NSWidth(self.bounds) - kEdgeW, 0, kEdgeW, docH);
  _leftGrad.frame = _leftShadow.bounds;
  _rightGrad.frame = _rightShadow.bounds;
  [self _scrolled];
}

- (void)_scrolled {
  CGFloat docW = NSWidth(_scroll.documentView.frame);
  CGFloat visW = _scroll.contentView.bounds.size.width;
  CGFloat offX = _scroll.contentView.bounds.origin.x;
  CGFloat scrollable = docW - visW;
  if (scrollable <= 0.5) {
    _leftShadow.alphaValue = 0.0;
    _rightShadow.alphaValue = 0.0;
    return;
  }
  _leftShadow.alphaValue = MAX(0.0, MIN(1.0, offX / kEdgeW));
  _rightShadow.alphaValue = MAX(0.0, MIN(1.0, (scrollable - offX) / kEdgeW));
}

- (void)setStates:(NSArray<NSArray<NSNumber *> *> *)states {
  _states = [states copy];
  for (NSInteger i = 0;
       i < (NSInteger)_rows.count && i < (NSInteger)states.count; i++)
    _rows[i].states = states[i];
}

@end
