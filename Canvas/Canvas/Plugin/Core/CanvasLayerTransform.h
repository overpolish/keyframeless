/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Internal (non-published) shared math for the Canvas layer render + hit-test:
// evaluating a layer's transform from its timeline and composing the per-layer
// 3D model matrix (member + ancestor groups + one perspective). Both
// CanvasLayerRender.m (encode) and CanvasLayerHitTest.m use these, so they live
// here rather than as file-statics in one of them.

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKColorLanes.h> // KKColorLanesValue
#import <simd/simd.h>

@class KKBezierPath;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// A layer's transform at a clip fraction. Built into a single 3D model matrix
/// per layer (CanvasComposedModelMatrix): Scale, then Rotation (Z·X·Y as ONE
/// rigid rotation about the layer centre), then Position, all in one matrix fed
/// to the kit KKTransformVertexShader - so the axes compose correctly when
/// combined and a parent group's model matrix simply pre-multiplies.
typedef struct {
  float scaleX, scaleY; // 1.0 = 100%
  float rotation;       // Z radians, CCW; in-plane spin
  float posX, posY;     // normalised, 0.5 = no offset
  float rotX, rotY;     // X/Y tilt radians (perspective)
  float opacity; // 0..1, 1 = fully opaque (multiplies premultiplied RGBA)
  float anchorX, anchorY; // pivot, normalised; 0.5 = layer centre (no offset)
} CanvasLayerTransform;

/// One ancestor group's transform + its content-bbox pivot, in object space.
/// `rest` is the group's FROZEN content-centre (normalised, Position-lane
/// space, 0.5 = clip centre), seeded at creation and stored on the group (its
/// repurposed translateX/Y). A group's Position is measured FROM rest
/// (translation = Position
/// - rest), so seeding Position to the content centre leaves members in place;
/// the Anchor stays a free pan-behind pivot (changing it never moves rest).
typedef struct {
  CanvasLayerTransform t;
  float cx, cy;
  float restX, restY;
} CanvasGroupXform;

/// Stack capacity for an ancestor chain - a literal (not the const-typed
/// CanvasLayerGroupDepthGuard) so a buffer of these isn't a VLA; matches it.
enum { kCanvasGroupXformCap = 32 };

/// Identity transform (scale 1, no rotation, centred position, opaque).
CanvasLayerTransform CanvasLayerTransformIdentity(void);

/// A layer's transform from an in-memory timeline (the popover's live-edited
/// copy, so a mini-viewer handle drag previews before it persists).
CanvasLayerTransform CanvasLayerTransformFromTimeline(KKTimeline *tl,
                                                      double frac);

/// A layer's transform from its persisted `animationJSON` (identity when none).
CanvasLayerTransform CanvasLayerTransformAtFraction(KKBezierPath *path,
                                                    double frac);

/// The effective stroke Start/End width (native px) at `frac` from the layer's
/// "Stroke Width" lane, falling back to the flat `strokeWidth`/`endWidth` when
/// there is no lane yet. `overrideLayerID`/`overrideTimeline` let the live
/// inspector edit of the selected layer preview before it persists (pass
/// nil/nil for the persisted state). Shared by the render and the OSC stroke
/// draw.
void CanvasStrokeWidthAtFraction(KKBezierPath *path, double frac,
                                 NSString *_Nullable overrideLayerID,
                                 KKTimeline *_Nullable overrideTimeline,
                                 float *_Nullable outStart,
                                 float *_Nullable outEnd);

/// Whether the stroke is ON at `frac` from the layer's "Enabled" toggle lane,
/// falling back to the flat `strokeEnabled` when there is no lane. Shared by
/// the render + hit-test so a lane-disabled stroke neither draws nor is
/// pickable.
BOOL CanvasStrokeEnabledAtFraction(KKBezierPath *path, double frac,
                                   NSString *_Nullable overrideLayerID,
                                   KKTimeline *_Nullable overrideTimeline);

/// The resolved stroke colour at `frac` from the layer's "Stroke Mode/Solid/
/// Gradient" lanes (the shared KKColorLanes group, no Dynamic), falling back to
/// the flat strokeColorMode / strokeR,G,B when there is no lane yet. The result
/// feeds the render + OSC: Solid uses `solidColor`; Gradient uses `gradientLUT`
/// + type/angle. Same override hook as the other stroke evaluators.
KKColorLanesValue
CanvasStrokeColorAtFraction(KKBezierPath *path, double frac,
                            NSString *_Nullable overrideLayerID,
                            KKTimeline *_Nullable overrideTimeline);

/// The stroke Line Cap (0=butt/1=round/2=square) + Line Join (0=miter/1=round/
/// 2=bevel) from the layer's "Line Cap"/"Line Join" lanes, falling back to the
/// flat lineCap/lineJoin. Non-animatable, but read via the lane so inspector
/// edits apply. Shared by the render + hit-test.
void CanvasStrokeCapJoinAtFraction(KKBezierPath *path, double frac,
                                   NSString *_Nullable overrideLayerID,
                                   KKTimeline *_Nullable overrideTimeline,
                                   uint8_t *_Nullable outCap,
                                   uint8_t *_Nullable outJoin);

/// The stroke's start/end marker types (0=none/1=arrow/2=circle/3=square/
/// 4=arrowhead/5=line) from the non-animatable "Markers" lane (component 0/1),
/// plus the marker size as a stroke-width MULTIPLIER from the animatable
/// "Marker Size" lane (its value is a percentage; converted /100 here). One
/// size drives both ends. Falls back to the flat startMarker/endMarker +
/// startMarkerSize/endMarkerSize. Shared by the render + OSC.
void CanvasStrokeMarkersAtFraction(KKBezierPath *path, double frac,
                                   NSString *_Nullable overrideLayerID,
                                   KKTimeline *_Nullable overrideTimeline,
                                   uint8_t *_Nullable outStart,
                                   uint8_t *_Nullable outEnd,
                                   float *_Nullable outStartMul,
                                   float *_Nullable outEndMul);

/// The stroke's dash pattern at a clip fraction. `style` is 0 = solid, 1 =
/// dashed, 2 = dotted. `dashLength`/`dashGap` (px) size the dashes, `dotGap`
/// (px) the spacing between dots, `marchSpeed` (cycles/sec) the marching-ants
/// animation rate. Read from the "Stroke Style"/"Dash Length"/"Dash Gap"/"Dot
/// Gap"/"Marching Ants Speed" lanes, falling back to the flat path props.
typedef struct {
  uint8_t style;    // 0 solid, 1 dashed, 2 dotted
  float dashLength; // px
  float dashGap;    // px
  float dotGap;     // px
  float marchSpeed; // cycles/sec
} CanvasStrokeStyle;

CanvasStrokeStyle
CanvasStrokeStyleAtFraction(KKBezierPath *path, double frac,
                            NSString *_Nullable overrideLayerID,
                            KKTimeline *_Nullable overrideTimeline);

/// Legacy per-layer tilt+perspective+tile-shift matrix for 2D-baked verts. Now
/// only used for the identity full-image source quad (CanvasEncodeSourceTile);
/// the layer pipeline uses CanvasComposedModelMatrix on raw verts instead.
matrix_float4x4 CanvasLayerTiltMatrix(CanvasLayerTransform t,
                                      simd_float2 centerPx, float W, float H,
                                      simd_float2 tileShift);

/// Fill `out` (capacity `maxN`) with the ancestor group transforms for the
/// layer at `idx`, INNERMOST parent first; returns the count. `overrideLayerID`
/// / `overrideTimeline` let a group whose id matches read the live-edited
/// timeline (mini-viewer drag preview); pass nil/nil for the persisted state.
NSInteger CanvasBuildGroupXforms(NSArray<KKBezierPath *> *layers,
                                 NSUInteger idx, double frac,
                                 NSString *_Nullable overrideLayerID,
                                 KKTimeline *_Nullable overrideTimeline,
                                 CanvasGroupXform *out, NSInteger maxN);

/// The full per-member transform fed to the vertex shader: the member's 3D
/// model matrix composed with each ancestor group's (member first, innermost
/// group … outermost), then ONE perspective centred on the outermost element's
/// positioned centre. Applied to RAW rect-corner verts (no CPU 2D baking) so
/// all rotation axes of each level compose rigidly. `dims` maps object space to
/// the working pixel space (render: image W,H; hit-test: aspect,1);
/// `memberCenterObj` is the member's REST centre in object space.
matrix_float4x4 CanvasComposedModelMatrix(CanvasLayerTransform memberT,
                                          simd_float2 memberCenterObj,
                                          const CanvasGroupXform *groups,
                                          NSInteger ng, simd_float2 dims,
                                          simd_float2 tileShift);

NS_ASSUME_NONNULL_END
