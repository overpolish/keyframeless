/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

@protocol CanvasPenSurface;
@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Draw a committed path's edit OSC - the anchors (points) and the connecting
/// curve (line) - onto `surface` via its CanvasPenSurface draw primitives, so
/// it looks identical in the viewer and the mini and stays in sync with the pen
/// preview. Each point is projected through the layer's transform + ancestor
/// groups at `frac` (CanvasProjectLayerPointsObj), so it lands exactly where
/// the stroke renders. Anchors whose index is in `selected` draw in the host
/// accent (active). When `marqueeActive`, the `marqueeSurfaceRect` rubber-band
/// is drawn on top (surface points, no projection). When `ghost` is YES the
/// anchors draw dimmed - used to preview a hidden Points OSC during an Opt-peek
/// so an Opt-click can re-show it (mirrors the transform handles' reveal
/// ghost).
/// The connecting guide curve is drawn from the corner-EXPANDED geometry so it
/// matches the rounded stroke, while the anchors stay at the stored (sharp)
/// corners. `showCornerWidgets` draws the live-corner radius handles (cursor tool
/// only - they're not interactive while drawing with the pen).
void CanvasDrawPathEditOSC(id<CanvasPenSurface> surface,
                           NSArray<KKBezierPath *> *layers, KKBezierPath *path,
                           double frac, float aspect,
                           NSIndexSet *_Nullable selected, BOOL marqueeActive,
                           CGRect marqueeSurfaceRect, BOOL ghost,
                           BOOL showCornerWidgets);

/// Draw the path-operation hover preview: each `operands` path outlined in red
/// (will be removed) and each `results` path outlined in green (will remain),
/// projected through their transforms at `frac`. Uses the surface's colored
/// curve primitive, so it renders identically in the viewer and the mini.
void CanvasDrawPathOpPreview(id<CanvasPenSurface> surface,
                             NSArray<KKBezierPath *> *layers,
                             NSArray<KKBezierPath *> *operands,
                             NSArray<KKBezierPath *> *results, double frac,
                             float aspect);

/// Draw a dimmed quad outline around `layer` - the multi-selection indicator for
/// an image (which has no points to outline). Uses the image's RECT SHAPE
/// corners (its actual on-screen quad, matching the hit-test) projected through
/// the transform at `frac`, falling back to the unit square for a shapeless
/// layer. Drawn via the surface's colored curve primitive (viewer + mini).
void CanvasDrawLayerBoxOSC(id<CanvasPenSurface> surface,
                           NSArray<KKBezierPath *> *layers, KKBezierPath *layer,
                           double frac, float aspect);

/// Render the path-op FILL preview (operands red, result green; translucent,
/// fill + stroke composited per shape in a transparency layer so there's no
/// double-alpha overlap) into a fresh sRGB-premultiplied CGBitmapContext of
/// `w`x`h` px. `objToPx` maps an object-space (Y-up, normalized) point to a pixel
/// in that bitmap - each surface supplies its own projection (viewer destination
/// px / mini drawable px). `refW` is the true output width in px, used to convert
/// the shapes' output-px stroke widths to bitmap px (the scale is measured via
/// `objToPx`). Returns a context the CALLER must CGContextRelease after uploading
/// its data to a texture, or NULL on failure. Shared by the viewer + mini so both
/// previews look identical.
CGContextRef _Nullable CanvasRenderPathOpFillBitmap(
    NSArray<KKBezierPath *> *operands, NSArray<KKBezierPath *> *results,
    NSArray<KKBezierPath *> *layers, double frac, float aspect, NSInteger w,
    NSInteger h, CGFloat refW, CGPoint (^objToPx)(simd_float2 objYUp));

/// Render a translucent HIGHLIGHT fill (single colour `r`/`g`/`b`) for the given
/// `highlight` layers into a fresh bitmap, same fill + stroke compositing as the
/// path-op preview. Used by the layer-list hover overlay so hovering a row shows
/// which layer it is on the mini-viewer. Returns a context the CALLER must
/// CGContextRelease after uploading to a texture, or NULL on failure.
CGContextRef _Nullable CanvasRenderLayerHighlightBitmap(
    NSArray<KKBezierPath *> *highlight, NSArray<KKBezierPath *> *layers,
    double frac, float aspect, NSInteger w, NSInteger h, CGFloat refW, CGFloat r,
    CGFloat g, CGFloat b, CGPoint (^objToPx)(simd_float2));

/// Upload a CG fill bitmap (from CanvasRenderPathOpFillBitmap) into a fresh
/// RGBA8 shader-read MTLTexture of `width`x`height` px. The CALLER still owns the
/// CGContext (release it after). Shared by the viewer + mini path-op previews so
/// the CGBitmap -> texture step isn't duplicated per surface.
id<MTLTexture> _Nullable CanvasFillBitmapToTexture(CGContextRef ctx,
                                                   id<MTLDevice> device,
                                                   NSInteger width,
                                                   NSInteger height);

NS_ASSUME_NONNULL_END
