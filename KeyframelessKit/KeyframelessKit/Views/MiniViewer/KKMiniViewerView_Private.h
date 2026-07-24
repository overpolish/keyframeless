/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKMiniViewerView.h"
#import "KKOSCGlyphStyle.h"
#import <IOSurface/IOSurface.h>
#import <KeyframelessKit/KKShaderTypes.h> // KKVertex2D
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>

// Outer radius (points) of the shared KKPointOSC handle glyph. Smaller than
// the viewer OSC's oscSize - the mini viewer is a compact preview. Must stay
// in sync with a plugin renderer's mini-OSC size (placement/hit).
// Shared by the main file's interaction code and the +Rendering encoders.
// The mini's standard handle-glyph outer radius DERIVES from the viewer's
// (KKOSCGlyphStyle.h): viewer outer x the mini's half-size proportion rule.
// It was a bare 4.5 that happened to equal 9 x 0.5 - now the relationship is
// the code.
#define kKKMiniHandleOuterPt (KKOSCPointOuterPx * KKOSCMiniGlyphRatio)

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
@property(nonatomic, nullable) IOSurfaceRef surface;
@property(nonatomic, strong, nullable) id<MTLTexture> sourceTexture;
@property(nonatomic, strong, nullable) id<MTLTexture> processedTexture;
@property(nonatomic) double tag; // the slot's clip fraction
@end

@interface KKMiniViewerView () {
@package
  id<MTLRenderPipelineState> _pipeline;
  // Same passthrough but NEAREST magnification, swapped in past a zoom
  // threshold so a zoomed-in preview shows crisp texels instead of bilinear
  // blur.
  id<MTLRenderPipelineState> _pipelineNearest;
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
  // A SECOND texture (not a second time), from the descriptor's optional
  // `channel1`. Outside _filmstripSlots on purpose: that array's count tracks
  // the onion/filmstrip fan-out, so an index into it would move. nil unless the
  // feed publishes one. Exposed to renderers as -channel1Texture.
  _KKMiniFilmSlot *_channel1Slot;
  NSTimer *_pollTimer;
  id _keyMon;       // Cmd-0 reset-zoom local keyDown monitor
  id _keyGlobalMon; // Cmd-0 reset-zoom global keyDown monitor (XPC: events
                    // arrive global, like scroll/magnify)
  id _magnifyMon;   // pinch-to-zoom local magnify monitor: AppKit delivers
                    // magnify gestures ONLY to the key window, so when the
                    // companion layer list holds key (popover non-key) a pinch
  // over the mini never reaches magnifyWithEvent:. The monitor
  // catches the app's magnify events regardless of which
  // window is key and routes by pointer location. (Pan needs
  // no monitor: AppKit delivers scrollWheel: to inactive
  // windows already.)
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
  id<MTLRenderPipelineState> _toolbarPipeline;
  // The render encoder armed during -miniViewerDrawToolOverlay: so the public
  // encodeTool* methods can encode into the current pass. nil otherwise.
  __unsafe_unretained id<MTLRenderCommandEncoder> _toolEncoder;
  // Tool-overlay primitive batch (opaque KKToolBatch*, owned by +Draw.m), armed
  // around the overlay delegate call. While armed, encodeToolDot/LineStrip
  // accumulate per-colour vertex buckets instead of issuing a draw each; the
  // buckets flush as one drawPrimitives per colour. nil when not batching.
  void *_toolBatch;
  // Set only around an interaction-driven synchronous draw (pan/zoom via
  // -_drawNowForInteraction). While YES, drawInMTKView reuses each slot's
  // existing processed texture instead of re-running the (unchanging) plugin
  // effect - panning can't change the rendered content, only the view
  // transform, so re-rendering it every frame was wasted time that throttled
  // the scroll event rate. Normal redraws (param edits via setNeedsDisplay)
  // leave this NO and render fresh, so there's no staleness.
  BOOL _reuseProcessedTexture;
  // CACurrentMediaTime of the last pan/zoom gesture event. The overlay's
  // hitTest: skips its expensive per-anchor handle hit-test while this is
  // recent (a scroll/pinch never targets a handle), so a dense path doesn't pay
  // ~35ms of hit-testing per scroll event - that was the real pan throttle.
  NSTimeInterval _lastPanZoomTime;
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
// Returns YES if it (re)created the slot's processed texture this call (size
// changed / first use), NO if it reused the existing one. Callers that skip the
// effect/generate pass during an interaction frame must still run it when a new
// (blank) texture was just made, or a resized slot draws black.
- (BOOL)_ensureProcessedTextureForSlot:(_KKMiniFilmSlot *)slot;
- (void)_ensureProcessedTexture;
// A source-less generator delegate: implements generateIntoTexture: and NOT
// processSourceTexture:. Such a delegate publishes no feed slots, so filmstrip/
// onion slots are built from its keypose fractions instead of the descriptor.
- (BOOL)_isGeneratorDelegate;
// Rebuild _filmstripSlots as one surfaceless slot per keypose fraction (from
// the generator delegate) when renderMode != Off, else a single slot. Returns
// YES if the slot set changed. No-op for non-generator delegates.
- (BOOL)_rebuildGeneratorSlots;
- (void)_installKeyMonitor;

@end

// Drawing / MTKViewDelegate. The protocol is adopted on this category (not the
// () extension) so the primary @implementation isn't expected to provide the
// required delegate methods - they live in KKMiniViewerView+Draw.m.
@interface KKMiniViewerView (Draw) <MTKViewDelegate>
@end

// Tool-overlay primitive batching. Implemented in KKMiniViewerView+ToolBatch.m
// (along with the public (ToolDraw) encode methods). drawInMTKView arms a batch
// around the overlay delegate call via begin/end; the encoders accumulate into
// per-colour vertex buckets and flush as one draw each.
@interface KKMiniViewerView (ToolBatchInternal)
- (void)_beginToolBatch;
- (void)_endToolBatch;
- (void)_flushToolBatchBuckets;
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
- (void)_encodeGridWithSpacingX:(CGFloat)nx
                       spacingY:(CGFloat)ny
                    contentRect:(CGRect)cr
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
// Vertex generators shared by the immediate encoders above and the batched
// tool-overlay path (+Draw.m). They fill a caller buffer rather than encoding,
// so the batch can pack many primitives into one draw. The dot helper writes
// exactly 6 verts; the line helper writes up to (count-1)*6 and returns how
// many.
- (void)_toolDotQuad:(KKVertex2D *)out
            atCenter:(CGPoint)centerPts
           sizeScale:(CGFloat)sizeScale;
- (NSUInteger)_toolLineVerts:(KKVertex2D *)out
                      points:(const CGPoint *)pts
                       count:(NSUInteger)count
                 halfWidthPt:(CGFloat)halfWidthPt;
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
/// YES if a pan/zoom gesture event arrived very recently. The overlay's
/// hitTest: skips its expensive per-anchor handle hit-test while this holds.
- (BOOL)_isPanZoomGestureActive;
@end

NS_ASSUME_NONNULL_END
