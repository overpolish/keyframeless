/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKPathBoolean.h> // KKBooleanOp

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Pure path-operation cores, shared by the viewer OSC (XPC process) and the
/// inspector mini (ViewBridge process) so both surfaces run identical logic.
/// Each mutates `paths` in place and returns the layerIDs that should become
/// the new selection (the op's result), or nil when it's a no-op (nothing
/// changed).

/// Boolean op (union / subtract / intersect / exclude) on the selected vector
/// layers. Needs two or more selected non-image/non-group CLOSED paths (open
/// strokes have no area and are excluded). Each operand is baked into the
/// TOP-most operand's space at clip fraction `frac` (so shapes combine where
/// they appear, regardless of differing group transforms), then replaced by a
/// single result inheriting the top operand's placement + name.
NSArray<NSString *> *_Nullable CanvasApplyBooleanOp(
    NSMutableArray<KKBezierPath *> *paths,
    NSArray<NSString *> *selectedLayerIDs, KKBooleanOp op, float aspect,
    double frac);

/// Stroke-to-outline on every selected stroke-bearing vector layer: the source
/// stroke is turned off and a filled outline inserted just above it. refWidth/
/// Height scale the px stroke width into 0-1 object space.
NSArray<NSString *> *_Nullable CanvasApplyOutlineOp(
    NSMutableArray<KKBezierPath *> *paths,
    NSArray<NSString *> *selectedLayerIDs, CGFloat refWidth, CGFloat refHeight);

/// Compute (without mutating anything) the hover-preview geometry for a path
/// op: `outOperands` are the selected paths that will be consumed (drawn red)
/// and `outResults` are the path(s) that will remain (drawn green). `outline`
/// picks stroke-to-outline (refWidth/Height scale the stroke); otherwise `op`
/// is the boolean. Returns NO (and leaves the out-params nil) when the op
/// doesn't apply to the current selection.
BOOL CanvasPathOpPreview(
    NSArray<KKBezierPath *> *paths, NSArray<NSString *> *selectedLayerIDs,
    BOOL outline, KKBooleanOp op, CGFloat refWidth, CGFloat refHeight,
    double frac, NSArray<KKBezierPath *> *_Nullable *_Nonnull outOperands,
    NSArray<KKBezierPath *> *_Nullable *_Nonnull outResults);

NS_ASSUME_NONNULL_END
