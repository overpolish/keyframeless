/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideOverlayView_Private.h"
#import "KKMarkup.h"
#import "KKTokens.h"

@implementation _KKJoyrideOverlayView

@synthesize step = _step;
@synthesize totalSteps = _totalSteps;
@synthesize drawsBackground = _drawsBackground;
@synthesize spotlightPassThrough = _spotlightPassThrough;

- (NSString *)message {
  return _message;
}

- (void)setMessage:(NSString *)message {
  _message = [message copy];
  [self _rebuildAttributedMessage];
  [self setNeedsDisplay:YES];
}

// Tooltip text is KKMarkup: <kbd>, <symbol/>, <accent>, <warn>. Render it
// once, then apply the bubble's base font + light colour only where the
// markup didn't set its own (so badges/symbols/accent/warn keep their look).
- (void)_rebuildAttributedMessage {
  if (_message.length == 0) {
    _attributedMessage = nil;
    return;
  }
  NSMutableAttributedString *s =
      [[KKMarkup attributedStringFromMarkup:_message] mutableCopy];
  NSFont *base = [NSFont systemFontOfSize:KKFontSizeSM
                                   weight:NSFontWeightMedium];
  NSColor *baseColor = [NSColor colorWithWhite:1.0 alpha:0.9];
  [s enumerateAttributesInRange:NSMakeRange(0, s.length)
                        options:0
                     usingBlock:^(NSDictionary *attrs, NSRange r, BOOL *stop) {
                       NSMutableDictionary *add =
                           [NSMutableDictionary dictionary];
                       if (!attrs[NSFontAttributeName])
                         add[NSFontAttributeName] = base;
                       if (!attrs[NSForegroundColorAttributeName])
                         add[NSForegroundColorAttributeName] = baseColor;
                       if (add.count)
                         [s addAttributes:add range:r];
                     }];
  _attributedMessage = s;
}

- (instancetype)initWithTargetView:(NSView *)target message:(NSString *)msg {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _targetView = target;
    _message = [msg copy];
    [self _rebuildAttributedMessage];
    _drawsBackground = YES;
  }
  return self;
}

- (NSRect)screenActionRect {
  if (NSIsEmptyRect(_actionRect) || !self.window)
    return NSZeroRect;
  NSRect winRect = [self convertRect:_actionRect toView:nil];
  return [self.window convertRectToScreen:winRect];
}

- (NSRect)screenNextRect {
  if (NSIsEmptyRect(_nextRect) || !self.window)
    return NSZeroRect;
  NSRect winRect = [self convertRect:_nextRect toView:nil];
  return [self.window convertRectToScreen:winRect];
}

- (void)setScreenRectBlock:(nullable NSRect (^)(void))block
                  circular:(BOOL)circular {
  _screenRectBlock = [block copy];
  _spotlightCircular = circular;
}

- (void)setPillToScreenRectBlock:(nullable NSRect (^)(void))block {
  _pillToScreenRectBlock = [block copy];
  if (block && !_pulseTimer) {
    // Drive the target glow ourselves — the FCP-rendered OSC only redraws
    // when FCP decides, so a real pulse must come from a view we control.
    // Common modes so it keeps ticking during the drag's event tracking.
    __weak typeof(self) weak = self;
    _pulseTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0
                                         repeats:YES
                                           block:^(NSTimer *t) {
                                             __strong typeof(weak) s = weak;
                                             if (!s) {
                                               [t invalidate];
                                               return;
                                             }
                                             [s setNeedsDisplay:YES];
                                           }];
    [[NSRunLoop mainRunLoop] addTimer:_pulseTimer forMode:NSRunLoopCommonModes];
  }
}

- (NSRect)_pillSecondaryLocalRect {
  if (!_pillToScreenRectBlock || !self.window)
    return NSZeroRect;
  NSRect sr = _pillToScreenRectBlock();
  if (NSIsEmptyRect(sr))
    return NSZeroRect;
  NSRect wr = [self.window convertRectFromScreen:sr];
  return NSInsetRect([self convertRect:wr fromView:nil], -8.0, -3.0);
}

- (void)viewDidMoveToWindow {
  if (!self.window) {
    [_pulseTimer invalidate];
    _pulseTimer = nil;
  }
}

- (void)dealloc {
  [_pulseTimer invalidate];
}

- (NSRect)screenSpotRect {
  if (_screenRectBlock) {
    NSRect sr = _screenRectBlock();
    return NSIsEmptyRect(sr) ? NSZeroRect : sr;
  }
  NSRect spot = [self spotRectInSelf];
  if (NSIsEmptyRect(spot) || !self.window)
    return NSZeroRect;
  NSRect padded = NSInsetRect(spot, -8.0, -3.0);
  NSRect winRect = [self convertRect:padded toView:nil];
  return [self.window convertRectToScreen:winRect];
}

- (NSRect)spotRectInSelf {
  if (_screenRectBlock) {
    NSRect sr = _screenRectBlock();
    if (NSIsEmptyRect(sr) || !self.window)
      return NSZeroRect;
    NSRect winRect = [self.window convertRectFromScreen:sr];
    return [self convertRect:winRect fromView:nil];
  }
  NSView *target = _targetView;
  if (!target || !self.window)
    return NSZeroRect;
  if (target.window == self.window)
    return [target convertRect:target.bounds toView:self];
  if (!target.window)
    return NSZeroRect;
  NSRect screenR = [target.window
      convertRectToScreen:[target convertRect:target.bounds toView:nil]];
  NSRect winR = [self.window convertRectFromScreen:screenR];
  return [self convertRect:winR fromView:nil];
}

- (BOOL)wantsLayer {
  return YES;
}
- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
  return YES;
}

// Called by the controller at the start of dismiss/teardown. Pins the overlay
// to the last spotlight it drew and stops the pulse timer so the fade-out
// renders in place instead of jumping to the centred "no target" fallback
// (the spotlight block returns NSZeroRect once the guide step resets).
- (void)freezeForDismiss {
  _frozen = YES;
  [_pulseTimer invalidate];
  _pulseTimer = nil;
}

// hitTest returns nil everywhere — the panel has ignoresMouseEvents = YES so
// this view never receives events directly. Clicks on buttons are handled by
// the global monitor in KKJoyrideController.
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}

@end
