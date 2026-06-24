/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKRotationOSCMath.h>
#import <Metal/Metal.h>

@class KKBezierPath;
@class KKTimeline;
@class KKLane;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// Reads `kParamLayerData` (action-scoped) and returns the decoded layer stack,
/// or an empty array when there's no data. `target` is the action identity
/// token (pass the host-recognized plugin where available; nil is tolerated for
/// reads). Used by the inspector to feed the mini-viewer renderer and by the
/// layer list to load its rows - one source of truth for decoding the blob.
NSMutableArray<KKBezierPath *> *
    CanvasReadLayerPaths(id<PROAPIAccessing> _Nullable api,
                         id _Nullable target);

/// Draws every visible image layer as a textured quad over whatever the encoder
/// already drew, back-to-front (array index 0 = topmost, drawn last). The
/// caller must have set an image pipeline (kit `KKVertexShader` + premultiplied
/// passthrough fragment) on `encoder` and bound the viewport-size buffer at
/// `KKVertexInputIndex_ViewportSize`; this only re-sets the per-quad vertex
/// buffer + texture. Object space is normalized [0,1] with Y=0 at the bottom,
/// mapped across `outputWidth` x `outputHeight`. Non-image / hidden / group /
/// non-rect layers are skipped. Shared by the main render and the mini-viewer
/// so both composite identically.
///
/// `frac` is the clip-local time (0–1) at which each layer's Scale + Position
/// transform is evaluated (from its own `animationJSON`) and applied to the
/// quad: Scale (%) about the layer's own centre, Position (normalised, 0.5 =
/// identity) as an offset. A NEGATIVE `frac` skips transform evaluation and
/// draws every layer at its static shape rect (used by call sites that don't
/// yet supply a render time).
///
/// `overrideLayerID` + `overrideTimeline` (both optional) let the mini-viewer
/// preview a live edit: the layer whose `layerID` matches takes its transform
/// from `overrideTimeline` (the popover's in-memory edited copy) instead of its
/// persisted `animationJSON`, so a Position-handle drag tracks immediately.
/// Pass nil/nil for the main render (every layer reads its own blob).
///
/// `imageWidth`/`imageHeight` are the FULL image dimensions (imagePixelBounds),
/// the space layers are positioned in; `tileShiftX`/`tileShiftY` translate that
/// image-space content into the current render TILE (the viewport the shader
/// divides by). For a full-frame render tile==image so shift is 0; FCP's tiled
/// previews pass a non-zero shift so each tile shows only its slice instead of
/// redrawing the whole composite.
void CanvasEncodeImageLayers(
    NSArray<KKBezierPath *> *layers, id<MTLRenderCommandEncoder> encoder,
    id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *cache, float imageWidth,
    float imageHeight, float tileShiftX, float tileShiftY, double frac,
    NSString *_Nullable overrideLayerID,
    KKTimeline *_Nullable overrideTimeline);

/// Draw the source frame as a full-image quad through the SAME tile transform
/// (KKTransformVertexShader + the tile-shift matrix) the layers use, so it
/// tiles identically in FCP's sub-tiled / reverse-Y library preview instead of
/// relying on the kit helper's UV passthrough (which isn't reliable
/// cross-tile). The caller must have set a KKTransformVertexShader +
/// KKTextureOpacityFragment pipeline (the image pipeline); this binds
/// opacity 1. Draws nothing if no src.
void CanvasEncodeSourceTile(id<MTLRenderCommandEncoder> encoder,
                            id<MTLTexture> _Nullable source, float imageWidth,
                            float imageHeight, float tileShiftX,
                            float tileShiftY);

/// Strokes every visible VECTOR layer (a non-image, non-group path with
/// `strokeEnabled`) over whatever the encoder already drew. The caller must
/// have set a stroke pipeline (`KKTransformVertexShader` + `KKLineFragment`,
/// premultiplied) on `encoder`; the viewport-size buffer at
/// `KKVertexInputIndex_ViewportSize` is inherited from the kit's encoder setup
/// (same as the image pass). Each layer's path is tessellated to a constant-
/// width triangle strip in the SAME centered-pixel object space as the image
/// quads and drawn through `CanvasComposedModelMatrix`, so a stroke moves /
/// scales / tilts / groups exactly like an image layer. `frac`,
/// `overrideLayerID` and `overrideTimeline` behave as in
/// CanvasEncodeImageLayers. Stroke colour is the layer's `strokeR/G/B`; alpha
/// folds in the layer + ancestor-group opacity. `strokeScale` multiplies the
/// stored (native-px) stroke width so a DOWNSCALED render (e.g. an FCP browser
/// thumbnail) draws strokes at the right thickness; pass 1.0 for a full-res /
/// native render.
/// `solidPS` is the line pipeline (KKLineFragment); `gradientPS` is the
/// gradient line pipeline (KKGradientLineFragment). The function sets the right
/// one per layer from its stroke-colour Mode. Pass gradientPS = nil to force
/// solid. `dashPS` is the dashed-stroke pipeline (KKStrokeDashVertexShader +
/// KKStrokeDashFragment): a dashed layer draws the solid stroke geometry and
/// masks the dash pattern by arc length in the fragment (so corners match the
/// solid stroke). Pass dashPS = nil to render dashed strokes as solid.
/// `elapsedSec` is the media time since the effect start; it drives the
/// marching-ants animation (phase = elapsedSec x Speed x pattern period). Pass
/// 0 for a static preview.
void CanvasEncodeVectorLayers(
    NSArray<KKBezierPath *> *layers, id<MTLRenderCommandEncoder> encoder,
    id<MTLDevice> device, float imageWidth, float imageHeight, float tileShiftX,
    float tileShiftY, double frac, NSString *_Nullable overrideLayerID,
    KKTimeline *_Nullable overrideTimeline, float strokeScale,
    double elapsedSec, id<MTLRenderPipelineState> _Nullable solidPS,
    id<MTLRenderPipelineState> _Nullable gradientPS,
    id<MTLRenderPipelineState> _Nullable dashPS);

/// Click-to-select hit-test: returns the `layerID` of the TOPMOST layer hit by
/// the object-space point (`objX`,`objY`) in [0,1] (Y-up, the render's object
/// space), evaluated at clip fraction `frac`, or nil if none. Image layers hit
/// when the point is inside their transformed quad; VECTOR (stroke) layers hit
/// when the point is within their transformed stroke. Images and vectors share
/// one topmost-first loop so z-order between them is unified. `aspect` is the
/// canvas pixel aspect (outputW/outputH) so the transform (scale / Z-rotation /
/// position / X-Y tilt + perspective) matches the render exactly.
///
/// `canvasHeightPx` (the render output height, or a viewer-canvas proxy) sizes
/// the vector stroke pick tolerance only; a generous object-space slop floor
/// applies so clicking near a thin stroke still selects it. Pass 0 for the
/// default reference. Ignored for image layers.
///
/// When `alphaAware` is YES, a click over a TRANSPARENT image pixel (raw image
/// alpha, NOT the layer's Opacity) falls through to the layer beneath, so you
/// select what you actually see; NO uses the transformed bounding quad alone.
/// (Vector layers ignore it - the stroke distance test is itself "what you
/// see", so a click in an open stroke's hollow interior falls through.) Skips
/// hidden / group / locked layers, and non-image layers without a stroke.
/// Evaluates each layer's own persisted `animationJSON` (selection acts on
/// persisted state).
///
/// Layers whose `layerID` is in `excludedLayerIDs` are skipped too (a click
/// over one falls through to the layer beneath) - used by the mini-viewer to
/// mirror the layer list's "non-selectable" gating (e.g. a keypose popover only
/// lets you pick layers with a keypose at that time). Pass nil for no
/// exclusion.
///
/// When `requireEditableAtFrac` is YES (the main viewer), a layer is skipped
/// unless it's editable at `frac`: it has at least one constant (per
/// `templates`) OR an animated lane visible at `frac` (at a keypose or its
/// lead-in/out hold). So a fully-animated layer with no keypose at the playhead
/// isn't pickable on the canvas. Pass NO + nil templates to skip this gate (the
/// mini-viewer, which is already gated by its popover set).
NSString *_Nullable CanvasHitTestLayerID(
    NSArray<KKBezierPath *> *layers, double frac, float aspect, float objX,
    float objY, BOOL alphaAware, NSSet<NSString *> *_Nullable excludedLayerIDs,
    BOOL requireEditableAtFrac, NSArray<KKLane *> *_Nullable templates,
    float canvasHeightPx);

/// Project a layer-local normalized point (Y-up [0,1], the raw KKBezierPath
/// space) through the layer's transform at `frac` + its ancestor groups +
/// perspective into screen-object space (Y-up [0,1], the render's object space)
/// - the SAME projection CanvasHitTestLayerID uses, so a path-edit OSC draws
/// its anchors / segments exactly where the stroke renders. For many points
/// prefer the batched form (it builds the transform once).
simd_float2 CanvasProjectLayerPointObj(NSArray<KKBezierPath *> *layers,
                                       KKBezierPath *path, double frac,
                                       float aspect, float localX,
                                       float localY);

/// Batched CanvasProjectLayerPointObj: builds the layer transform + group
/// composition ONCE, then projects `count` local points (`localPts`) into
/// `outProj`. Both buffers are `count` long.
void CanvasProjectLayerPointsObj(NSArray<KKBezierPath *> *layers,
                                 KKBezierPath *path, double frac, float aspect,
                                 const simd_float2 *localPts,
                                 simd_float2 *outProj, NSUInteger count);

/// Inverse of CanvasProjectLayerPointObj: map a screen-object point (Y-up
/// [0,1], the render's object space) back to the layer's local normalized point
/// (Y-up [0,1], the raw KKBezierPath space), through the inverse of the layer
/// transform + groups + perspective. Built by projecting the 4 unit-square
/// corners and inverting the resulting homography. Used by path-anchor dragging
/// to follow the cursor under any layer transform.
simd_float2 CanvasUnprojectLayerPointObj(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *path, double frac,
                                         float aspect, float screenX,
                                         float screenY);

/// Apply a member's ANCESTOR-GROUP transforms (only) to an object point already
/// in the member's output / clip object space (Y-up, [0,1]) - the same group
/// composition + perspective the render uses. Returns the transformed point
/// (unchanged for an ungrouped layer / group). Lets a member's OSC draw at the
/// group-composed location of its actual point (move handle, anchor pivot).
/// Safe to call live now that a group pivots on its STORED Anchor, not the
/// member- dependent content centre - so it no longer feeds back during a
/// member drag.
BOOL CanvasComposedGroupPointObj(NSArray<KKBezierPath *> *layers,
                                 KKBezierPath *_Nullable member, double frac,
                                 float aspect, float inX, float inY,
                                 float *_Nullable outX, float *_Nullable outY);

/// The accumulated rotation of a member's ancestor groups (outermost · … ·
/// innermost), in the SAME Ry·Rx·Rz order the render composes - identity for an
/// ungrouped layer or a group. Feeds a member's rotation gizmo `baseRotation`
/// so its rings tilt with the group while the drag still writes the member's
/// own Euler.
KKRotMatrix3 CanvasComposedGroupRotation(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *_Nullable member,
                                         double frac);

/// A layer's geometry centre in normalized object space (Y-up [0,1]) - the
/// pivot the render rotates / scales about and the gizmo cluster centres on.
/// Rect / ellipse shapes use their bbox centre; a drawn path uses its point
/// bbox; a group (or empty) returns (0.5, 0.5) since groups pivot on their
/// stored Anchor. Shared by CanvasEncodeVectorLayers and the OSC gizmo so both
/// agree.
simd_float2 CanvasLayerObjectCenter(KKBezierPath *path);

/// Heckbert square->quad homography: maps the unit square
/// (0,0),(1,0),(1,1),(0,1) onto the four given quad corners. Column-major (M *
/// (u,v,1) -> (X,Y,W); divide by W). A planar member projected through its
/// group transform is a projective map, so this captures it exactly (and
/// `simd_inverse` gives the reverse for snapping a composed point back to a
/// member value). Pure math.
simd_float3x3 CanvasSquareToQuadHomography(CGPoint p0, CGPoint p1, CGPoint p2,
                                           CGPoint p3);

/// The group's content centre in object space (Y-up) = the centre of the union
/// of its descendant image rects (rest shape, ignoring animation). NO for a
/// non-group or a group with no rect-shaped image descendants. Used to seed a
/// new group's stored Anchor pivot (CanvasSeedGroupAnchor) onto its content.
BOOL CanvasGroupContentCenterObj(NSArray<KKBezierPath *> *layers,
                                 KKBezierPath *group, float *_Nullable outCx,
                                 float *_Nullable outCy);

/// A group's frozen content-centre rest (its repurposed translateX/Y, Position-
/// lane space; the reference its Position is measured from). Falls back to the
/// clip centre {0.5,0.5} for an unseeded/legacy group or a non-group, so it can
/// be called unconditionally to get the Position reference.
simd_float2 CanvasLayerGroupRest(KKBezierPath *group);

/// A layer's content HALF-extent in object space (normalised), per axis: 0.5
/// for a clip-filling image, the shape/points bbox half for a
/// rect/ellipse/path, the content bbox half for a group. Used to map the Anchor
/// lane to the scale box's scale-from-anchor fraction. NO for a nil layer /
/// unmeasurable group.
BOOL CanvasLayerContentHalfExtentObj(NSArray<KKBezierPath *> *layers,
                                     KKBezierPath *layer,
                                     float *_Nullable outHx,
                                     float *_Nullable outHy);

NS_ASSUME_NONNULL_END
