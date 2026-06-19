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
