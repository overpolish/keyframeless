/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Cross-process rendezvous path: the render side's `KKMiniViewerFeed`
/// publishes here and the inspector's `KKMiniViewerView` consumes it.
extern NSString *const CanvasMiniViewerDescriptorPath;

/// Reverse channel: the boundary / filmstrip / onion previews write the
/// requested clip fraction here; the render side reads it in `-scheduleInputs:`
/// to also pull those frames for the preview.
extern NSString *const CanvasMiniViewerRequestPath;

/// Canvas's mini-viewer delegate. The generic timeline / handle scaffolding
/// lives in `KKMiniViewerRenderer`; this subclass runs the same image-layer
/// compositing as the main render (Plugin+Render.m) over the source frame, so
/// the preview matches the viewer. The host keeps `layers` synced from the
/// `kParamLayerData` blob (see CanvasInspectorView).
@interface CanvasMiniViewerRenderer : KKMiniViewerRenderer
/// The layer stack to composite, kept in sync by the host. Index 0 is topmost.
@property(nonatomic, copy, nullable) NSArray<KKBezierPath *> *layers;
/// The effect's clip duration in seconds, set by the inspector. Used to map the
/// preview's `editFraction` to clip-local seconds for the marching-ants dash
/// phase (editFraction x clipDurationSeconds), matching the main render's
/// media-time phase. Retained across timeline rebuilds (a gesture rebuild drops
/// the lanes' lastKnownClipDuration), so 0 only before the first stamp.
@property(nonatomic) double clipDurationSeconds;
/// The layer the open popover edits. Its transform in the composite comes from
/// the live `timeline` (the kit's in-memory edited copy) so a Position-handle
/// drag previews immediately; the Position OSC also reads/writes this layer.
@property(nonatomic, copy, nullable) NSString *selectedLayerID;
/// The full multi-selection (every selected layer's id), mirrored from the host.
/// Drives the mini toolbar's conditional path-operation buttons (which need the
/// whole selection, not just the primary). Falls back to selectedLayerID.
@property(nonatomic, copy, nullable) NSArray<NSString *> *selectedLayerIDs;
/// The plugin's lane templates (`+[CanvasPlugin availableLanes]`), set by the
/// inspector. Used by `-templateLaneForLabel:` so a created lane keeps its
/// metadata (aspectLinked, units) and the scale-box drag reads the aspect-link
/// default when the timeline has no Scale lane yet.
@property(nonatomic, copy, nullable) NSArray<KKLane *> *laneTemplates;
/// When YES, a click on the preview body (missing every handle) picks the
/// topmost image layer under the cursor and fires `onSelectLayer` - the
/// mini-viewer counterpart of the viewer's auto-select toggle. Off by default;
/// the inspector mirrors the persisted "Auto-select layers" state onto it.
@property(nonatomic) BOOL autoSelectEnabled;
/// Layers that can't be auto-selected right now (mirrors the layer list's
/// non-selectable gating - e.g. a keypose popover only lets you pick layers with
/// a keypose at that time). A click over one falls through to the layer beneath.
@property(nonatomic, copy, nullable) NSSet<NSString *> *nonSelectableLayerIDs;
/// Stricter gating for the MARQUEE / body-drag (which select to MOVE): in the
/// constants popover this excludes move-lane-animated layers (Points / Position),
/// which a single click can still pick. Falls back to nonSelectableLayerIDs.
@property(nonatomic, copy, nullable)
    NSSet<NSString *> *marqueeNonSelectableLayerIDs;
/// Fired with the picked layer's id when a background click auto-selects a layer
/// (only when `autoSelectEnabled`). The inspector wires this to its layer
/// selection so the timeline / OSC / Constants follow.
@property(nonatomic, copy, nullable) void (^onSelectLayer)(NSString *layerID);
/// Fired for a multi-selection change (Shift / Cmd-click in the mini): the full
/// set of selected layer ids plus the primary edit target. The inspector mirrors
/// the set onto the Layers panel + persists it. Falls back to onSelectLayer.
@property(nonatomic, copy, nullable) void (^onSelectLayers)
    (NSArray<NSString *> *layerIDs, NSString *primaryLayerID);

/// Shared alignment-grid state, mirrored from the viewer's kParamUIState by the
/// inspector so the mini grid matches the viewer's. The mini draws the grid (and
/// snaps drags to it) when `gridEnabled`; `gridAdaptive` doubles the spacing as
/// it gets dense; `gridSpacing` is the base cell size in output pixels.
@property(nonatomic) BOOL gridEnabled;
@property(nonatomic) BOOL gridAdaptive;
@property(nonatomic) NSInteger gridSpacing;
/// When YES, dragging the Position handle / Anchor square in the mini snaps to
/// the grid (matches the viewer's snap toggle).
@property(nonatomic) BOOL gridSnap;
/// Active drawing tool tag (shared with the viewer toolbar), for the radio
/// highlight. 0 = none/default.
@property(nonatomic) NSInteger toolbarTool;
/// Shared toolbar position, normalized to the viewport (0..1). {-1,-1} = the
/// default bottom-centre anchor (until the user drags it in either surface).
@property(nonatomic) CGPoint toolbarNormPos;
/// Fired when a mini-toolbar interaction changes shared UI state, so the host
/// persists it to kParamUIState (which round-trips to the viewer too). Keys match
/// the OSC's: gridEnabled / gridAdaptive / gridSpacing / gridSnap / tool, and the
/// mini's own miniToolbarPos (@[nx, ny]).
@property(nonatomic, copy, nullable) void (^onPatchUIState)(NSString *key,
                                                            id value);

/// Fired when the pen tool mutates the layer stack (a new / extended vector
/// layer). The host writes `paths` to kParamLayerData (one undo action) and, if
/// `selectLayerID` is non-nil, makes that the selected layer. The renderer has
/// already updated its own `layers` so the next draw/click sees the change.
@property(nonatomic, copy, nullable) void (^onPersistLayers)
    (NSArray<KKBezierPath *> *paths, NSString *_Nullable selectLayerID);

/// Fired when a delete removes layer(s): the host writes `paths` to
/// kParamLayerData AND clears the selection in ONE undo action (so a single
/// cmd-Z restores both the layer and the prior selection). The renderer has
/// already cleared its own selection + updated `layers`.
@property(nonatomic, copy, nullable) void (^onDeleteLayers)
    (NSArray<KKBezierPath *> *paths);
@end

NS_ASSUME_NONNULL_END
