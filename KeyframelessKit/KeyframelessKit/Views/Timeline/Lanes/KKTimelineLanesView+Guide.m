/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneFilterBar.h"
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

- (NSRect)guideRenderModePillScreenRectForMode:(KKMiniViewerRenderMode)mode {
  _KKStaticValuesPopoverView *sv = _openStaticView;
  if (!sv || !_openStaticIsBoundary)
    return NSZeroRect;
  return [sv guideRenderModePillScreenRectForMode:mode];
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

- (NSSet<NSString *> *)guideLaneFilterHiddenLabels {
  return [_laneFilterBar hiddenLabels];
}

- (void)guideShowAllLanes {
  [_laneFilterBar showAllLanes];
}

- (void)guideRestoreLaneFilterHidden:(NSSet<NSString *> *)hidden {
  [_laneFilterBar applyHiddenLabels:hidden ?: [NSSet set]];
}

- (NSRect)guideLaneFilterBarScreenRect {
  KKLaneFilterBar *bar = _laneFilterBar;
  NSWindow *w = bar.window;
  if (!bar || bar.isHidden || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[bar convertRect:bar.bounds toView:nil]];
}

@end
