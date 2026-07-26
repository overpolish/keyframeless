/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKMiniViewerView.h>

@class KKLane;

NS_ASSUME_NONNULL_BEGIN

/// Manages the mini-viewer siblings of the viewer's custom `// @osc` controls
/// (MirageOSC's expr blocks). A `point` block is a fixed glyph at the block's
/// forward-expression object point, dragged by numerically inverting the
/// forward (or evaluating its explicit inverse); a `ring` block is a
/// value-sized radius ring at its `center` with its `toR` radii, dragged
/// through the runtime's shared ring mechanic - the SAME MirageOSCBlockRuntime
/// the viewer uses, so both sit and drag identically. Reads/writes the host
/// through KKMiniViewerRenderer's public hooks. The mini analogue of the
/// viewer's expr-control loop in MirageOSC, and the `// @osc` cousin of
/// KKRingOSCSet.
@interface MirageExprMiniSet : NSObject

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer;

/// Rebuild from the shader source (parse + compile via MirageOSCBlockRuntime).
/// Cheap string-compare no-op when unchanged. `lanes` seed a first write.
- (void)syncWithSource:(nullable NSString *)src
                 lanes:(NSArray<KKLane *> *)lanes;

/// `@{@"center", @"style", @"alpha"}` bundles for the active POINT handles.
/// Forward -miniViewer:extraFixedGlyphsForContentRect: here.
- (NSArray<NSDictionary<NSString *, id> *> *)glyphBundlesForContentRect:
    (CGRect)cr;

/// `@{@"center", @"radiusX", @"radiusY", @"emphasis", @"alpha"}` bundles for
/// the active RING blocks (same shape as KKRingOSCSet's). Merge into
/// -miniViewer:extraRingsForContentRect:.
- (NSArray<NSDictionary<NSString *, id> *> *)ringBundlesForContentRect:
    (CGRect)cr;

/// One KKMiniBox (rect + 8 handles + readout) per active BOX block. Merge
/// into -miniViewer:boxesForContentRect:. `mediaSize` = the canvas's
/// sourceMediaSize; a crop-style (vec4) box shows its rect in source px with
/// it, matching the viewer (zero size = no px readout).
- (NSArray<KKMiniBox *> *)boxesForContentRect:(CGRect)cr
                                    mediaSize:(CGSize)mediaSize;

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Is a POINT GLYPH under `p`? Narrower than -handleHitAtPoint: (no rings, no
/// boxes), so the host can give glyphs precedence over the position set. A
/// position hit-tests as a filled disc even though it draws as an arc, so a
/// glyph parked at the same spot - an anchor at the pivot - is otherwise
/// unreachable. Pure query; nothing is primed or claimed.
- (BOOL)glyphHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (nullable NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Grab whatever handle is under `p`. YES if claimed (host should NOT fall
/// through to super).
- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas;
/// Live-update the active drag (`modifiers` feeds the ring mechanic's Shift
/// aspect-lock invert). YES if a drag is active.
- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers;
/// End the active drag. YES if a drag was active.
- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas;
/// Opt-click to hide the handle under `p`. YES if one toggled.
- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas;

/// YES while a POINT handle that snaps (not `skipsnapping`) is being dragged -
/// the interaction routes the snap-guide query here rather than to the position
/// set.
@property(nonatomic, readonly) BOOL draggingSnapPoint;

/// The active point drag's snap-guide state, in normalized value space
/// (matching KKPositionMiniController's reporter). `fromKeypose*` = the axis
/// snapped to another handle (accent/blue) rather than a canvas anchor
/// (yellow).
- (void)snapGuideHasX:(out BOOL *)hasX
                    X:(out CGFloat *)outX
         fromKeyposeX:(out BOOL *)fromKeyposeX
                 hasY:(out BOOL *)hasY
                    Y:(out CGFloat *)outY
         fromKeyposeY:(out BOOL *)fromKeyposeY;

/// Every POINT handle's normalized value position (0..1), so the position set
/// can snap onto them (its `externalSnapTargets`). CGPoint-wrapped.
- (NSArray<NSValue *> *)pointHandleValuePositionsForContentRect:(CGRect)cr;

@end

NS_ASSUME_NONNULL_END
