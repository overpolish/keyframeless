/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

/// Generic OSC-guide engine, plugin- and OSC-shape-agnostic. Owns the
/// screen↔canvas affine, the drawOSC-staleness heuristic, the hitTest
/// velocity gate, and the step/position notifications that drive a
/// KKJoyrideController over an on-screen control.
///
/// The plugin's OSC tick (which alone has the FxPlug APIs) extracts raw
/// geometry - canvas corners, canvas scale, the handle's canvas position -
/// and feeds it in via -ingestDrawTick… / -ingestHitTest…; the bridge does
/// all the math. None of this code touches FxPlug or any plugin specifics,
/// so every plugin and OSC shape reuses it unchanged.
@interface KKOSCGuideBridge : NSObject

/// 0 = guide inactive. >0 = a guide step is running; the exact numbering is
/// the segment's concern. Setting it posts guideStepNotificationName on the
/// main queue and clears the cached handle position on 0/1 (handle not yet
/// located). Mirror of the old RoundedSetOSCGuideStep.
@property(nonatomic) NSInteger guideStep;

/// YES while the guide pointer is over the control's spotlight - the segment
/// sets it on hover in/out so the OSC's drawOSC can show its hover emphasis
/// (FCP doesn't run its own hitTest hover while the guide panel is frontmost).
/// Cleared automatically when guideStep returns to 0.
@property(nonatomic) BOOL handleHovered;

/// Radius (pt) of the square spotlight rect built around the handle/target
/// screen points. Default 30.
@property(nonatomic) CGFloat spotlightHandleRadius;

/// guideStep value at which the target spotlight is exposed (the drag step).
/// estimatedTargetScreenRect returns NSZeroRect at any other step. Default 2.
@property(nonatomic) NSInteger targetVisibleAtStep;

/// Seconds since the last -ingestDrawTick… within which the OSC is considered
/// alive. FCP gives no OSC-deselect callback, so this is a staleness
/// heuristic (long enough a still mouse doesn't false-disable, short enough a
/// real deselect disables soon). Default 15.
@property(nonatomic) CFTimeInterval canvasRefStaleWindow;

/// Max cursor speed (screen px/sec) for a hitTest sample to be trusted as a
/// re-anchor. Faster samples have temporal skew that translates the whole
/// viewer rect. Default 200.
@property(nonatomic) double hitReanchorMaxVelocity;

@property(nonatomic, readonly) NSNotificationName guideStepNotificationName;
@property(nonatomic, readonly) NSNotificationName guidePositionNotificationName;

/// Spotlight rect around the handle in screen space, or NSZeroRect until the
/// handle has been located by a draw/hit ingest.
@property(nonatomic, readonly) NSRect estimatedHandleScreenRect;
/// Spotlight rect around the target, or NSZeroRect unless guideStep ==
/// targetVisibleAtStep and a target has been located.
@property(nonatomic, readonly) NSRect estimatedTargetScreenRect;
/// The viewer image rect in screen space (recomputed every draw tick).
@property(nonatomic, readonly) NSRect estimatedViewerScreenRect;

/// Live canvas corners + viewer rect from the last draw tick - exposed so an
/// OSC-shape strategy can run its own inverse screen→value map. geometryValid
/// is NO until a usable draw tick has landed.
@property(nonatomic, readonly) CGPoint currentCanvasTopRight;
@property(nonatomic, readonly) CGPoint currentCanvasBottomLeft;
@property(nonatomic, readonly) BOOL geometryValid;

/// YES if a draw tick landed within canvasRefStaleWindow (OSC alive).
- (BOOL)hasCanvasReference;

/// Feed one drawOSC tick. The caller passes the live geometry it pulled from
/// FxPlug; the bridge refreshes scale, recomputes the viewer rect from fresh
/// corners (the zoom-invariant CANVAS→screen affine - never stale vs
/// corners), maps the handle/target to screen, and posts the position
/// notification (throttled to 1/s, plus immediately on change while a guide
/// step is active).
- (void)ingestDrawTickWithCanvasTopRight:(CGPoint)topRight
                              bottomLeft:(CGPoint)bottomLeft
                             canvasScale:(double)spC
                         handleCanvasPos:(CGPoint)handleCanvasPos
                         targetCanvasPos:(CGPoint)targetCanvasPos
                               hasTarget:(BOOL)hasTarget;

/// Feed one hitTest sample (the only place screen + canvas coords arrive
/// together). Velocity-gates the sample, re-anchors the screen↔canvas map on
/// trustworthy samples, recomputes the viewer rect, and posts the position
/// notification if the viewer or handle moved. handleCanvasPos is used only
/// while a guide step is active to refine the handle screen position.
- (void)ingestHitTestAtScreen:(NSPoint)mouseScreen
                    canvasPos:(CGPoint)canvasPos
                  canvasScale:(double)spC
                     topRight:(CGPoint)topRight
                   bottomLeft:(CGPoint)bottomLeft
                     onHandle:(BOOL)onHandle
              handleCanvasPos:(CGPoint)handleCanvasPos;

/// Pair a real screen point with the handle's current canvas position and the
/// live scale, producing a screen↔canvas map correct *now* regardless of how
/// stale the hitTest reference is. Used at the step-0 click and at
/// drag-begin. Returns NO if no live scale yet (no draw tick has run).
- (BOOL)reanchorAtScreen:(NSPoint)screenPt handleCanvasPos:(CGPoint)handle;

/// Inverse of the current anchor map: screen → canvas. NO if no canvas ref.
- (BOOL)screenToCanvas:(NSPoint)screenPt
                  outX:(double *)outX
                  outY:(double *)outY;

/// Drop the cached screen↔canvas map (call when the guide triggers
/// zoom-to-fit). No stale spotlight is then drawn until a fresh post-zoom
/// draw/hit re-anchors it.
- (void)invalidateMapping;

@end

NS_ASSUME_NONNULL_END
