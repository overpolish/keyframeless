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

/// Reusable mini-viewer Anchor controller: the mini sibling of the viewer-side
/// `KKAnchorOSC`. A `KKMiniViewerRenderer` subclass owns one of these and
/// forwards the anchor-square hooks (centre + hit-test + drag) to it, so any
/// plugin with a 2D Anchor lane gets the pivot square in the mini-viewer for
/// free. The base `KKMiniViewerView` already DRAWS the square (via the
/// renderer's `miniViewer:anchorSquareCenter:contentRect:` + `anchorSquareGhost
/// Alpha` delegate) - the host just proxies those to this controller.
///
/// Composition, not inheritance: the controller holds a weak back-ref to the
/// renderer and calls its public hooks (`valuesForLabel:`, `commitValues:for
/// Label:canvas:`, `isConstantLabel:`, `labelVisibleOrRevealing:`,
/// `ghostAlphaForLabel:`, `handlePointForContentRect:position:`). The pivot is
/// the content centre (the sibling `positionLaneLabel` value) shifted by the
/// Anchor offset, mapped to overlay points - mirroring the viewer's default
/// clip-space geometry.
///
/// Drag is delta-based (the value moves by the cursor's normalised offset from
/// the grab point). **Cmd** snaps the pivot to the content's centre / corners /
/// edge-midpoints / thirds through the shared snap engine, so the canvas strokes
/// the same yellow guide lines as a Position drag.
@interface KKAnchorMiniController : NSObject

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer
                       laneLabel:(NSString *)laneLabel
               positionLaneLabel:(NSString *)positionLaneLabel
                      snapEngine:(KKSnapEngine *)snapEngine
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, weak, readonly) KKMiniViewerRenderer *renderer;
@property(nonatomic, copy, readonly) NSString *laneLabel;
@property(nonatomic, copy, readonly) NSString *positionLaneLabel;
/// YES while the square is being dragged.
@property(nonatomic, readonly) BOOL isDragging;

/// Optional override for the square's overlay-point centre (e.g. a Canvas member
/// inside a transformed group, where the pivot is the group-composed point).
/// When set, it replaces the default content-space pivot for both drawing and
/// hit-testing; the drag still writes the lane value in content space (flat).
@property(nonatomic, copy, nullable) CGPoint (^centerOverride)(CGRect contentRect);

/// Optional grid snap applied when Cmd is NOT held (Cmd still snaps to the
/// content's own centre/corners). The host snaps the anchor PIVOT - a normalized
/// object point - to the grid; the controller converts it back to the anchor
/// offset. nil = no grid snap. Mirrors the viewer Anchor OSC's canvasSnapProvider.
@property(nonatomic, copy, nullable) simd_float2 (^gridSnapPivot)
    (simd_float2 normalizedPivot, CGRect contentRect);

/// Optional map from a content-rect view point to the member-local normalized
/// value (inverse of the draw transform), so a drag follows the cursor when the
/// pivot is drawn through a parent/group transform. nil = plain normalization.
@property(nonatomic, copy, nullable) simd_float2 (^viewToValue)
    (CGPoint viewPoint, CGRect contentRect);

/// Hit-test half-extent for the square in points (Chebyshev), at the baseline
/// popover size; scales with the popover. Default 5.0. A host whose anchor pivot
/// can coincide with a larger Position handle (so the handle would otherwise
/// swallow it) can shrink this so the anchor keeps a tight central grab zone and
/// the Position ring around it stays clickable.
@property(nonatomic) CGFloat hitRadiusPt;

/// Whether the square is shown this tick: the Anchor lane is a constant in the
/// current popover mode and visible (or opt-revealing).
- (BOOL)squareShown;
/// Draw alpha for the square (1.0 normally, dimmed when opt-revealing a ghost).
- (CGFloat)ghostAlpha;
/// The pivot square centre in overlay points. NO if the square isn't shown.
- (BOOL)squareCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr;

/// YES if `p` lands on the square (and it is shown).
- (BOOL)squareHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Try to grab the square at `p`. YES if claimed (sets `isDragging`); the host
/// should not fall through to its own controls.
- (BOOL)beginDragAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Live-update the grabbed square. Caller gates on `isDragging`.
- (void)applyDragToPoint:(CGPoint)p
             contentRect:(CGRect)cr
               modifiers:(NSEventModifierFlags)modifiers
                  canvas:(KKMiniViewerView *)canvas;
/// End the drag (clears `isDragging`).
- (void)endDrag;

@end

NS_ASSUME_NONNULL_END
