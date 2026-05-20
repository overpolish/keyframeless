/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineInspectorButtons.h"
#import "KKTimelineInspectorView+Guide.h"
#import "KKTimelineInspectorView_Private.h"

@implementation KKTimelineInspectorView (Guide)

@dynamic onPlayingChanged;

- (NSRect)guidePlayButtonScreenRect {
  KKPlayButton *btn = [self _guidePlayButton];
  NSWindow *w = btn.window;
  if (!btn || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[btn convertRect:btn.bounds toView:nil]];
}

- (void (^)(BOOL))onPlayingChanged {
  return _onPlayingChanged;
}

- (void)setOnPlayingChanged:(void (^)(BOOL))onPlayingChanged {
  _onPlayingChanged = [onPlayingChanged copy];
}

@end
