/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPillToggleRowView.h"
#import "KKTimelineInspectorView+Guide.h"
#import "KKTimelineInspectorView_Private.h"

@implementation KKTimelineInspectorView (Guide)

@dynamic onPlayingChanged;
@dynamic onGuideTabChanged;

- (void (^)(NSInteger))onGuideTabChanged {
  return _onGuideTabChanged;
}

- (void)setOnGuideTabChanged:(void (^)(NSInteger))block {
  _onGuideTabChanged = [block copy];
}

- (NSRect)guidePlayButtonScreenRect {
  KKPlayButton *btn = [self _guidePlayButton];
  NSWindow *w = btn.window;
  if (!btn || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[btn convertRect:btn.bounds toView:nil]];
}

- (NSRect)guideTabSegmentScreenRectForTab:(NSInteger)tab {
  KKPillToggleRowView *bar = [self _guideTabBar];
  if (!bar)
    return NSZeroRect;
  return [bar guidePillScreenRectAtIndex:tab];
}

- (void (^)(BOOL))onPlayingChanged {
  return _onPlayingChanged;
}

- (void)setOnPlayingChanged:(void (^)(BOOL))onPlayingChanged {
  _onPlayingChanged = [onPlayingChanged copy];
}

@end
