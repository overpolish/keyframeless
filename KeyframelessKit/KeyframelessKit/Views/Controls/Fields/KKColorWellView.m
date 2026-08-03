/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKColorWellView.h"
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

extern void KKDrawCheckerboard(NSRect rect);

static const CGFloat kSwatchSize = 14.0;

@implementation KKColorWellView {
  BOOL _editing; // panel opened from this swatch and not yet closed
  BOOL _ignoreNextColorPanel; // suppress the initial programmatic colour set
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _color = [NSColor whiteColor];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.window) {
    // The popover (or whatever hosts the swatch) is going away - stop editing
    // and detach from the shared panel so a stray callback can't fire into a
    // dead row.
    [self _endEditing];
    NSColorPanel *panel = [NSColorPanel sharedColorPanel];
    [panel setTarget:nil];
    [panel setAction:nil];
  }
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(kSwatchSize, kSwatchSize);
}

- (void)drawRect:(NSRect)dirtyRect {
  NSRect swatch = NSMakeRect(round((NSWidth(self.bounds) - kSwatchSize) * 0.5),
                             round((NSHeight(self.bounds) - kSwatchSize) * 0.5),
                             kSwatchSize, kSwatchSize);

  // Checkerboard for transparency
  NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:swatch
                                                       xRadius:KKRadiusSM
                                                       yRadius:KKRadiusSM];
  [NSGraphicsContext saveGraphicsState];
  [clip addClip];
  KKDrawCheckerboard(swatch);
  [NSGraphicsContext restoreGraphicsState];

  // Color fill
  [_color setFill];
  [clip fill];

  // Border
  [[NSColor.inspectorLabel colorWithAlphaComponent:0.3] setStroke];
  NSBezierPath *border =
      [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(swatch, 0.5, 0.5)
                                      xRadius:KKRadiusSM
                                      yRadius:KKRadiusSM];
  border.lineWidth = KKBorderWidthXS;
  [border stroke];
}

- (void)mouseDown:(NSEvent *)event {
  NSColorPanel *panel = [NSColorPanel sharedColorPanel];
  // Retarget the shared panel to THIS swatch before loading its colour. Setting
  // panel.color can fire the panel's action synchronously; if the previous
  // swatch were still the target that would overwrite it (and the guard stops
  // this swatch's own initial set from writing back). Matches
  // KKGradientBarView.
  _ignoreNextColorPanel = YES;
  panel.target = self;
  panel.action = @selector(_colorPanelChanged:);
  panel.continuous = YES;
  panel.color = _color;

  NSWindow *hostWindow = self.window;
  if (hostWindow && panel.parentWindow != hostWindow) {
    [panel.parentWindow removeChildWindow:panel];
    [hostWindow addChildWindow:panel ordered:NSWindowAbove];
  }

  [self _beginEditingWithPanel:panel];
  [panel orderFront:nil];
  _ignoreNextColorPanel = NO;
}

- (void)_beginEditingWithPanel:(NSColorPanel *)panel {
  if (_editing)
    return;
  _editing = YES;
  // Restore normal popover dismissal the moment the panel closes.
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(_panelWillClose:)
             name:NSWindowWillCloseNotification
           object:panel];
  if (_onColorEditingChanged)
    _onColorEditingChanged(YES);
}

- (void)_endEditing {
  if (!_editing)
    return;
  _editing = NO;
  [[NSNotificationCenter defaultCenter]
      removeObserver:self
                name:NSWindowWillCloseNotification
              object:nil];
  if (_onColorEditingChanged)
    _onColorEditingChanged(NO);
}

- (void)_panelWillClose:(NSNotification *)note {
  [self _endEditing];
}

- (void)_colorPanelChanged:(NSColorPanel *)panel {
  if (_ignoreNextColorPanel)
    return;
  self.color = panel.color;
  if (_onColorChanged)
    _onColorChanged(_color);
}

- (void)setColor:(NSColor *)color {
  _color = color;
  [self setNeedsDisplay:YES];
}

@end
