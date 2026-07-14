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

/// Manages 1..N mini-viewer radius-ring OSCs at once - the mini sibling of a
/// viewer that draws every KKRingOSC in a loop. A plugin whose renderer exposes
/// several ring OSCs (e.g. Shader's `osc=ring` scalar lanes) owns one of these,
/// feeds it the ring specs, and forwards its ring-draw + generic handle
/// interaction delegate methods to the matching call here. There is no
/// "primary" ring: every ring draws through
/// `-miniViewer:extraRingsForContentRect:` and drags through one shared
/// active-label, so N rings behave identically. The mini sibling of the
/// viewer's ring loop in ShaderOSC, and the ring analogue of KKPointOSCSet.
///
/// Each ring encodes its scalar value NORMALIZED 0..1 across [min,max] through
/// the shared KKRingOSCExtentForNorm curve, so it draws and drags at the same
/// size as the in-viewer KKRingOSC. Reads/writes the host via
/// KKMiniViewerRenderer's public hooks (`valuesForLabel:`,
/// `commitValues:forLabel:canvas:`, `isConstantLabel:`,
/// `labelVisibleOrRevealing:`, `ghostAlphaForLabel:`,
/// `handlePointForContentRect:position:`, `onHandleVisibilityToggled`).
@interface KKRingOSCSet : KKRadialOSCSet

/// Rebuild the rings. Each spec is a dict: `@"label"` (NSString, the lane
/// identity), `@"min"`/`@"max"` (NSNumber, the value range the ring normalizes
/// over), `@"isInt"` (NSNumber bool, rounds the written value), `@"centerX"` /
/// `@"centerY"` (NSNumber, the ring centre in object space 0..1). Cheap no-op
/// when unchanged; preserves hover/drag state for surviving labels. Pass empty
/// to clear.
- (void)setRings:(NSArray<NSDictionary<NSString *, id> *> *)rings;

/// One `@{@"center", @"radiusX", @"radiusY", @"emphasis", @"alpha"}` bundle per
/// ring active in the current context. Forward
/// -miniViewer:extraRingsForContentRect: here.
- (NSArray<NSDictionary<NSString *, id> *> *)ringBundlesForContentRect:
    (CGRect)cr;

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (nullable NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Grab whatever ring is under `p`. YES if claimed (the host should NOT fall
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
/// Opt-click to hide the ring under `p`. YES if one toggled.
- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas;

@end

NS_ASSUME_NONNULL_END
