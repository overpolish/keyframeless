/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>
#import <KeyframelessKit/KKSquarePointOSC.h>
#import <simd/simd.h>

@class KKLane;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Reusable Anchor-point on-screen control: the small square at the pivot that
/// rotation and scale swing around, drawn over the other transform controls. It
/// reads a 2-component anchor lane (normalized content space, 0.5,0.5 = content
/// centre) from the process timeline snapshot, owns its draw / hit-test / delta
/// drag / Cmd-snap / persist, and gates on the shared OSC-visibility state - the
/// same self-contained shape as KKScaleOSC / KKRotationOSC.
///
/// By default the pivot is in CLIP space: the content centre is the sibling
/// `positionLaneLabel` value (0.5,0.5 = clip centre), and the pivot is that
/// shifted by the Anchor offset, mapped through the OSC API's OBJECT<->CANVAS
/// convert - the common case for a single-clip plugin and a per-layer Canvas
/// selection. A host with non-standard geometry (a group whose pivot is its
/// content bbox centre, a composed 3D transform) overrides this by setting
/// `anchorToCanvas` / `canvasToAnchor`. Snapping (Cmd) is done in canvas space
/// against the content's own features (centre / corners / edge-midpoints /
/// thirds), so it works under any host geometry including rotation.
///
/// Drag is delta-based: the anchor value moves by the cursor's offset in anchor
/// space from the grab point (grabbing off-centre never jumps the pivot to the
/// cursor). **Cmd** engages snapping.
@interface KKAnchorOSC : KKOnScreenControl

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         laneLabel:(NSString *)laneLabel;

/// The 2-component anchor lane this control reads/writes (e.g. @"Anchor").
@property(nonatomic, copy) NSString *laneLabel;

/// Lane template (from the host's `availableLanes`) used to build the lane when
/// a drag writes an Anchor that doesn't exist in the snapshot yet, so the new
/// lane keeps the plugin's exact metadata (units, scale-with-media, ...).
@property(nonatomic, copy, nullable) KKLane *templateLane;

/// The host's `activePart` number for "this is the anchor square". The host sets
/// it once so the controller can gate its draw highlight + drag on the live
/// activePart. Default 5.
@property(nonatomic) NSInteger anchorActivePart;

/// The host mirrors its FxPlug `isDragging` here each draw tick.
@property(nonatomic) BOOL dragging;

/// The sibling lane whose value is the content centre the default clip-space
/// pivot shifts from (e.g. @"Position"). Default @"Position". Ignored when
/// `anchorToCanvas` / `canvasToAnchor` are set.
@property(nonatomic, copy) NSString *positionLaneLabel;

/// Override the default clip-space geometry: map an anchor value (lane
/// components; 0.5,0.5 = content centre) to a canvas point. Set both this and
/// `canvasToAnchor` together (a host with non-standard pivot geometry).
@property(nonatomic, copy, nullable) CGPoint (^anchorToCanvas)(double ax,
                                                               double ay);

/// Inverse of `anchorToCanvas`: map a canvas point back to an anchor value (for
/// the delta drag + snap). Set together with `anchorToCanvas`.
@property(nonatomic, copy, nullable) void (^canvasToAnchor)(CGPoint canvasPoint,
                                                            double *outAX,
                                                            double *outAY);

/// Optional persist override (see KKScaleOSC): when set, a drag writes via this
/// block instead of the single `kKKParamTimelineData` param, so a multi-owner
/// host (Canvas) can route the write to the owning layer. Invoked inside the
/// control's open action scope.
@property(nonatomic, copy, nullable) void (^onTimelinePersist)
    (KKTimeline *timeline);

/// A 2D affine in OBJECT space (homogeneous 3x3) mapping the anchor's own clip
/// space to an enclosing parent's space (e.g. a Canvas member's group). Applied
/// forward to the default pivot before mapping to canvas, and INVERTED on a drag,
/// so the square draws where the layer is rendered and dragging reacts to the
/// parent's rotation/scale instead of skewing or feeding back. Ignored when the
/// `anchorToCanvas` / `canvasToAnchor` blocks are set. Default identity.
@property(nonatomic) simd_float3x3 parentObjectTransform;

/// The owned square (exposed so the host can tune size / hit radius).
@property(nonatomic, readonly) KKSquarePointOSC *square;

/// The clip-local fraction the control is currently evaluating. Set internally
/// just before each `anchorToCanvas` / `canvasToAnchor` call, so a host whose
/// geometry depends on the playhead (animated Position / transform) can read the
/// matching fraction from inside its blocks.
@property(nonatomic, readonly) double evalFraction;

/// Draw the anchor square, gated on the Anchor element's visibility (+ opt-reveal
/// ghost) and the lane being visible at this fraction. Draws snap guides while
/// dragging with Cmd. The host calls this in its drawOSC tick after setting
/// `anchorToCanvas` + `dragging`.
- (void)drawInDestination:(FxImageTile *)destinationImage
                   atTime:(CMTime)time
               activePart:(NSInteger)activePart;

/// Hit-test the square. Returns `anchorActivePart` on a hit, else -1. Sets the
/// move / visibility cursor on a hit.
- (NSInteger)hitTestAtX:(double)x y:(double)y atTime:(CMTime)time;

/// Forwarded mouse events. The host calls these when its activePart is the
/// anchor square. mouseDown must follow a hitTest.
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
