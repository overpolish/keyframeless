/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasInspectorView.h"
#import "Plugin.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPlayheadPoller;

@interface CanvasPlugin ()
/// Covariant re-type of the KKPlugin base property (one storage, @dynamic in
/// the implementation).
@property(nonatomic, weak, nullable) CanvasInspectorView *inspectorView;
@property(nonatomic, strong, nonnull) KKRenderCache *renderCache;
@property(nonatomic, strong, nullable) KKPlayheadPoller *playheadPoller;
/// Link-source advertisement: one KKLinkLayerSource per layer (stable
/// layerID + display name + effective lanes), rebuilt in -pluginState: when
/// the layer blob changes and consumed by the base -writeLinkManifest hook.
@property(nonatomic, copy, nullable)
    NSArray<KKLinkLayerSource *> *linkLayerSources;
/// Hash of the layer blob linkLayerSources was built from, so an unchanged
/// blob skips the per-tick decode.
@property(nonatomic) NSUInteger linkLayerBlobHash;
/// Cross-clip subscriber: watches the sources this clip's layer expressions
/// reference and nudges a re-render when one changes (FCP renders clips
/// independently and won't refresh a subscriber otherwise).
@property(nonatomic, strong, nullable) KKLinkWatcher *linkWatcher;
/// Set while restoring the selected layer from an undo/redo of kParamUIState,
/// so the selection-change callback skips its (otherwise undoable) re-persist
/// and doesn't push a duplicate entry onto the undo stack.
@property(nonatomic) BOOL restoringSelection;
/// Guide demo-scene state: a timing guide saves the user's layer blob +
/// selection here, swaps in a single demo shape to teach on, then restores both
/// when the guide ends. `guideSceneActive` gates the restore; `guideSavedSel*`
/// hold the pre-guide selection; `guideSuppressMutate` swallows the kit guide
/// host's one async timeline-restore write (Canvas restores the whole scene
/// itself, so that write would otherwise clobber the restored layer).
@property(nonatomic) BOOL guideSceneActive;
@property(nonatomic) BOOL guideSuppressMutate;
/// Set when a demo scene is staged; the next timeline mutation (the guide's
/// seed) refreshes the Advanced graph from the blob so its keypose-based steps
/// (Advanced / Mini Viewer / OSC) can find the seeded keyposes.
@property(nonatomic) BOOL guideNeedsGraphRefresh;
@property(nonatomic, copy, nullable) NSString *guideSavedLayerB64;
@property(nonatomic, copy, nullable) NSString *guideSavedSelPrimary;
@property(nonatomic, copy, nullable) NSArray<NSString *> *guideSavedSelIDs;
/// The Arrow guide forces the Cursor tool at start so its "switch to Pen" step
/// has a real change to make; this holds the user's prior tool to restore on
/// guide end. 0 (never a valid tool tag - they start at 101) = nothing to
/// restore (no Arrow guide ran).
@property(nonatomic) NSInteger guideSavedTool;
/// Monotonic guide-run counter. Bumped on every guide start so a deferred help-
/// window reopen (scheduled on a guide's end) can tell whether ANOTHER guide
/// started in between (a restart) and skip the reopen - no help-window flicker.
@property(nonatomic) NSInteger guideRunGeneration;
/// Per-instance cache of decoded image-layer textures, keyed by file path.
/// (Instance-scoped, not a static - every plugin instance is a separate XPC
/// process.)
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString *, id<MTLTexture>> *imageTextureCache;
/// Per-instance tracked scratch texture the non-blur render composites the
/// whole layer stack into (one command buffer, intra-buffer hazard tracking
/// serialises the per-layer passes), then blits to FCP's untracked dest - so
/// the per-layer ordering needs NO per-draw waitUntilCompleted. Rebuilt on
/// tile-size / format change. (Instance-scoped, not a static - separate XPC
/// process per instance.)
@property(nonatomic, strong, nullable) id<MTLTexture> renderIntermediateTex;
/// Per-layer "Fast" (velocity-reconstruction) motion-blur scratch textures,
/// reused across layers and frames (rebuilt on size / format change).
/// `mbColorTex` holds one layer rendered alone over transparent;
/// `mbVelocityTex` (RG16Float) its analytic screen-space velocity;
/// `mbBlurredTex` the reconstruction result composited over the dest.
/// Instance-scoped (separate XPC process per instance).
@property(nonatomic, strong, nullable) id<MTLTexture> mbColorTex;
@property(nonatomic, strong, nullable) id<MTLTexture> mbVelocityTex;
@property(nonatomic, strong, nullable) id<MTLTexture> mbBlurredTex;
@end

NS_ASSUME_NONNULL_BEGIN

@interface CanvasPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

/// The declarative lane + OSC definitions (implemented in
/// Plugin+LaneDefinitions.m). Pure data factories, no instance state.
@interface CanvasPlugin (LaneDefinitions)
+ (NSArray<KKLane *> *)availableLanes;
/// The viewer-OSC visibility pill compounds (each array = one pill: primary +
/// members toggled together). Single source of truth shared by createView's
/// wiring and the kParamUIState parameterChanged refresh, so the element-key
/// list can't drift between them (a drift hid the Rotation toggle).
+ (NSArray<NSArray<NSString *> *> *)oscCompounds;
/// Default per-element visibility seed, by layer kind. A vector path starts
/// with just its point-edit anchors shown (the transform gizmo hidden, opt-peek
/// reveals it). A non-vector layer (image / group) has no point/pen editing, so
/// it starts with the transform gizmo SHOWN (otherwise it would have no visible
/// control at all) and "Points" off.
+ (NSDictionary<NSString *, NSNumber *> *)defaultOSCElementsForVector:
    (BOOL)vector;
@end

@interface CanvasPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
/// Load `layerID`'s per-layer OSC element set (or the default seed) into the
/// ACTIVE per-instance state + refresh the inspector + mini. Called on open and
/// on every layer-selection change so the viewer OSC / mini reflect the
/// selected layer's own visibility.
- (void)canvasApplyOSCForLayer:(nullable NSString *)layerID
                          keys:(NSArray<NSString *> *)keys;
/// Toggle one element for the SELECTED layer: update the active set + that
/// layer's stored map + persist the per-layer map to kParamUIState.
- (void)canvasToggleOSCElement:(NSString *)key
                       visible:(BOOL)visible
                          keys:(NSArray<NSString *> *)keys;
@end

@interface CanvasPlugin (Render)
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error;
- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *_Nullable)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError;
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

NS_ASSUME_NONNULL_END
