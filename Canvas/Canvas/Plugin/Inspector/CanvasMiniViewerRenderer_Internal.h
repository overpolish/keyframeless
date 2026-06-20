/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasMiniViewerRenderer.h"
#import "CanvasPenController.h" // CanvasPenSurface + shared pen state machine
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KKToolbar;

@interface CanvasMiniViewerRenderer ()
// Shared pen state machine; this renderer is its surface (CanvasMiniViewerRenderer
// +Pen.m implements CanvasPenSurface). Set in -init.
@property(nonatomic, strong) CanvasPenController *penController;
// The content rect (overlay view points) of the in-flight pen input / draw, so
// the surface coordinate methods can convert without it being threaded through.
@property(nonatomic) CGRect penContentRect;
// The canvas during a pen overlay draw, so the surface draw primitives can encode
// dots / lines via its armed Metal encoder. Set only inside the draw hook.
@property(nonatomic, weak) KKMiniViewerView *penDrawCanvas;
// View point (overlay y-up) -> normalized member value (Position space, Y-down),
// through the inverse group homography. Used by the pen surface (it flips to the
// Y-up KKBezierPath space).
- (simd_float2)_memberValueForViewPoint:(CGPoint)vp contentRect:(CGRect)cr;
// Output dims of the last composite (= the rendered frame size), captured in
// -encodeEffectFromSource:. The grid spacing is in these output pixels, so the
// mini grid lands on the same cells as the viewer.
@property(nonatomic) CGFloat renderWidth;
@property(nonatomic) CGFloat renderHeight;
// The exact normalized cell size the grid LAST drew (after Auto). The snap reuses
// it so it can't diverge from the drawn lines (0 = not drawn yet).
@property(nonatomic) double drawnGridNX;
@property(nonatomic) double drawnGridNY;
// The mini's own toolbar instance (the SAME bar as the viewer, built by the
// shared CanvasMakeToolbar). State is driven per-draw from the shared kParamUIState
// the inspector mirrors onto this renderer; it's drawn via the kit's toolbar hook.
@property(nonatomic, strong) KKToolbar *toolbar;
// Drag-handle press state (drawable px, y-down layout space).
@property(nonatomic) CGPoint toolbarPressMouse;
@property(nonatomic) CGPoint toolbarPressAnchor;
@property(nonatomic) BOOL toolbarDragging;
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
// Snap a normalized object point to the grid (no-op unless gridSnap). Used by the
// Position/Anchor mini controllers' grid-snap blocks.
- (simd_float2)_snapNormalizedPointToGrid:(simd_float2)p
                              contentRect:(CGRect)cr;
@end

@interface CanvasMiniViewerRenderer (Interaction)
// The layer auto-select would pick at `p` (or nil): topmost selectable image
// layer under the cursor, honoring autoSelectEnabled + nonSelectableLayerIDs.
// Shared by the background-click selector and the hover cursor.
- (nullable NSString *)_autoSelectLayerAtPoint:(CGPoint)p
                                   contentRect:(CGRect)cr;
@end

// The mini is the drawing SURFACE for the shared pen controller: it implements
// the CanvasPenSurface coords/blob/draw primitives (CoreGraphics) and the kit's
// tool-drawing delegate hooks (forwarding to the controller).
@interface CanvasMiniViewerRenderer (Pen) <CanvasPenSurface>
@end

NS_ASSUME_NONNULL_END
