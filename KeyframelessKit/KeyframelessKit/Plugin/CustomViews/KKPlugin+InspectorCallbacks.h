/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKPlugin.h>
#import <KeyframelessKit/KKTimeline.h>

@class KKPluginInstanceState;
@class KKPreset;
@class KKTimelineInspectorView;

// Forward-declare the FxPlug protocol (not a module - see KKDataBlob.h).
@protocol FxParameterRetrievalAPI_v6;
@class KKTimelineInspectorView;

NS_ASSUME_NONNULL_BEGIN

/// The shared inspector state persisted across the custom params, parsed once
/// at view-creation time. `timeline` is the raw saved timeline (NOT yet stamped
/// with the clip duration - the caller does that with its own helper).
/// `renderMode` is a `KKMiniViewerRenderMode` carried as NSInteger.
@interface KKInspectorPersistedState : NSObject
@property(nonatomic) BOOL loopEnabled;
@property(nonatomic) BOOL maintainTimingEnabled;
@property(nonatomic) NSInteger activeTab;
@property(nonatomic) BOOL oscMasterVisible;
@property(nonatomic) NSInteger renderMode;
@property(nonatomic) BOOL motionBlurEnabled;
@property(nonatomic) double motionBlurShutterAngle;
@property(nonatomic) NSInteger motionBlurSamples;
@property(nonatomic) NSInteger motionBlurTechnique;
@property(nonatomic, copy) NSDictionary *uiState;
@property(nonatomic, strong, nullable) KKTimeline *timeline;
@end

/// Everything createViewForParameterID: reads before it can build the
/// inspector view. `persistedState`, the timing seeds and `instanceState`
/// are filled inside the template's action scope; `instanceUUID` after it.
@interface KKInspectorCreateContext : NSObject
@property(nonatomic, strong, nullable) KKInspectorPersistedState *persistedState;
/// Frame/clip durations read from FxTimingAPI inside the scope (0 when the
/// API is unavailable). Seeded into the view immediately after construction
/// because the render-side push is gated on lastPushedClipDuration and can
/// race view creation: if the first render fires before the inspector view
/// exists, the push targets a nil weak ref and the basic view never learns
/// the frame duration for the session.
@property(nonatomic) double seedFrameDurSec;
@property(nonatomic) double seedClipDurSec;
/// Per-instance state, minted inside the scope (where the setting API
/// resolves) so the viewer OSC can resolve its visibility from cold.
@property(nonatomic, strong, nullable) KKPluginInstanceState *instanceState;
@property(nonatomic, copy, nullable) NSString *instanceUUID;
@end

@interface KKPlugin (InspectorCallbacks)

/// parameterChanged handler for kKKParamMotionBlurData: reads the blob
/// (inside its own action scope), parses enabled / shutterAngle / samples /
/// technique (migrating a legacy "mode"-only blob), and pushes
/// enabled + shutter + samples to `self.inspectorView` on main.
/// `pushTechnique` additionally pushes the technique row (for plugins whose
/// MB popover exposes Fast/Accurate).
- (void)kkHandleMotionBlurDataChangedPushingTechnique:(BOOL)pushTechnique;

/// The shared spine of createViewForParameterID: for the inspector custom-UI
/// param: opens an action scope, reads the persisted inspector state, seeds
/// frame/clip durations, mints the per-instance UUID, runs `inScope` (the
/// plugin's own scope-bound reads), ends the scope, then builds the view via
/// `buildView`, seeds durations + motion blur into it, wires the standard
/// inspector callbacks, registers `builtinPresets` under the plugin's preset
/// key, and assigns `self.inspectorView`. Returns the built view for the
/// plugin's remaining domain wiring (or nil when `buildView` returns nil).
- (nullable KKTimelineInspectorView *)
    kkCreateInspectorViewWithUIStateParamID:(UInt32)uiStateParamID
                         renderNudgeParamID:(UInt32)renderNudgeParamID
                              dragUndoLabel:(NSString *)dragUndoLabel
                         detachedWindowSize:(CGSize)detachedWindowSize
                             builtinPresets:(nullable NSArray<KKPreset *> *)presets
                                    inScope:
                                        (void (^_Nullable)(
                                            KKInspectorCreateContext *ctx,
                                            id<FxParameterRetrievalAPI_v6>
                                                getAPI))inScope
                                  buildView:
                                      (KKTimelineInspectorView *_Nullable (^)(
                                          KKInspectorCreateContext *ctx))
                                          buildView;

/// Read + parse the shared inspector-persisted state (loop / tab / OSC-master /
/// render-mode + motion-blur + raw timeline) from the custom params. `getAPI`
/// must resolve, so call inside an action scope. Motion-blur + timeline use the
/// fixed kit param IDs; the per-plugin UI-state blob is at `uiStateParamID`.
/// Applies the legacy `onionSkinEnabled` -> render-mode migration.
- (KKInspectorPersistedState *)
    kkReadInspectorPersistedStateWithGetAPI:
        (id<FxParameterRetrievalAPI_v6>)getAPI
                             uiStateParamID:(UInt32)uiStateParamID;

/// Wire the standard inspector callback blocks - loop / tab / motion-blur /
/// render-mode / timeline-mutate / drag-begin+end (undo coalescing) / boundary
/// render-nudge / scrub / playback / detach - on `view`. These bodies are
/// identical across plugins; only the UI-state + render-nudge param IDs, the
/// drag undo-group label, and the detached-window size differ. Plugins keep
/// their own view creation, OSC-visibility, mini-viewer, and gap-popover
/// wiring.
- (void)kkWireStandardInspectorCallbacksForView:(KKTimelineInspectorView *)view
                                 uiStateParamID:(UInt32)uiStateParamID
                             renderNudgeParamID:(UInt32)renderNudgeParamID
                                  dragUndoLabel:(NSString *)dragUndoLabel
                             detachedWindowSize:(CGSize)detachedWindowSize;

@end

NS_ASSUME_NONNULL_END
