/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKArcOSC.h>
#import <KeyframelessKit/KKPointOSC.h>
#import <KeyframelessKit/KKSnapEngine.h>
#import <simd/simd.h>

@class KKLane;
@class KKTimeline;
@class KKOSCGuideBridge;

NS_ASSUME_NONNULL_BEGIN

/// Result of a Position hit-test. The host maps a non-None value to its own
/// `activePart` (Handle / AnchorDot both mean "the Position lane";
/// TangentHandle means "the motion-path tangent").
typedef NS_ENUM(NSInteger, KKPositionHit) {
  KKPositionHitNone = 0,
  KKPositionHitHandle = 1,       // the playhead arc handle
  KKPositionHitAnchorDot = 2,    // a keypose anchor dot (a Position target)
  KKPositionHitTangentHandle = 3 // an in/out tangent handle
};

/// Supplied by a plugin that runs an OSC guide over its Position handle.
/// nil = no guide; the handle reads the live timeline normally.
@protocol KKPositionGuideProvider <NSObject>
/// The per-process guide bridge (for `guideStep` + `handleHovered`).
- (KKOSCGuideBridge *)positionGuideBridge;
/// The live guide-pushed Position in object [0,1] space (the drawOSC tick can't
/// read the blob, so the inspector drag pushes it here).
- (CGPoint)positionGuideObjectValue;
@end

/// Reusable Position on-screen control: the playhead arc handle, the motion
/// path (line + keypose anchor dots + tangent handles), and all of their
/// drawing / hit-testing / drag / snap / smooth-toggle logic, keyed on a lane
/// label. It is itself a `KKOnScreenControl` (so it owns coordinate conversion,
/// the process timeline snapshot, the action-scope writer, and the visibility
/// helpers), but the host plugin's OSC stays the single FxPlug control and
/// forwards draw / hit-test / mouse to it - composing it alongside its own
/// controls (a ring, scale box, rotation rings, ...). See KKPositionOSC.m for
/// the host-forwarding contract.
@interface KKPositionOSC : KKArcOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         laneLabel:(NSString *)laneLabel
                         pathLabel:(NSString *)pathLabel;

/// The lane this control reads/writes (e.g. @"Position").
@property(nonatomic, copy) NSString *laneLabel;
/// The element key for the motion path (line / anchors / tangent handles), a
/// separately-hideable OSC element (e.g. @"Path").
@property(nonatomic, copy) NSString *pathLabel;

/// Lane template (from the host's `availableLanes`) used to build the lane when
/// a drag writes a Position that doesn't exist in the snapshot yet, so the new
/// lane keeps the plugin's exact metadata (units, spatial-curvable, ...).
@property(nonatomic, copy, nullable) KKLane *templateLane;

/// The host's `activePart` numbers for "this is the Position handle/anchor" and
/// "this is a tangent handle". The host sets these once so the controller can
/// gate its draw on the live activePart. Defaults 1 and 3.
@property(nonatomic) NSInteger positionActivePart;
@property(nonatomic) NSInteger tangentActivePart;

/// The host mirrors its FxPlug `isDragging` here each draw tick (the controller
/// doesn't receive FCP's mouse bookkeeping directly).
@property(nonatomic) BOOL dragging;

/// A 2D affine in OBJECT space (homogeneous 3x3) mapping the control's own lane
/// space to an enclosing parent's space - e.g. a Canvas member's clip space to
/// where its rotated/scaled/translated group actually draws it. Applied forward
/// to every drawn point (object -> parent -> canvas) and INVERTED on input
/// (canvas -> parent -> object), so the handle draws where the layer is
/// rendered AND a drag maps the cursor back through the parent (reacting to the
/// parent's rotation) instead of skewing or feeding back. Default identity.
@property(nonatomic) simd_float3x3 parentObjectTransform;

/// Optional ARBITRARY (possibly nonlinear) warp between the lane's value space
/// and object space, applied INSIDE the parent transform: lane -> warp ->
/// parent -> canvas on every drawn point (handle, motion-path samples, keypose
/// anchors, tangent endpoints - all point-mapped), and inverted on input.
/// `fraction` is the clip fraction the mapped point belongs to (the playhead
/// for the handle and drags, each sample's own time along the path), so a
/// warp referencing other ANIMATED values can follow them per sample. Set
/// BOTH or NEITHER (there is no numeric 2D inversion). Default nil = identity
/// (Shader wires these to a `// @osc` block's toPos/fromPos).
@property(nonatomic, copy, nullable) simd_float2 (^laneToObjectWarp)
    (simd_float2 laneValue, double fraction);
@property(nonatomic, copy, nullable) simd_float2 (^objectToLaneWarp)
    (simd_float2 objectPoint, double fraction);

/// nil = no guide.
@property(nonatomic, weak, nullable) id<KKPositionGuideProvider> guideProvider;

/// Optional persist override. When set, a drag/smooth/tangent edit calls this
/// with the updated timeline INSTEAD of writing the single
/// `kKKParamTimelineData` param - so a multi-owner host (e.g. Canvas, whose
/// layers each carry their own `animationJSON`) can route the write to the
/// owning layer. The block is invoked inside the host's OSC callback, so its
/// get/set API (same apiManager) resolves there. The lane carries
/// its owner via `layerKey`. nil = default single-param write
/// (single-param plugins unchanged).
@property(nonatomic, copy, nullable) void (^onTimelinePersist)
    (KKTimeline *timeline);

/// Optional persistent snap (e.g. a grid), applied to the dragged handle's
/// CANVAS point when Cmd is NOT held. The host returns the snapped canvas
/// point; the control converts it back to the lane value. Generic (canvas
/// space) so the Anchor control and a future pen tool reuse the same hook. nil
/// = no snap.
@property(nonatomic, copy, nullable) CGPoint (^canvasSnapProvider)
    (CGPoint canvasPoint);

/// Extra OBJECT-space snap targets (0..1, Y-up) folded into the Cmd-held snap
/// alongside the lane's own keyposes and the canvas anchors - so a host with
/// other position-like handles (e.g. Shader's point OSCs) can let this control
/// snap onto them. Each NSValue wraps a CGPoint. nil / empty = keyposes only.
/// Set fresh per drag; read on every snap tick.
@property(nonatomic, copy, nullable) NSArray<NSValue *> *externalSnapTargets;

/// Opt this control out of snapping entirely (the Cmd snap and any
/// canvasSnapProvider), for a host handle the user asked not to snap
/// (Shader's `skipsnapping`). Default NO.
@property(nonatomic) BOOL snapDisabled;

/// Set by the hit-test: YES when the hovered Position target is a keypose
/// anchor dot rather than the playhead arc handle (both report Handle/AnchorDot
/// to the host). The host reads this for element-key mapping (anchor -> Path).
@property(nonatomic, readonly) BOOL hoverTargetIsAnchor;

/// Owned glyphs (exposed so the host can restyle them).
@property(nonatomic, readonly) KKPointOSC *anchorDotOSC;  // keypose dots
@property(nonatomic, readonly) KKPointOSC *tangentDotOSC; // tangent dots
@property(nonatomic, readonly) KKSnapEngine *snapEngine;

/// Canvas-space point of the Position handle at `time` (the playhead value, or
/// the guide-pushed value during a guide). The host's other controls (rotation,
/// scale, anchor pivot) centre on this.
- (CGPoint)positionCanvasAtTime:(CMTime)time;

/// Draw the motion path (line + tangent handles + keypose anchor dots). Drawn
/// FIRST (under the host's other controls). Split from the handle draw so the
/// host can interleave its own controls between them at the right z-order.
- (void)drawPathInDestination:(FxImageTile *)destinationImage
                       atTime:(CMTime)time
                   activePart:(NSInteger)activePart;
/// Draw the playhead arc handle (+ the Cmd-snap guides during a Position drag).
/// Drawn LAST (over the host's other controls).
- (void)drawHandleInDestination:(FxImageTile *)destinationImage
                         atTime:(CMTime)time
                     activePart:(NSInteger)activePart;

/// Hit-test the Position elements (tangent handle, arc handle, anchor dot - in
/// that precedence). Sets the viewer cursor on a hit. The host calls this in
/// its own precedence chain and maps the result to its activePart.
- (KKPositionHit)hitTestAtX:(double)x y:(double)y atTime:(CMTime)time;

/// Forwarded mouse events. The host calls these when its activePart is in the
/// Position range. `hit` distinguishes the handle/anchor (a value drag) from a
/// tangent handle (a curve edit).
- (void)mouseDownAtX:(double)x
                   y:(double)y
                 hit:(KKPositionHit)hit
           modifiers:(NSUInteger)modifiers
         forceUpdate:(BOOL *)forceUpdate
              atTime:(CMTime)time;
- (void)mouseDraggedAtX:(double)x
                      y:(double)y
                    hit:(KKPositionHit)hit
              modifiers:(NSUInteger)modifiers
            forceUpdate:(BOOL *)forceUpdate
                 atTime:(CMTime)time;
- (void)mouseUp;

@end

NS_ASSUME_NONNULL_END
