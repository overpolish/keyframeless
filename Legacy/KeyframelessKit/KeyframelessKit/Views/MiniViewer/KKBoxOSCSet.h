/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKRadialOSCSet.h>

NS_ASSUME_NONNULL_BEGIN

/// Manages 1..N mini-viewer box OSCs at once - the box sibling of KKRingOSCSet
/// and the mini analogue of the viewer's KKBoxOSC. A box is the ring's twin: it
/// encodes a `#float`/`#percent`/`#int`/vec2 `#multi` field NORMALIZED 0..1
/// through the SAME KKRingOSCExtentForNorm curve, so a box and a ring for the
/// same field are the same size - but it is a real box (border + 8 handles + a
/// value readout, drawn through KKMiniViewerView's shared `KKMiniBox` path)
/// that is edited by dragging a handle. A scalar box is a square; a vec2 #multi
/// box is a rectangle.
///
/// Reads/writes the host through KKMiniViewerRenderer's public hooks
/// (`valuesForLabel:`, `commitValues:forLabel:canvas:`, `isConstantLabel:`,
/// `labelVisibleOrRevealing:`, `ghostAlphaForLabel:`,
/// `handlePointForContentRect:position:`, `nearestHandleIndexToPoint:...`,
/// `templateLaneForLabel:`, `onHandleVisibilityToggled`), so a plugin whose
/// renderer exposes several `osc=box` lanes owns one of these and forwards its
/// box-draw + generic handle interaction delegate methods here.
@interface KKBoxOSCSet : KKRadialOSCSet

/// Rebuild the boxes. Each spec is a dict: `@"label"` (NSString, lane
/// identity),
/// `@"min"`/`@"max"` (NSNumber, the value range normalized over), `@"isInt"`
/// (NSNumber bool, rounds the written value), `@"isPercent"` (NSNumber bool,
/// "%" readout), `@"bounded"` (NSNumber bool, clamp to max), `@"fields"`
/// (NSNumber int, 1 = square / 2 = rectangle), `@"linked"` (NSNumber bool,
/// aspect-lockable #multi), `@"centerX"`/`@"centerY"` (NSNumber, box centre in
/// object space 0..1), `@"linkLabel"` (NSString, a #point uniform the centre
/// follows). Cheap no-op when unchanged; preserves drag state for surviving
/// labels.
- (void)setBoxes:(NSArray<NSDictionary<NSString *, id> *> *)boxes;

/// One KKMiniBox (rect + 8 handles + readout) per box active in the current
/// context. Forward -miniViewer:boxesForContentRect: here (merge with any other
/// boxes the renderer draws).
- (NSArray<KKMiniBox *> *)boxesForContentRect:(CGRect)cr;

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (nullable NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Grab whatever box handle is under `p`. YES if claimed (host must NOT fall
/// through to super).
- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas;
/// Live-update the active drag. YES if a drag is active.
- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers;
/// End the active drag. YES if a drag was active.
- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas;
/// Opt-click to hide the box under `p`. YES if one toggled (or claimed the
/// hit).
- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas;

@end

NS_ASSUME_NONNULL_END
