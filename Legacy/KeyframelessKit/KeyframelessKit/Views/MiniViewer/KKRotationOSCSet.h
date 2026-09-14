/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKRadialOSCSet.h>

NS_ASSUME_NONNULL_BEGIN

/// The mini-viewer sibling of the viewer's KKRotationOSC, for a plugin with N
/// independent 3-ring rotation gizmos (e.g. a shader declaring several
/// `osc={..}` uniforms). One per rotate lane; each reads its Euler value +
/// writes its drag through the host KKMiniViewerRenderer's `valuesForLabel:` /
/// `commitValues:forLabel:canvas:`, so the set owns only the geometry + the
/// per-axis compose. Parallel to KKRingOSCSet / KKBoxOSCSet.
///
/// A spec is a dict: `label` (lane identity), `axes` (KKRotationAxes bitmask,
/// which rings this gizmo drives - the lane carries one component per axis in
/// canonical X<Y<Z order), and `centerX`/`centerY` (object 0..1, default 0.5).
/// `offsetDeg` (an [X,Y,Z] degrees array) or `offsetDegBlock` (the same,
/// evaluated live per draw) add a DISPLAY-ONLY pose offset - the mini sibling
/// of the viewer gizmo's `baseRotation`, for a shader that renders a preset
/// angle on top of the lane's own.
@interface KKRotationOSCSet : KKRadialOSCSet

/// Replace the rotation specs (label / axes / centre).
- (void)setRotations:(NSArray<NSDictionary<NSString *, id> *> *)rotations;

/// The gizmos to draw for the current values, one per shown lane.
- (NSArray<KKMiniRotation *> *)rotationsForContentRect:(CGRect)cr
                                                canvas:
                                                    (KKMiniViewerView *)canvas;

/// Generic KKMiniViewerDelegate-style interaction forwards (the host's
/// Interaction category routes these through the set, then super).
- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (nullable NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas;
- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers;
- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas;
- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas;

@end

NS_ASSUME_NONNULL_END
