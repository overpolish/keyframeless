/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKFloatingPanel.h"
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
  // The Animated dropdown pages its lanes by category; the target lane may live
  // outside the default (first) page, so flip to its page before spotlighting
  // (idempotent - no-op once it's the selected page).
  [mv selectCategoryForLabel:label];
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
  [self _closeEditorPanel];
  [_openContentPopover close];
}

- (void)guideCloseAllPopovers {
  [self _closeEditorPanel];
  [_openContentPopover close];
  [self closeManagePopover];
  [self closeFilterPopover];
}

- (NSString *)guideRememberedConstantCategory {
  return _rememberedCategory;
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

- (void)guideBeginEditorLayoutOverride {
  if (_guideEditorLayoutOverrideActive)
    return;
  _guideEditorLayoutOverrideActive = YES;
  _guideSavedEditorCompactMode = _editorCompactMode;
  _guideSavedExpandedSizeBeforeCompact = _editorExpandedSizeBeforeCompact;
  _guideSavedStaticEditorFrameValid = _staticEditorPanel != nil;
  _guideSavedStaticEditorFrame = _staticEditorPanel.frame;
  _guideSavedSegmentEditorFrameValid = _segmentEditorPanel != nil;
  _guideSavedSegmentEditorFrame = _segmentEditorPanel.frame;

  // Do not call the normal setter: this is transient guide state and must not
  // overwrite the user's scoped default. Every editor built during the run now
  // starts expanded, including plugin-specific guides such as Canvas Arrow.
  _editorCompactMode = NO;
  _editorExpandedSizeBeforeCompact = NSZeroSize;
  [self _syncMiniViewerFeedActivity];
}

- (void)guideEndEditorLayoutOverride {
  if (!_guideEditorLayoutOverrideActive)
    return;

  _editorCompactMode = _guideSavedEditorCompactMode;
  _editorExpandedSizeBeforeCompact = _guideSavedExpandedSizeBeforeCompact;

  if (_openStaticView) {
    [_openStaticView setCompactMode:_editorCompactMode];
    _staticEditorPanel.minSize = [_openStaticView minimumHostedContentSize];
  }
  if (_guideSavedStaticEditorFrameValid && _staticEditorPanel) {
    [_staticEditorPanel setFrame:_guideSavedStaticEditorFrame
                         display:_staticEditorPanel.isVisible];
  } else if (_openStaticView && _staticEditorPanel) {
    NSSize natural = [_openStaticView naturalHostedContentSize];
    natural.width = MAX(_staticEditorPanel.frame.size.width,
                        _staticEditorPanel.minSize.width);
    natural.height = MAX(natural.height, _staticEditorPanel.minSize.height);
    [_staticEditorPanel setContentSizeKeepingTopEdge:natural];
  }
  if (_openStaticView && _staticEditorPanel)
    [_openStaticView applyHostedContentSize:_staticEditorPanel.frame.size];
  if (_guideSavedSegmentEditorFrameValid && _segmentEditorPanel)
    [_segmentEditorPanel setFrame:_guideSavedSegmentEditorFrame
                          display:_segmentEditorPanel.isVisible];

  _staticEditorPanel.userMovable = YES;
  _staticEditorPanel.userResizable = YES;
  _segmentEditorPanel.userMovable = YES;
  _segmentEditorPanel.userResizable = NO;

  _guideSavedStaticEditorFrameValid = NO;
  _guideSavedSegmentEditorFrameValid = NO;
  _guideEditorLayoutOverrideActive = NO;
  [self _syncMiniViewerFeedActivity];
}

@end
