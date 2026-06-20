/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Canvas's plugin-specific timeline inspector. For now a thin subclass of the
/// generic `KKTimelineInspectorView` (toolbar, tab bar, content area, detach,
/// live setters). Canvas-specific extras (mini-viewer renderer, OSC, guides)
/// get added back as those features are rebuilt onto the v3 timing core.
@interface CanvasInspectorView : KKTimelineInspectorView
/// Re-read the layer blob and refresh the Layers panel (on undo/redo).
- (void)reloadLayerList;
/// Programmatically restore the edited layer (on undo/redo of a selection
/// change). Like a panel click but ALSO moves the list highlight, since it
/// doesn't originate from one. Pass nil/empty for the topmost layer. The plugin
/// guards its persist while this runs so it doesn't write a fresh undo step.
- (void)restoreSelectedLayerID:(nullable NSString *)layerID;
/// Sync the popover mini-viewer handles to the OSC visibility (global toggle +
/// per-element hidden set, from per-instance state) combined with the selected
/// layer's lock. Call after the plugin applies/refreshes OSC visibility.
- (void)syncMiniHandleVisibility;
/// The host-recognized object (plugin) to open parameter actions with, so the
/// Layers panel's writes persist. Set by the plugin after creating the view.
- (void)setLayerParamActionTarget:(nullable id)target;
/// layerID of the layer whose timeline the inspector currently edits (driven by
/// the Layers panel selection; nil = topmost). The plugin's timeline-persist
/// reads this to write the edit back to the right layer.
@property(nonatomic, copy, nullable, readonly) NSString *selectedLayerID;
/// The RESOLVED selected layer id (nil `selectedLayerID` -> the topmost layer's
/// id), i.e. the layer the OSC / mini actually act on. The plugin keys
/// per-layer OSC visibility off this.
@property(nonatomic, copy, nullable, readonly)
    NSString *resolvedSelectedLayerID;
/// Fired whenever the edited layer changes (panel click / constants fallback),
/// with the resolved layer id. The plugin loads that layer's per-layer OSC
/// visibility into the active instance state in response.
@property(nonatomic, copy, nullable) void (^onSelectedLayerChanged)
    (NSString *resolvedLayerID);
/// Reflect the persisted "Auto-select layers" toggle onto the Layers panel
/// checkbox (seed from createView + on undo/redo). Does not fire
/// onAutoSelectChanged.
- (void)setAutoSelect:(BOOL)autoSelect;
/// Fired when the user flips the "Auto-select layers" checkbox in the Layers
/// panel. The plugin persists it to kParamUIState.
@property(nonatomic, copy, nullable) void (^onAutoSelectChanged)(BOOL on);
/// Mirror the shared alignment-grid state (from kParamUIState) onto the mini-
/// viewer renderer so the popover preview's grid matches the viewer's. Seeded
/// from createView and on every UIState change / undo-redo.
- (void)setGridEnabled:(BOOL)enabled
              adaptive:(BOOL)adaptive
               spacing:(NSInteger)spacing
                  snap:(BOOL)snap;
/// Mirror the shared toolbar tool + position (kParamUIState) onto the mini so its
/// toolbar matches the viewer's. `normPos` is {-1,-1} for the default anchor.
- (void)setToolbarTool:(NSInteger)tool normPos:(CGPoint)normPos;
/// Fired when the mini-viewer's toolbar changes a kParamUIState key (grid toggles,
/// tool, miniToolbarPos). The plugin persists it (and the write round-trips to the
/// viewer + mini).
@property(nonatomic, copy, nullable) void (^onUIStatePatch)(NSString *key,
                                                            id value);
@end

NS_ASSUME_NONNULL_END
