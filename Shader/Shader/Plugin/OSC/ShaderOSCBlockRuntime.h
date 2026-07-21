/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKLinkExpr.h>
#import <simd/simd.h>

@class KKLane;

NS_ASSUME_NONNULL_BEGIN

/// The OSC-expression variables a `// @osc` block may reference (object space),
/// beyond its bound uniform: mouse/pos, corners, aspect, part, center, size. A
/// bare identifier outside this set (plus the bound name + earlier locals) is a
/// compile error, so a typo underlines instead of silently evaluating to 0.
extern NSSet<NSString *> *ShaderOSCBaseVars(void);

/// Map a `cursor =` name ("move"/"crosshair"/"pointing"/"resize-h/v/diag") to
/// an NSCursor. Defaults to the point-move cursor (matches Rounded).
extern NSCursor *ShaderOSCCursorForName(NSString *_Nullable name);

/// A single compiled `// @osc` block: the bound lane, the value normalization
/// mirroring the shader's directive delivery, and the forward (value ->
/// object-space geometry) + optional inverse. Shared by the viewer (ShaderOSC)
/// and the mini (ShaderMiniViewerRenderer) so the handle sits and drags
/// identically in both. Object space is 0..1, Y-up, per-axis
/// (aspect-distorted); each side converts the returned object point to its own
/// pixel space. The glyph object (viewer) / glyph style (mini) is chosen from
/// `styleName` by the caller, since only the caller has the drawing surface.
@interface ShaderOSCBlockRuntime : NSObject

@property(nonatomic, readonly) NSString *name;      // OSC display + element key
@property(nonatomic, readonly) NSString *primitive; // "point" (box/ring later)
@property(nonatomic, readonly) NSString *binds;     // bound lane label
@property(nonatomic, readonly)
    NSString *styleName; // "hollow"/"square"/"dot"/""
@property(nonatomic, readonly) NSString *cursorName; // hover-cursor name
@property(nonatomic, readonly) int fieldCount; // bound value component count
@property(nonatomic, readonly) double divisor; // lane units -> expr units
@property(nonatomic, readonly) double laneMin, laneMax; // clamp (lane units)
@property(nonatomic, readonly) double exprMin,
    exprMax; // search range (expr units)
@property(nonatomic, readonly, nullable)
    KKLane *templateLane; // seeds first write
@property(nonatomic, readonly) BOOL hasInverse;

/// Parse + compile + normalize every `// @osc` block in `src`. `lanes` = the
/// effective lanes (to seed a first keypose on write). Silently drops a block
/// whose primitive isn't wired, whose locals/forward fail to compile, or whose
/// name/binds is empty. Returns [] for none.
+ (NSArray<ShaderOSCBlockRuntime *> *)runtimesForSource:(NSString *)src
                                                  lanes:(NSArray<KKLane *> *)
                                                            lanes;

/// Bound value in EXPR units from raw lane values (÷divisor, `fieldCount`
/// comps).
- (KKExprVal)boundValueFromLaneValues:(nullable NSArray<NSNumber *> *)values;

/// Forward-eval to an object-space point (0..1, Y-up). `mouse` is used only
/// when the forward references `pos`/`mouse` (a drag); pass haveMouse=NO
/// otherwise.
- (simd_float2)objectPointForBound:(KKExprVal)bound
                            aspect:(double)aspect
                             mouse:(simd_float2)mouse
                         haveMouse:(BOOL)haveMouse;

/// The bound value whose forward object-point is nearest `target`,
/// golden-section searched over [exprMin, exprMax] with aspect-corrected
/// distance (so the argmin matches the canvas-space one). For a non-linear /
/// non-invertible forward.
- (KKExprVal)invertBoundForObjectPoint:(simd_float2)target
                                aspect:(double)aspect;

/// Evaluate the EXPLICIT inverse (only meaningful when `hasInverse`): geometry
/// -> value. `boundNow` is the current bound value (available to the
/// expression).
- (KKExprVal)inverseBoundForObjectMouse:(simd_float2)mouse
                               boundNow:(KKExprVal)boundNow
                                 aspect:(double)aspect;

/// EXPR-unit bound -> clamped lane-unit values (×divisor, clamp
/// [laneMin,laneMax], `fieldCount` components) ready for a lane write.
- (NSArray<NSNumber *> *)laneValuesFromBound:(KKExprVal)bound;

@end

NS_ASSUME_NONNULL_END
