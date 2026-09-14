/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasInspectorView.h"

@class KKJoyrideController;
@class KKJoyrideLanesBinder;
@class KKJoyrideStep;

NS_ASSUME_NONNULL_BEGIN

/// State shared between the main inspector (which synthesizes it) and the
/// ArrowGuide category: whether the "Animating an Arrow" guide is running, and
/// the constant-popover category tab to restore when it ends.
@interface CanvasInspectorView ()
@property(nonatomic) BOOL arrowGuideActive;
@property(nonatomic, copy, nullable) NSString *arrowGuideSavedCategory;
@end

/// The "Animating an Arrow" end-to-end walkthrough. `runArrowGuide` (declared on
/// the main interface) is started by the plugin from a help-guide onStart; the
/// steps live in this category to keep the inspector file focused.
@interface CanvasInspectorView (ArrowGuide)
/// Build the ordered arrow-guide steps, binding each to `binder`. Called by
/// -runArrowGuide (on the main class) inside the guide host's buildSteps block.
- (NSArray<KKJoyrideStep *> *)_arrowGuideStepsForGuide:(KKJoyrideController *)guide
                                               binder:
                                                   (KKJoyrideLanesBinder *)binder;
/// Advance the Pen-tool step once the tool becomes Pen. Called from
/// -setToolbarTool: on every kParamUIState tool change.
- (void)_arrowGuideAdvanceIfPenSelected:(NSInteger)tool;
@end

NS_ASSUME_NONNULL_END
