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
@property(nonatomic, weak, nullable) CanvasInspectorView *inspectorView;
@property(nonatomic, strong, nonnull) KKRenderCache *renderCache;
@property(nonatomic, strong, nullable) KKPlayheadPoller *playheadPoller;
/// Set while restoring the selected layer from an undo/redo of kParamUIState,
/// so the selection-change callback skips its (otherwise undoable) re-persist
/// and doesn't push a duplicate entry onto the undo stack.
@property(nonatomic) BOOL restoringSelection;
/// Per-instance cache of decoded image-layer textures, keyed by file path.
/// (Instance-scoped, not a static - every plugin instance is a separate XPC
/// process.)
@property(nonatomic, strong, nonnull)
    NSMutableDictionary<NSString *, id<MTLTexture>> *imageTextureCache;
/// Returns a copy of `timeline` with every lane's lastKnownClipDuration set to
/// the current effect duration (seconds). Must be called inside an action
/// scope (FxTimingAPI resolves there).
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;
@end

NS_ASSUME_NONNULL_BEGIN

@interface CanvasPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface CanvasPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
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
