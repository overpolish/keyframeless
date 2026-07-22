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
extern NSSet<NSString *> *MirageOSCBaseVars(void);

/// Map a `cursor =` name ("move"/"crosshair"/"pointing"/"resize-h/v/diag") to
/// an NSCursor. Defaults to the point-move cursor (matches Rounded).
extern NSCursor *MirageOSCCursorForName(NSString *_Nullable name);

/// A single compiled `// @osc` block: the bound lane, the value normalization
/// mirroring the shader's directive delivery, and the forward (value ->
/// object-space geometry) + optional inverse. Shared by the viewer (MirageOSC)
/// and the mini (MirageMiniViewerRenderer) so the handle sits and drags
/// identically in both. Object space is 0..1, Y-up, per-axis
/// (aspect-distorted); each side converts the returned object point to its own
/// pixel space. The glyph object (viewer) / glyph style (mini) is chosen from
/// `styleName` by the caller, since only the caller has the drawing surface.
@interface MirageOSCBlockRuntime : NSObject

@property(nonatomic, readonly) NSString *name; // OSC display + element key
@property(nonatomic, readonly)
    NSString *primitive; // "point"/"ring"/"box"/"rotate"/"position"
@property(nonatomic, readonly) NSString *axes; // rotate: raw "x y z" subset
/// The raw `center =` text ("" when not authored). The mini's spec-driven sets
/// map the two standard shapes (a bare uniform name -> live link, anything
/// else -> a one-time constant eval); the viewer evaluates it live.
@property(nonatomic, readonly) NSString *centerSource;
@property(nonatomic, readonly) NSString *binds; // bound lane label
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
@property(nonatomic, readonly) BOOL isInt;    // whole-number lane: writes round
@property(nonatomic, readonly) BOOL linked;   // ellipse fields aspect-linked
@property(nonatomic, readonly) BOOL bodyMove; // box: interior drags the rect
/// Point: Cmd-held snapping to canvas anchors + the lane's other keyposes is on
/// unless the block declared `skipsnapping`. Matches osc=position.
@property(nonatomic, readonly) BOOL snaps;
/// The bound lane's display metadata, so a box/point readout matches the lane
/// fields: media-scaled per-component (px) with the raw/"%"/"" exemptions.
@property(nonatomic, readonly) BOOL boundScalesWithMedia;
@property(nonatomic, readonly, nullable)
    NSArray<NSString *> *boundComponentUnits;

/// The box's "W x H" readout in the bound lane's DISPLAY units: each of the
/// two dimensions media-scaled to px when its component unit is "px" (and the
/// lane scales with media), else the raw 2-decimal value ("%" -> a percent).
/// `values` = the lane's raw components; `media` its px size (zero = no
/// scaling). Empty when there are < 2 components.
+ (NSString *)boxReadoutForValues:(NSArray<NSNumber *> *)values
                            units:(nullable NSArray<NSString *> *)units
                  scalesWithMedia:(BOOL)scalesWithMedia
                        mediaSize:(CGSize)media;

/// Raw lane values for OTHER uniforms an expression references (e.g.
/// `center = uOrigin`). Set by the owning surface before evaluating (it is the
/// one with snapshot access); nil resolves those references to 0. The runtime
/// normalizes per that uniform's directive (a percent lane's 0..100 -> 0..1).
@property(nonatomic, copy, nullable)
    NSArray<NSNumber *> *_Nullable (^laneValueProvider)(NSString *label);

/// Like laneValueProvider but AT a given clip fraction - the position warp's
/// per-sample path mapping needs referenced uniforms at each sample's own
/// time. When set, it wins for any evaluation that carries a fraction.
@property(nonatomic, copy, nullable)
    NSArray<NSNumber *> *_Nullable (^laneValuesAtFractionProvider)
        (NSString *label, double fraction);

/// Parse + compile + normalize every `// @osc` block in `src`. `lanes` = the
/// effective lanes (to seed a first keypose on write). Silently drops a block
/// whose primitive isn't wired, whose locals/forward fail to compile, or whose
/// name/binds is empty. Returns [] for none.
+ (NSArray<MirageOSCBlockRuntime *> *)runtimesForSource:(NSString *)src
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

/// Object-space (0..1, Y-up) point where a point/position handle sits for the
/// given raw lane values: a `point` at its forward object point, a `position`
/// at its value directly (identity placement). Shared by the viewer and mini so
/// a handle snaps onto the same spot in both.
+ (simd_float2)handleObjectPointForRuntime:(MirageOSCBlockRuntime *)runtime
                                laneValues:
                                    (nullable NSArray<NSNumber *> *)values
                                    aspect:(double)aspect;

/// Every point/position handle's object position EXCEPT the one bound to
/// `excludeBinds`, CGPoint-wrapped - the shared snap-target set the viewer and
/// mini both pull from (points snap onto positions and vice-versa).
/// `laneValues(binds)` yields each runtime's raw lane values (the caller owns
/// the snapshot / renderer access).
+ (NSArray<NSValue *> *)
    snapTargetsForRuntimes:(NSArray<MirageOSCBlockRuntime *> *)runtimes
            excludingBinds:(nullable NSString *)excludeBinds
                    aspect:(double)aspect
                laneValues:(NSArray<NSNumber *> *_Nullable (^)(NSString *binds))
                               laneValues;

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
/// [laneMin,laneMax], round when `isInt`, `fieldCount` components) ready for a
/// lane write.
- (NSArray<NSNumber *> *)laneValuesFromBound:(KKExprVal)bound;

/// The centred primitives' placement: the `center =` expression in object
/// space (may follow another uniform), or the frame centre when none was
/// authored.
- (simd_float2)centerObjectForBound:(KKExprVal)bound aspect:(double)aspect;

/// Ring forward: the `toR` radii for a bound value, in MIN-DIMENSION FRACTIONS
/// (multiply by the surface's min dimension for pixels). Scalar = circle,
/// vec2 = ellipse.
- (KKExprVal)ringRadiiForBound:(KKExprVal)bound aspect:(double)aspect;

/// Box forward: the `toRect` rectangle for a bound value, an object-space vec4
/// (minX, minY, maxX, maxY), min/max normalized.
- (KKExprVal)boxRectForBound:(KKExprVal)bound aspect:(double)aspect;

/// Box inverse: `fromRect` with the dragged rectangle bound to `rect`.
- (KKExprVal)boxBoundForRect:(KKExprVal)rect
                    boundNow:(KKExprVal)boundNow
                      aspect:(double)aspect;

/// The CENTRED box's default drag (used when `body = none`): the cursor's
/// per-axis distance from the fixed centre becomes the candidate extent for
/// the grabbed handle's driven axes (grow AND shrink), a held axis keeps its
/// press extent, and the two candidates couple like the scale box (corner =
/// one factor when linked, edge = ratio-follow). `m` is the cursor in object
/// space; `fromRect` is the bijection.
- (KKExprVal)boxCenteredBoundForObjectMouse:(simd_float2)m
                                     corner:(BOOL)isCorner
                                  controlsX:(BOOL)controlsX
                                 pressBound:(KKExprVal)pressBound
                            linkedEffective:(BOOL)linkedEffective
                                     aspect:(double)aspect;

/// The fixed bridge between an object-space rect (Y-up) and the `[w, h, x, y]`
/// crop model (KKCropModel: size + centre offset, y-down) the box scaffolds
/// (KKCropOSC in the viewer, KKMiniViewerCropEditor in the mini) drive - so
/// both sides run the identical anchored-resize + body-move mechanic.
+ (NSArray<NSNumber *> *)cropModelFromRect:(KKExprVal)rect;
+ (KKExprVal)rectFromCropModel:(NSArray<NSNumber *> *)values;

/// The ring primitive's default drag: cursor offset from the ring centre (in
/// min-dimension fractions, signed; `pressOff` captured at mouse-down) -> new
/// bound value via `fromR`. A scalar tracks the radial distance; an ellipse is
/// per-axis with a cardinal-grabbed axis held, or scales both components by
/// one factor when `linkedEffective` (the lane's link XOR Shift).
- (KKExprVal)ringBoundForDragOffset:(simd_float2)off
                        pressOffset:(simd_float2)pressOff
                         pressBound:(KKExprVal)pressBound
                    linkedEffective:(BOOL)linkedEffective
                             aspect:(double)aspect;

@end

NS_ASSUME_NONNULL_END
