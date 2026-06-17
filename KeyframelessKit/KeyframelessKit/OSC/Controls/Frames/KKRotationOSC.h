/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKOnScreenControl.h>

@class KKLane;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// 3-ring sphere rotation gizmo. Each ring is the great-circle perpendicular
/// to its axis, drawn with the current world rotation `R = Ry * Rx * Rz`
/// applied (matching MagicMove's shader order) so the rings visually tilt
/// as the pose changes. Per-ring axis drag: grab a ring, drag tangentially,
/// rotate that axis only.
///
/// Like KKPositionOSC / KKScaleOSC it is a self-contained `KKOnScreenControl`:
/// given a `laneLabel` it reads the 3-axis Euler (degrees) lane from the
/// process timeline snapshot, owns ring visibility + opt-reveal gating, and on
/// a drag composes `R_press * R_axis(delta)`, decomposes back to Euler nearest
/// the press pose, and persists (via `onTimelinePersist` or the single
/// `kKKParamTimelineData` param). The host stays the single FxPlug control and
/// forwards draw / hit-test / mouse to it via the high-level API below. **Cmd**
/// snaps the axis delta to 15° steps before composing. The low-level drawing /
/// hit / angle-delta primitives remain exposed (used internally + for bespoke
/// hosts).
@interface KKRotationOSC : KKOnScreenControl

/// Convenience init binding the control to a 3-axis Euler lane (e.g.
/// @"Rotation"); enables the self-contained high-level API.
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         laneLabel:(NSString *)laneLabel;

/// Canvas-space center of rotation. Set by the owning plugin before hit
/// testing or drawing.
@property(nonatomic) CGPoint center;

/// The 3-axis Euler (X/Y/Z degrees) lane this control reads/writes (e.g.
/// @"Rotation"). Set by the convenience init; nil leaves the high-level API
/// inert (a bespoke host drives the low-level primitives directly).
@property(nonatomic, copy, nullable) NSString *laneLabel;

/// Lane template (from the host's `availableLanes`) used to build the lane when
/// a drag writes a Rotation that doesn't exist in the snapshot yet.
@property(nonatomic, copy, nullable) KKLane *templateLane;

/// The host's `activePart` number for "this is the rotation gizmo". The host
/// sets it once so the controller can gate its draw highlight + drag on the
/// live activePart.
@property(nonatomic) NSInteger rotationActivePart;

/// The host mirrors its FxPlug `isDragging` here each draw tick.
@property(nonatomic) BOOL dragging;

/// Optional persist override (see KKPositionOSC / KKScaleOSC): when set, a drag
/// writes via this block instead of the single `kKKParamTimelineData` param, so
/// a multi-owner host (Canvas) can route the write to the owning layer. Invoked
/// inside the control's open action scope.
@property(nonatomic, copy, nullable) void (^onTimelinePersist)
    (KKTimeline *timeline);

/// Sphere radius in canvas pixels. Default 90.
@property(nonatomic) float radius;

/// Ring fill half-width in pixels. Default 2.5.
@property(nonatomic) float ringHalfWidth;

/// Ring outline half-width (extra beyond fill) in pixels. Default 1.0.
@property(nonatomic) float outlineWidth;

/// Alpha multiplier applied to the back hemisphere of each ring. Default 0.3.
@property(nonatomic) float backDim;

/// Current rotation in radians. Order applied as R = Ry * Rx * Rz.
@property(nonatomic) float rotX;
@property(nonatomic) float rotY;
@property(nonatomic) float rotZ;

/// Per-axis ring colors. Default red / green / blue.
@property(nonatomic, strong) NSColor *colorX;
@property(nonatomic, strong) NSColor *colorY;
@property(nonatomic, strong) NSColor *colorZ;
@property(nonatomic, strong) NSColor *outlineColor;

/// Per-axis ring visibility (default YES). A hidden ring is neither drawn nor
/// hit-tested, letting the OSC-visibility popover suppress individual rings.
@property(nonatomic) BOOL showX;
@property(nonatomic) BOOL showY;
@property(nonatomic) BOOL showZ;

/// Per-axis ring alpha (default 1.0). A shown ring drawn at < 1.0 reads as a
/// dimmed "ghost" (used by opt-reveal to preview a hidden ring); still
/// hit-tested so an opt-click can re-show it.
@property(nonatomic) float ringAlphaX;
@property(nonatomic) float ringAlphaY;
@property(nonatomic) float ringAlphaZ;

/// 0 = X, 1 = Y, 2 = Z, -1 = none. Set by `hitTestAtMousePositionX:...`
/// and consumed by the draw call to highlight the grabbed ring + by
/// `angleDeltaFromPressPoint:currentPoint:` to choose the axis to rotate.
@property(nonatomic, readonly) NSInteger activeAxis;

/// Convert a screen-space drag (press → current, in canvas pixels) into the
/// rotation delta (radians) to apply to `activeAxis`. Projects the screen
/// displacement onto the ring's screen-space tangent at the press point,
/// then divides by radius. Returns 0 if no ring is active.
- (double)angleDeltaFromPressPoint:(CGPoint)pressPoint
                      currentPoint:(CGPoint)currentPoint;

/// High-level, self-contained API (requires `laneLabel`). The host forwards
/// these from its drawOSC / hitTest / mouse callbacks after setting `center`
/// (+ `dragging` each draw tick). They read the snapshot lane, gate on OSC
/// visibility + opt-reveal, and persist drags themselves.

/// Draw the rings, gated on the Rotation element's visibility (per-axis pills +
/// opt-reveal ghost). Reads the current pose + ring colours from the lane.
- (void)drawInDestination:(FxImageTile *)destinationImage
                   atTime:(CMTime)time
               activePart:(NSInteger)activePart;

/// Hit-test the rings. Returns the active axis (0=X,1=Y,2=Z) or -1. Sets the
/// rotate / visibility cursor on a hit. The host maps a non-negative result to
/// its rotation activePart.
- (NSInteger)hitTestRingAtX:(double)x y:(double)y atTime:(CMTime)time;

/// Forwarded mouse events. mouseDown must follow a hitTest (it reads the active
/// axis + captures the press pose from the nearest keypose).
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
