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
/// Restore the FULL multi-selection (highlights every selected row + drives the
/// mini), with `primary` the edit target. An empty `layerIDs` is a real
/// no-selection state (clears highlights, shows the no-layer timeline) - not a
/// fallback to the topmost layer.
- (void)restoreSelectedLayerIDs:(nullable NSArray<NSString *> *)layerIDs
                        primary:(nullable NSString *)primary;
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
/// with the resolved PRIMARY layer id plus the full multi-selection set (the
/// layerIDs of every selected row; just the primary for non-panel selections).
/// The plugin loads the primary layer's per-layer OSC visibility into the active
/// instance state and persists both as the undoable selection.
@property(nonatomic, copy, nullable) void (^onSelectedLayerChanged)
    (NSString *_Nullable resolvedLayerID, NSArray<NSString *> *selectedLayerIDs);
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

/// Fired just before a timing guide (Introduction / Advanced / Mini Viewer /
/// On-Screen Controls) runs, so the plugin can stage a demo subject: it saves
/// the current scene + selection and replaces it with a single demo shape the
/// guide teaches on, restoring the scene when the guide ends (mirrors how a
/// single-clip plugin seeds + restores the clip's timeline). The matching
/// restore runs from the guide host's run-did-end hook. nil = no demo scene
/// (the guide runs on whatever's selected).
@property(nonatomic, copy, nullable) void (^onGuideSceneBegin)(void);

/// Fired just before the Presets guide seeds. Stages an EMPTY scene (a preset
/// applies onto a clean canvas) instead of the demo shape; restored by the same
/// run-did-end hook. nil = no scene staging.
@property(nonatomic, copy, nullable) void (^onGuidePresetsSceneBegin)(void);

/// Fired just before the Canvas-specific "Animating an Arrow" guide runs. Stages
/// an EMPTY scene AND activates the Pen tool so the user can draw the demo path;
/// restored by the same run-did-end hook. nil = no scene staging.
@property(nonatomic, copy, nullable) void (^onGuideArrowSceneBegin)(void);

/// Runs the Canvas-specific "Animating an Arrow" walkthrough: an interactive,
/// end-to-end workflow (draw a path on the viewer, set an arrow marker, animate
/// Draw On). Stages an empty scene + Pen tool, pins the Basic tab, forwards
/// gestures, and runs the steps on the shared timing-guide host.
- (void)runArrowGuide;
@end

NS_ASSUME_NONNULL_END
