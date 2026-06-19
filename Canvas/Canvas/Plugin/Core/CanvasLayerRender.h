/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
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

/// Click-to-select hit-test: returns the `layerID` of the TOPMOST image layer
/// whose on-screen quad contains the object-space point (`objX`,`objY`) in
/// [0,1] (Y-up, the render's object space), evaluated at clip fraction `frac`,
/// or nil if none. `aspect` is the canvas pixel aspect (outputW/outputH) so the
/// transform (scale / Z-rotation / position / X-Y tilt + perspective) matches
/// the render exactly - the math is scale-invariant in object space, so only
/// the aspect is needed, not the pixel dimensions.
///
/// When `alphaAware` is YES, a click over a TRANSPARENT image pixel (raw image
/// alpha, NOT the layer's Opacity) falls through to the layer beneath, so you
/// select what you actually see; NO uses the transformed bounding quad alone.
/// Skips hidden / group / locked / non-image / non-rect layers. Evaluates each
/// layer's own persisted `animationJSON` (selection acts on persisted state).
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
    BOOL requireEditableAtFrac, NSArray<KKLane *> *_Nullable templates);

NS_ASSUME_NONNULL_END
