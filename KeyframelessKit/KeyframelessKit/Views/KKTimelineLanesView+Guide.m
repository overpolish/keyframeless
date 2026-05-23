/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTimelineLanesView_Private.h"

@implementation KKTimelineLanesView (Guide)

@dynamic onGapPopoverWillOpen;
@dynamic onGapPopoverCurveChanged;

- (NSRect)guideManagePopoverItemScreenRectForLabel:(NSString *)label {
  _KKManagePopoverView *mv = _openManageView;
  if (!mv || label.length == 0)
    return NSZeroRect;
  NSView *row = [mv rowViewForLabel:label];
  NSWindow *w = row.window;
  if (!row || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[row convertRect:row.bounds toView:nil]];
}

- (KKTimelineBasicView *)basicGraph {
  return _basicGraph;
}

- (KKTimelineAdvancedView *)advancedGraph {
  return _advancedGraph;
}

- (void)guideCloseContentPopover {
  [_openContentPopover close];
}

- (void (^)(NSView *, KKSegmentEditView *))onGapPopoverWillOpen {
  return _onGapPopoverWillOpen;
}

- (void)setOnGapPopoverWillOpen:(void (^)(NSView *, KKSegmentEditView *))block {
  _onGapPopoverWillOpen = [block copy];
}

- (void (^)(NSInteger))onGapPopoverCurveChanged {
  return _onGapPopoverCurveChanged;
}

- (void)setOnGapPopoverCurveChanged:(void (^)(NSInteger))block {
  _onGapPopoverCurveChanged = [block copy];
}

@end
