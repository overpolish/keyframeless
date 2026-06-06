/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKPlugin.h>

@class KKTimelineInspectorView;
@class KKMiniCanvasRenderer;
@class KKJoyrideGuideHost;

NS_ASSUME_NONNULL_BEGIN

/// Reusable on-screen-control visibility wiring (master tick + per-element
/// pills + opt-click-hide + opt-reveal). The viewer-OSC side lives on
/// KKOnScreenControl; this category is the plugin-side glue that persists the
/// state and keeps the inspector pills + mini-canvas + viewer in sync.
///
/// A plugin opts in by: (1) returning YES from `showsOSCVisibilityRow` on its
/// inspector view; (2) in createViewForParameterID, after the view + renderer
/// exist, seeding master state and calling -kkWireOSCVisibilityForView:...;
/// (3) in parameterChanged for the UI-state blob, calling
/// -kkRefreshOSCVisibilityFromState:...; (4) its viewer OSC overriding
/// `oscElementKeys` + `oscElementKeyForActivePart:`. Compounds group the pills:
/// segment 0 of each compound is its master (e.g.
/// @[ @[@"Position"], @[@"Rotation", @"Rotation.X", @"Rotation.Y",
/// @"Rotation.Z"] ]).
@interface KKPlugin (OSCVisibility)

/// Flatten compounds into the full element-key list.
+ (NSArray<NSString *> *)kkOSCElementKeysForCompounds:
    (NSArray<NSArray<NSString *> *> *)compounds;

/// Derive the hidden set from a UI-state dict's `oscElements` map and push it
/// to this instance's KKPluginInstanceState + the mini-canvas renderer.
- (void)kkApplyOSCVisibilityFromState:(NSDictionary *)uiState
                          elementKeys:(NSArray<NSString *> *)keys
                             renderer:(nullable KKMiniCanvasRenderer *)renderer;

/// Toggle one element's visibility (used by the pills and the mini-canvas
/// opt-click) and persist the full `oscElements` map via patchUIStateKey.
- (void)kkToggleOSCElement:(NSString *)label
               elementKeys:(NSArray<NSString *> *)keys
                  renderer:(nullable KKMiniCanvasRenderer *)renderer
                   paramID:(UInt32)paramID;

/// Wire the inspector view's OSC-visibility callbacks (master tick + pills) and
/// the mini-canvas opt-click. Call once in createViewForParameterID after the
/// view + renderer exist and master state is seeded.
- (void)kkWireOSCVisibilityForView:(KKTimelineInspectorView *)view
                          renderer:(nullable KKMiniCanvasRenderer *)renderer
                         compounds:(NSArray<NSArray<NSString *> *> *)compounds
                           paramID:(UInt32)paramID;

/// Handle a UI-state-blob parameterChanged: refresh this instance's master +
/// lastUIState + hidden set, then push to the inspector tick + mini-canvas on
/// the main queue. Call from parameterChanged before any other UI-state sync.
- (void)kkRefreshOSCVisibilityFromState:(NSDictionary *)state
                                   view:(nullable KKTimelineInspectorView *)view
                               renderer:
                                   (nullable KKMiniCanvasRenderer *)renderer
                            elementKeys:(NSArray<NSString *> *)keys;

/// Transiently force OSC visibility for a guide run, showing ONLY the elements
/// in `keepLabels` (nil/empty = show all) so the guide isn't cluttered by
/// other on-screen controls. Master is forced ON and every element not in
/// `keepLabels` is hidden, WITHOUT persisting - the user's saved OSC setting
/// in the UI-state blob is untouched. Returns an opaque snapshot of the prior
/// master + hidden set; pass it to -kkRestoreOSCForGuide:... when the guide
/// ends.
- (NSDictionary *)
    kkForceOSCForGuideKeepingLabels:(nullable NSArray<NSString *> *)keepLabels
                        elementKeys:(NSArray<NSString *> *)keys
                               view:(nullable KKTimelineInspectorView *)view
                           renderer:(nullable KKMiniCanvasRenderer *)renderer;

/// Restore the OSC visibility captured by -kkForceOSCForGuideKeepingOnly:...
/// Call on guide end (complete or skip).
- (void)kkRestoreOSCForGuide:(NSDictionary *)snapshot
                        view:(nullable KKTimelineInspectorView *)view
                    renderer:(nullable KKMiniCanvasRenderer *)renderer;

/// Wire the guide host's run start/end hooks to force-then-restore OSC
/// visibility for the duration of every timing-guide run. On start, hides all
/// OSCs except the inspector's `guideOSCKeepLabels` (the keep-set the running
/// guide's config installed); on end, restores the user's prior visibility. The
/// renderer is resolved from `view.miniCanvasDelegate` at fire time. Call once
/// in createViewForParameterID after the view + host exist. Replaces the
/// per-plugin onRunWillStart/onRunDidEnd boilerplate.
///
/// `nudgeParamID` is the plugin's hidden render-nudge scratch param. Forcing
/// OSC visibility only mutates in-memory instance state, so the FCP viewer
/// won't redraw its on-screen controls until something triggers a re-render.
/// Guides that write params incidentally (seed / scrub) get this for free, but
/// a pure-navigation guide (the OSC walkthrough) does not - so we write a nonce
/// to this param on force and restore to force the viewer to redraw.
- (void)kkInstallGuideOSCForcingOnHost:(KKJoyrideGuideHost *)host
                                  view:(KKTimelineInspectorView *)view
                           elementKeys:(NSArray<NSString *> *)keys
                          nudgeParamID:(UInt32)nudgeParamID;

@end

NS_ASSUME_NONNULL_END
