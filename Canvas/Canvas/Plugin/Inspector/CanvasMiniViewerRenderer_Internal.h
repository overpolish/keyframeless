/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasMiniViewerRenderer.h"
#import "CanvasPathEditController.h" // shared path anchor/handle editing
#import "CanvasPenController.h"   // CanvasPenSurface + shared pen state machine
#import "CanvasShapeController.h" // shared rect/ellipse drag-create tool
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KKToolbar;

@interface CanvasMiniViewerRenderer ()
// The full multi-selection (or the single primary as a fallback). Shared with
// the +Interaction category for Shift / Cmd-click multi-select.
- (NSArray<NSString *> *)_miniSelectedIDs;
// Shared pen state machine; this renderer is its surface
// (CanvasMiniViewerRenderer +Pen.m implements CanvasPenSurface). Set in -init.
@property(nonatomic, strong) CanvasPenController *penController;
// Shared anchor/handle editor for the selected path (this renderer is its
// surface via the same CanvasPenSurface the pen uses).
@property(nonatomic, strong) CanvasPathEditController *pathEditController;
// Shared rect/ellipse drag-create tool (same CanvasPenSurface).
@property(nonatomic, strong) CanvasShapeController *shapeController;
// The content rect (overlay view points) of the in-flight pen input / draw, so
// the surface coordinate methods can convert without it being threaded through.
@property(nonatomic) CGRect penContentRect;
// The canvas during a pen overlay draw, so the surface draw primitives can
// encode dots / lines via its armed Metal encoder. Set only inside the draw
// hook.
@property(nonatomic, weak) KKMiniViewerView *penDrawCanvas;
// View point (overlay y-up) -> normalized member value (Position space,
// Y-down), through the inverse group homography. Used by the pen surface (it
// flips to the Y-up KKBezierPath space).
- (simd_float2)_memberValueForViewPoint:(CGPoint)vp contentRect:(CGRect)cr;
// Output dims of the last composite (= the rendered frame size), captured in
// -encodeEffectFromSource:. The grid spacing is in these output pixels, so the
// mini grid lands on the same cells as the viewer.
@property(nonatomic) CGFloat renderWidth;
@property(nonatomic) CGFloat renderHeight;
// The TRUE render output size in pixels (the full-frame feed source, not the
// small preview dest). Path ops that bake px-relative geometry (stroke-to-
// outline) convert against this so the result matches the main render at any
// project resolution. 0 until the first frame is composited.
@property(nonatomic) CGFloat outputWidth;
@property(nonatomic) CGFloat outputHeight;
// The exact normalized cell size the grid LAST drew (after Auto). The snap
// reuses it so it can't diverge from the drawn lines (0 = not drawn yet).
@property(nonatomic) double drawnGridNX;
@property(nonatomic) double drawnGridNY;
// The mini's own toolbar instance (the SAME bar as the viewer, built by the
// shared CanvasMakeToolbar). State is driven per-draw from the shared
// kParamUIState the inspector mirrors onto this renderer; it's drawn via the
// kit's toolbar hook.
@property(nonatomic, strong) KKToolbar *toolbar;
// The conditional path-op groups the current bar was built with, so draw rebuilds
// it only when the selection crosses the show/hide threshold (KKToolbar's items
// are fixed at init - same as the viewer).
@property(nonatomic) BOOL toolbarShowsBooleans;
@property(nonatomic) BOOL toolbarShowsOutline;
// Drag-handle press state (drawable px, y-down layout space).
@property(nonatomic) CGPoint toolbarPressMouse;
@property(nonatomic) CGPoint toolbarPressAnchor;
@property(nonatomic) BOOL toolbarDragging;
// Body-drag move state (mirrors the viewer's): the selected layer the press
// landed on, the Y-up object point at press, the pre-drag layer stack (each tick
// translates from this, not cumulatively), and whether a real drag happened
// (else the up is a plain click = select).
@property(nonatomic) BOOL layerMoveActive;
@property(nonatomic, copy, nullable) NSString *layerMoveHitID;
@property(nonatomic) CGPoint layerMoveStartObj;
@property(nonatomic, copy, nullable) NSArray<KKBezierPath *> *layerMoveStartLayers;
@property(nonatomic) BOOL layerMoveDidMove;
// Reusable Position + motion-path controller (owns the shared snap engine and
// the whole Position/Path drag-state machine). Canvas has no anchor / rotation
// in the mini, so Position is the only point handle.
@property(nonatomic, strong) KKPositionMiniController *positionMini;
// Reusable Scale transform-box controller (geometry + hit-test + drag).
@property(nonatomic, strong) KKScaleMiniController *scaleMini;
// Reusable Anchor-square controller (centre + hit-test + delta drag + Cmd-snap,
// sharing the Position controller's snap engine).
@property(nonatomic, strong) KKAnchorMiniController *anchorMini;
// Position handle centre for a content rect (proxies the base helper); called
// across the Interaction category.
- (CGPoint)_handlePointForContentRect:(CGRect)cr
                             position:(NSArray<NSNumber *> *)pos;
// Member-local ANCHOR pivot (Position + Anchor) in overlay points - the centre
// the rotation rings / scale box / anchor square share.
- (CGPoint)_anchorPivotForContentRect:(CGRect)cr;
// Snap a normalized object point to the grid (no-op unless gridSnap). Used by
// the Position/Anchor mini controllers' grid-snap blocks.
- (simd_float2)_snapNormalizedPointToGrid:(simd_float2)p contentRect:(CGRect)cr;
@end

@interface CanvasMiniViewerRenderer (Interaction)
// The layer auto-select would pick at `p` (or nil): topmost selectable image
// layer under the cursor, honoring autoSelectEnabled + nonSelectableLayerIDs.
// Shared by the background-click selector and the hover cursor.
- (nullable NSString *)_autoSelectLayerAtPoint:(CGPoint)p
                                   contentRect:(CGRect)cr;
// Transform handles (incl. the rotation rings) show only for a lone image/group
// under the cursor tool. Gates the rotationLabel opt-in too (see the main .m).
- (BOOL)_transformHandlesActive;
// Cursor-tool gesture helpers, shared between the hover cursor / modifier
// delegates (Interaction) and the drag lifecycle (Gesture category): the
// path-edit context gate, any/under-cursor layer picks, and the empty-canvas
// marquee allowance.
- (BOOL)_pathEditContext;
- (nullable NSString *)_anyLayerAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (nullable NSString *)_selectedLayerUnderPoint:(CGPoint)p
                                    contentRect:(CGRect)cr;
- (BOOL)_layerMarqueeAllowedAtPoint:(CGPoint)p contentRect:(CGRect)cr;
// Position point-handle hit-test + drag, used by the Gesture lifecycle.
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas
                    modifiers:(NSEventModifierFlags)modifiers;
@end

// The mini is the drawing SURFACE for the shared pen controller: it implements
// the CanvasPenSurface coords/blob/draw primitives (CoreGraphics) and the kit's
// tool-drawing delegate hooks (forwarding to the controller).
@interface CanvasMiniViewerRenderer (Pen) <CanvasPenSurface>
@end

// Rect / ellipse drag-create on the mini: the tool-drawing delegate hooks (in
// the Pen category) forward to the shared shape controller via these.
@interface CanvasMiniViewerRenderer (Shape)
- (BOOL)_shapeToolActive;
// Sync the controller's kind to the live toolbar tool before each gesture.
- (void)_syncShapeKind;
@end

NS_ASSUME_NONNULL_END
