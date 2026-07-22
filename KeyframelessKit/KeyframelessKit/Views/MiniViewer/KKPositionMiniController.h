/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKMiniViewerView.h>

@class KKSnapEngine;

NS_ASSUME_NONNULL_BEGIN

/// Reusable mini-viewer Position controller: the spatial-curve sibling of the
/// viewer-side `KKPositionOSC`. A `KKMiniViewerRenderer` subclass owns one of
/// these and forwards the Position point-handle hooks + the motion-path
/// (keypose anchors / tangent handles) interaction to it, so any plugin with a
/// 2D Position lane gets curved drag, snapping, and the motion-path overlay for
/// free.
///
/// Composition, not inheritance: the controller holds a weak back-ref to the
/// renderer and calls its public hooks (`timeline`, `valuesForLabel:`,
/// `commitValues:forLabel:canvas:`, `labelVisibleOrRevealing:`,
/// `ghostAlphaForLabel:`, `handlePointForContentRect:position:`,
/// `editFraction`, `boundaryEditing`, `onTimelinePersist`). It owns the whole
/// Position + Path drag-state machine and the shared `KKSnapEngine`.
///
/// The host renderer keeps the dispatch glue (interleaving its own scale /
/// anchor / crop / rotation controls at the right precedence) and forwards:
/// - the base point-handle overrides (`pointHandleHitAtPoint:`,
///   `pointHandleCenter:forContentRect:`, `applyPointDragToPoint:…`) to the
///   `position…` methods here, since the base drives the point-handle grab
///   lifecycle;
/// - the path anchors / tangent handles fully to the `path…` methods here.
@interface KKPositionMiniController : NSObject

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer
                       laneLabel:(NSString *)laneLabel
                       pathLabel:(NSString *)pathLabel
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, weak, readonly) KKMiniViewerRenderer *renderer;
@property(nonatomic, copy, readonly) NSString *laneLabel;
@property(nonatomic, copy, readonly) NSString *pathLabel;
/// Shared snap engine (Position, Path, and the host's own anchor drag all feed
/// it so the canvas strokes one set of guide lines). Read by the host's
/// `snapGuideHasX:…` reporter and its anchor drag.
@property(nonatomic, readonly) KKSnapEngine *snapEngine;

/// Optional grid snap applied to the dragged normalized value when Cmd is NOT
/// held (Cmd still does the centre/corner/keypose snap). The host returns the
/// snapped value for the given content rect; nil = no grid snap. Mirrors the
/// viewer Position OSC's `canvasSnapProvider`.
@property(nonatomic, copy, nullable) simd_float2 (^gridSnapValue)
    (simd_float2 normalizedValue, CGRect contentRect);

/// Optional map from a content-rect view point to the member-local normalized
/// value (the inverse of how the handle is drawn). Set by a host whose handle
/// is drawn through a parent transform (a Canvas member in a transformed group)
/// so a drag follows the cursor instead of drifting. nil = the plain
/// content-rect normalization. Mirrors the viewer Position OSC's
/// `_objFromCanvasX` inverse.
@property(nonatomic, copy, nullable) simd_float2 (^viewToValue)
    (CGPoint viewPoint, CGRect contentRect);

/// Optional ARBITRARY warp between the lane's value space and the drawn
/// object space (mirrors the viewer KKPositionOSC's warp pair): applied to
/// every drawn point (handle, path samples, anchors, tangent endpoints) and
/// inverted on drags. `fraction` = the mapped point's clip fraction (the edit
/// fraction for the handle/drags, each sample's own time along the path). Set
/// BOTH or NEITHER. nil = identity.
@property(nonatomic, copy, nullable) simd_float2 (^laneToObjectWarp)
    (simd_float2 laneValue, double fraction);
@property(nonatomic, copy, nullable) simd_float2 (^objectToLaneWarp)
    (simd_float2 objectPoint, double fraction);

/// Extra normalized-value snap targets (0..1) folded into the Cmd snap
/// alongside the lane's keyposes and the canvas anchors - so the host can let
/// this position handle snap onto other handles (Shader's point OSCs). Each
/// NSValue wraps a CGPoint. Set fresh per drag. Mirrors the viewer
/// KKPositionOSC's `externalSnapTargets`.
@property(nonatomic, copy, nullable) NSArray<NSValue *> *externalSnapTargets;

/// Opt this handle out of snapping entirely (Cmd snap + grid), for a control
/// the user asked not to snap (Shader's `skipsnapping`). Default NO.
@property(nonatomic) BOOL snapDisabled;

/// YES while a Position handle or a Path anchor/tangent is being dragged.
@property(nonatomic, readonly) BOOL isDragging;
/// YES while a Path anchor/tangent (not the Position handle) is being dragged.
@property(nonatomic, readonly) BOOL pathGrabbed;

#pragma mark Position point handle (forwarded from the base point-handle hooks)

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr;
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                forValues:(NSArray<NSNumber *> *)values
           forContentRect:(CGRect)cr;
/// YES if `p` grabs the Position handle (only when its label is visible /
/// revealing, so a hidden handle never eats the keypose dot beneath it).
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Capture the press normals + grabbed value (call on point-drag begin).
- (void)beginPointDragAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Delta drag with Shift axis-lock + Cmd snap; commits to the Position lane.
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers;

#pragma mark Motion-path overlay (keypose anchors + tangent handles)

- (NSArray<NSValue *> *)motionPathPolylineForContentRect:(CGRect)cr;
- (NSArray<NSValue *> *)motionPathAnchorsForContentRect:(CGRect)cr;
- (NSArray<NSValue *> *)motionPathHandleSegmentsForContentRect:(CGRect)cr;

/// YES if `p` lands on a tangent handle of a smooth keypose.
- (BOOL)pathHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// YES if `p` lands on a (non-active) keypose anchor dot.
- (BOOL)pathAnchorHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Try to grab a tangent handle or anchor at `p`. YES if claimed (sets
/// `pathGrabbed`); the host should not fall through to its own controls.
- (BOOL)beginPathDragAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Live-update the grabbed anchor/tangent. Caller gates on `pathGrabbed`.
- (void)applyPathDragToPoint:(CGPoint)p
                 contentRect:(CGRect)cr
                   modifiers:(NSEventModifierFlags)modifiers;
/// Toggle the smooth flag of the keypose under `p` (its anchor dot or the
/// active Position handle). YES if a keypose was toggled (persisted).
- (BOOL)toggleSmoothAtPoint:(CGPoint)p contentRect:(CGRect)cr;

/// End any Position/Path drag: reset the snap engine. YES if a Path drag was
/// active (so the host persists the full blob).
- (BOOL)endDrag;

/// Snap-guide read-back for the canvas (proxies the shared snap engine).
- (void)snapGuideHasX:(out BOOL *)hasX
                    X:(out CGFloat *)outX
         fromKeyposeX:(out BOOL *)fromKeyposeX
                 hasY:(out BOOL *)hasY
                    Y:(out CGFloat *)outY
         fromKeyposeY:(out BOOL *)fromKeyposeY;

@end

NS_ASSUME_NONNULL_END
