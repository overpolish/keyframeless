/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKBoxOSC.h>
#import <KeyframelessKit/KKOnScreenControl.h>

@class KKLane;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Reusable Scale on-screen control: the transform bounding box (border + 8
/// corner/edge handles + a "X% x Y%" readout) and all of its sizing
/// (KKScaleGizmo curve), drawing, hit-testing and drag logic, keyed on a lane
/// label. Like KKPositionOSC it is a `KKOnScreenControl` (so it owns the
/// process timeline snapshot read, the action-scope writer, and the OSC
/// visibility helpers) but is composed under a host OSC that stays the single
/// FxPlug control and forwards draw / hit-test / mouse to it.
///
/// Drag shortcuts (preserved across plugins): the grabbed handle tracks the
/// cursor absolutely; **Cmd** = fine mode (cursor movement scaled to 20% for
/// precision at high scale); **Shift** = invert the lane's aspect-link for this
/// drag. Corner handles drive both axes (geometric-mean uniform scale when
/// linked); edge handles drive one axis (the other follows by ratio when
/// linked). Values snap to integers, floored at 0 (no negative scale).
@interface KKScaleOSC : KKOnScreenControl

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         laneLabel:(NSString *)laneLabel;

/// The lane this control reads/writes (e.g. @"Scale").
@property(nonatomic, copy) NSString *laneLabel;

/// Lane template (from the host's `availableLanes`) used to build the lane when
/// a drag writes a Scale that doesn't exist in the snapshot yet, so the new
/// lane keeps the plugin's exact metadata (units, aspect-linkable, ...).
@property(nonatomic, copy, nullable) KKLane *templateLane;

/// The host's `activePart` number for "this is the scale box". The host sets it
/// once so the controller can gate its draw on the live activePart. Default 4.
@property(nonatomic) NSInteger scaleActivePart;

/// The host mirrors its FxPlug `isDragging` here each draw tick.
@property(nonatomic) BOOL dragging;

/// Canvas-space centre of the box (= the Position handle). The host sets this
/// each draw / hit-test / mouse tick (the box is concentric with Position).
@property(nonatomic) CGPoint center;

/// The surface's reference dimension (the viewer frame's min side, in canvas
/// units) that sizes the gizmo. The host sets it each draw / hit-test / mouse
/// tick; the controller derives e0/span via KKScaleGizmoE0Frac/SpanFrac.
@property(nonatomic) double frameMin;

/// Optional persist override (see KKPositionOSC): when set, a drag writes via
/// this block instead of the single `kKKParamTimelineData` param, so a
/// multi-owner host (Canvas) can route the write to the owning layer. Invoked
/// inside the control's open action scope.
@property(nonatomic, copy, nullable) void (^onTimelinePersist)
    (KKTimeline *timeline);

/// The owned box gizmo (exposed so the host can tune hit padding etc.).
@property(nonatomic, readonly) KKBoxOSC *box;

/// Draw the scale box, gated on the Scale element's visibility (+ opt-reveal
/// ghost). The host calls this in its drawOSC tick after setting center +
/// frameMin + dragging.
- (void)drawInDestination:(FxImageTile *)destinationImage
                   atTime:(CMTime)time
               activePart:(NSInteger)activePart;

/// Hit-test the scale box handles. Returns the handle index hit (0-7) or -1.
/// Sets the resize / visibility cursor on a hit. The host maps a non-negative
/// result to its scale activePart.
- (NSInteger)hitTestHandleAtX:(double)x y:(double)y atTime:(CMTime)time;

/// Forwarded mouse events. The host calls these when its activePart is the
/// scale box. mouseDown must follow a hitTest (it reads the hit handle).
- (void)mouseDownAtX:(double)x
                   y:(double)y
           modifiers:(NSUInteger)modifiers
         forceUpdate:(BOOL *)forceUpdate
              atTime:(CMTime)time;
- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(NSUInteger)modifiers
            forceUpdate:(BOOL *)forceUpdate
                 atTime:(CMTime)time;
- (void)mouseUp;

@end

NS_ASSUME_NONNULL_END
