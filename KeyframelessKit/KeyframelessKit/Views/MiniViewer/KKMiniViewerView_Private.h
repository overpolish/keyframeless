/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKMiniViewerView.h"
#import <IOSurface/IOSurface.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>

// Outer radius (points) of the shared KKPointOSC handle glyph. Smaller than
// the viewer OSC's oscSize - the mini viewer is a compact preview. Must stay
// in sync with RoundedMiniViewerRenderer's MiniOscSize() (placement/hit).
// Shared by the main file's interaction code and the +Rendering encoders.
static const CGFloat kKKMiniHandleOuterPt = 4.5;

// Initial / double-click-reset zoom. Slightly < 1 (aspect-fit) so there's a
// margin around the image and the corner handles are clear of the view edge
// (and the rounded-corner mask) and easy to grab from the start. Used by init
// (main) and resetView (+Interaction).
static const CGFloat kKKMiniInitialZoom = 0.85;

// Click vs drag slop (view points): cumulative pointer travel below this on a
// filmstrip cell counts as a click (swap the active cell on mouseUp); past it
// the gesture is a pan and the pending swap is dropped.
static const CGFloat kKKMiniFilmstripClickSlopPt = 3.0;

NS_ASSUME_NONNULL_BEGIN

/// Transparent AppKit layer over the Metal content. Draws plugin handles and
/// owns handle hit-testing/dragging; passes non-handle clicks through to the
/// canvas (so pan/zoom/double-click-reset still work).
@interface _KKMiniViewerOverlay : NSView
@property(nonatomic, weak) KKMiniViewerView *canvas;
@end

// One filmstrip slot: a resolved IOSurface from the feed's `slots[]` array,
// wrapped as the source texture and a per-slot persistent processed texture.
// Slot 0 is the single-slot fast path; the multi-slot ivars below alias it.
@interface _KKMiniFilmSlot : NSObject
@property(nonatomic) uint32_t sid;
@property(nonatomic) uint64_t generation;
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic, strong) id<MTLTexture> sourceTexture;
@property(nonatomic, strong, nullable) id<MTLTexture> processedTexture;
@property(nonatomic) double tag; // the slot's clip fraction
@end

@interface KKMiniViewerView () {
@package
  id<MTLRenderPipelineState> _pipeline;
  id<MTLRenderPipelineState> _onionPipeline;
  id<MTLCommandQueue> _queue;
  // Slot 0 aliases - keep the existing names so the handle/border/OSC code
  // paths (which always target the editable slot) don't need to change.
  // The aliases point at `_filmstripSlots.firstObject`'s textures/surface.
  id<MTLTexture> _sourceTexture;
  id<MTLTexture> _processedTexture;
  IOSurfaceRef _sourceSurface;
  uint32_t _resolvedSurfaceID;
  uint64_t _resolvedGeneration;
  // Multi-slot bookkeeping. Always has at least 1 entry (slot 0); onion-skin
  // grows it to N when the descriptor's `slots[]` is published with N>1.
  NSMutableArray<_KKMiniFilmSlot *> *_filmstripSlots;
  NSTimer *_pollTimer;
  id _keyMon;       // Cmd-0 reset-zoom local keyDown monitor
  id _keyGlobalMon; // Cmd-0 reset-zoom global keyDown monitor (XPC: events
                    // arrive global, like scroll/magnify)
  _KKMiniViewerOverlay *_overlay;
  CGFloat _zoom;           // 1 == aspect-fit
  CGPoint _panPixels;      // drawable-space pan offset
  CGSize _sourceMediaSize; // original media px (from descriptor srcW/H)
  // Deferred filmstrip cell activation: mouseDown records the candidate cell
  // but waits for mouseUp so a click-drag pan doesn't swap the active cell.
  // Cancelled in mouseDragged once the gesture moves past the click threshold.
  BOOL _hasPendingFilmstripActivation;
  double _pendingFilmstripTag;
  CGFloat _filmstripDragDistance; // accumulated |delta| in view points
  // OSC-glyph render pipelines: built in _buildPipeline (+Rendering category),
  // consumed by the +Rendering encoders.
  id<MTLRenderPipelineState> _pointPipeline;
  id<MTLRenderPipelineState> _squarePipeline;
  id<MTLRenderPipelineState> _arcPipeline;
  id<MTLRenderPipelineState> _ringPipeline;
  id<MTLRenderPipelineState> _rotationPipeline;
  id<MTLRenderPipelineState> _linePipeline;
  id<MTLRenderPipelineState> _aaLinePipeline;
}
- (CGRect)contentRectInViewPoints;
- (CGSize)sourceMediaSize;

// Slot/texture resolution + filmstrip geometry (main file); called by the
// +Draw category's drawInMTKView.
- (BOOL)_resolveSlot:(_KKMiniFilmSlot *)slot
                 sid:(uint32_t)sid
                 gen:(uint64_t)gen
                 tag:(double)tag;
- (NSUInteger)_activeSlotIndex;
- (void)_syncSlot0Aliases;
- (CGRect)_contentRectInDrawable;
- (CGRect)_filmstripCellRectInDrawable:(NSUInteger)i ofTotal:(NSUInteger)n;
- (void)_ensureProcessedTextureForSlot:(_KKMiniFilmSlot *)slot;
- (void)_ensureProcessedTexture;
- (void)_installKeyMonitor;

@end

// Drawing / MTKViewDelegate. The protocol is adopted on this category (not the
// () extension) so the primary @implementation isn't expected to provide the
// required delegate methods - they live in KKMiniViewerView+Draw.m.
@interface KKMiniViewerView (Draw) <MTKViewDelegate>
@end

// Pipeline construction + Metal glyph/line encoders. Implemented in
// KKMiniViewerView+Rendering.m; called by drawInMTKView in the +Draw category.
@interface KKMiniViewerView (Rendering)
- (void)_buildPipeline;
- (CGFloat)_canvasScale;
- (void)_encodeArcHandleGlyphAt:(CGPoint)centerPts
                       isActive:(BOOL)isActive
                     ghostAlpha:(CGFloat)ghostAlpha
                        encoder:(id<MTLRenderCommandEncoder>)enc;
- (void)_encodeRotationOSCAt:(CGPoint)centerPts
                    radiusPx:(CGFloat)radiusPx
                      params:(KKRotationOSCParams)params
                     encoder:(id<MTLRenderCommandEncoder>)enc;
// Single-pass elliptical fill+outline ring, using the viewer's
// KKRingOSCFragment (same shader the in-viewer radius ring uses) - no
// tessellation seams or fill/outline bleed. Center + radii + widths are in
// overlay points (y-up).
- (void)_encodeRingOSCAt:(CGPoint)centerPts
               radiusXPt:(CGFloat)radiusXPt
               radiusYPt:(CGFloat)radiusYPt
               fillColor:(simd_float4)fillColor
             strokeColor:(simd_float4)strokeColor
             fillWidthPt:(CGFloat)fillWidthPt
          outlineWidthPt:(CGFloat)outlineWidthPt
                 encoder:(id<MTLRenderCommandEncoder>)enc;
- (void)_encodeRectBorder:(CGRect)br
                lineColor:(simd_float4)lineColor
                  encoder:(id<MTLRenderCommandEncoder>)enc;
- (void)_encodeHandleGlyphAt:(CGPoint)centerPts
                   fillColor:(simd_float4)fillColor
                     encoder:(id<MTLRenderCommandEncoder>)enc;
- (void)_encodeHandleGlyphAt:(CGPoint)centerPts
                   fillColor:(simd_float4)fillColor
                   sizeScale:(CGFloat)sizeScale
                     encoder:(id<MTLRenderCommandEncoder>)enc;
- (void)_encodeSquareGlyphAt:(CGPoint)centerPts
                  ghostAlpha:(CGFloat)ghostAlpha
                   sizeScale:(CGFloat)sizeScale
                     encoder:(id<MTLRenderCommandEncoder>)enc;
- (void)_encodeMotionLineStrip:(NSArray<NSValue *> *)pointsPts
                         color:(simd_float4)color
                   halfWidthPt:(CGFloat)halfWidthPt
                       encoder:(id<MTLRenderCommandEncoder>)enc;
@end

// View transform / hit geometry. Implemented in KKMiniViewerView+Interaction.m
// (the same @implementation that provides the public (Interaction) methods).
@interface KKMiniViewerView (InteractionInternal)
- (CGFloat)_backingScale;
- (void)_zoomTo:(CGFloat)newZoom aboutViewPoint:(NSPoint)viewPt;
- (void)_didChangeViewTransformOfKind:(KKMiniViewerTransformKind)kind;
- (NSPoint)_viewPointForScreenPoint:(NSPoint)screenPoint;
- (NSRect)_screenRectForHandleCenter:(CGPoint)ctr;
- (NSRect)_screenRectForHandleCenters:(NSArray<NSValue *> *)centers
                              atIndex:(NSInteger)index;
- (BOOL)_pointFromGlobalEvent:(NSPoint *)outViewPt;
@end

NS_ASSUME_NONNULL_END
