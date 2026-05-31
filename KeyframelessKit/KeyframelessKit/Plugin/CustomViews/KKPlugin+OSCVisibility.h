/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKPlugin.h>

@class KKTimelineInspectorView;
@class KKMiniCanvasRenderer;

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

@end

NS_ASSUME_NONNULL_END
