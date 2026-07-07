/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKPlugin.h>
#import <KeyframelessKit/KKTimingStage.h>

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

@interface KKPlugin (InspectorCallbacks)

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
