/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Shared internals of CanvasOSC, split across category files (+Geometry, +State,
// +AutoSelect, +Input). Holds the controller properties + transient state and
// declares the cross-category method surface so each category can call the
// others without -Wundeclared-selector.

#import "CanvasOSC.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPositionOSC;
@class KKScaleOSC;
@class KKRotationOSC;
@class KKAnchorOSC;

NS_ASSUME_NONNULL_BEGIN

// This control's own activePart numbers (Position handle / anchor dot, the
// motion-path tangent handle, the scale box, the rotation rings, and the
// auto-select layer pick). Match the controllers' activePart wiring in -init.
typedef NS_ENUM(NSInteger, CanvasOSCPart) {
  CanvasOSCPartNone = 0,
  CanvasOSCPartPosition = 1,
  CanvasOSCPartScale = 2,
  CanvasOSCPartPath = 3,
  CanvasOSCPartRotation = 4,
  CanvasOSCPartLayerPick = 5,
  CanvasOSCPartAnchor = 6,
};

@interface CanvasOSC ()
// The three reusable sub-controls, concentric on the layer's Position handle.
@property(nonatomic, strong) KKPositionOSC *position;
@property(nonatomic, strong) KKScaleOSC *scale;
@property(nonatomic, strong) KKRotationOSC *rotation;
// The anchor pivot square (topmost), concentric region with the Position handle.
@property(nonatomic, strong) KKAnchorOSC *anchor;
// Set while the hover hit-test forced a move/eye/hand cursor, so the next hover
// can reset it to the arrow.
@property(nonatomic) BOOL pointCursorSet;
// Layer the hover hit-test resolved for an auto-select pick; consumed by the
// matching mouseDown.
@property(nonatomic, copy, nullable) NSString *pendingPickLayerID;
@end

// Canvas-space geometry + sub-control feeding.
@interface CanvasOSC (Geometry)
- (double)_onScreenFrameMin;
- (double)_canvasAspect;
- (void)_syncScaleControlAtTime:(CMTime)time;
- (void)_syncRotationControlAtTime:(CMTime)time;
@end

// Reading the inspector-published snapshots (layer blob + UIState) and writing
// back through the OSC's action scope - the OSC can't read the custom params.
@interface CanvasOSC (State)
- (NSArray<KKBezierPath *> *)_snapshotPaths;
- (nullable KKBezierPath *)_selectedLayer;
- (nullable NSString *)_resolvedSelectedLayerID;
- (BOOL)_selectedLayerLocked;
- (NSDictionary *)_uiStateDict;
- (void)_writeUIStateMerging:(void (^)(NSMutableDictionary *state))mutate;
- (void)_persistSelectedLayerTimeline:(KKTimeline *)tl;
@end

// Click-to-select: pick the layer under the cursor + commit the selection.
@interface CanvasOSC (AutoSelect)
- (BOOL)_autoSelectEnabled;
- (nullable NSString *)_pickLayerIDAtX:(double)x y:(double)y atTime:(CMTime)time;
- (void)_commitPickSelection;
@end

NS_ASSUME_NONNULL_END
