/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MirageMiniViewerRenderer.h"
#import <KeyframelessKit/KeyframelessKit.h>

#import <Metal/Metal.h>

@class KKPointOSCSet;
@class KKRotationOSCSet;
@class MirageExprMiniSet;

NS_ASSUME_NONNULL_BEGIN

@interface _MirageNeighborConversion : NSObject
@property(nonatomic, strong, nullable) id<MTLTexture> raw;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL technicalTransform;
@property(nonatomic, strong, nullable) id<MTLTexture> converted;
@end

// The clip textures one DRAW hands the chain, converted at most once each.
//
// Every entry decides its own colour treatment (an ordinary Shadertoy shader
// wants gamma, a `color-transform` wants linear), but the clip they are
// treatments OF is the same texture for the whole draw - and each conversion is
// a full-frame render pass plus an RGBA16Float allocation. Memoised here so a
// three-entry chain costs the same two conversions a single template does.
@interface _MirageMiniChainInputs : NSObject {
@package
  id<MTLTexture> _sourceLinear;
  id<MTLTexture> _sourceGamma;
  id<MTLTexture> _channel1Linear;
  id<MTLTexture> _channel1Gamma;
  BOOL _channel1Resolved;
}
@end

@interface MirageMiniViewerRenderer () {
@package
  // Keyed "custom:<pixelFormat>:<mslDigest>" - the format belongs in the key
  // because one draw of a chain renders into two different ones.
  NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *_pipelines;
  // Render-at-reference-resolution + downscale (so the small mini texture shows
  // a proper minified copy of a full-res render: grain, dither, everything).
  id<MTLTexture> _hiResTex;
  id<MTLRenderPipelineState> _blitPipeline;
  MTLPixelFormat _blitFormat;
  id<MTLSamplerState> _linearSampler;
  // Source last fed to -_syncMiniPointController, so the per-draw sync is a
  // cheap string compare instead of re-running the directive parse each frame.
  NSString *_pointSyncedSource;
  KKPointOSCSet *_pointSet;
  NSString *_rotSyncedSource;
  KKRotationOSCSet *_rotSet;
  MirageExprMiniSet *_exprSet;
  // Last logged `// #frames` bind state (declared count / first offset / pumped
  // count), so the diagnostic fires on a change instead of once per drawn
  // frame.
  NSString *_neighborBindSignature;
  // Colour-matched neighbours, one entry per aux index. Same shape as the
  // _hiResTex / _pipelines caches: an ivar-held Metal object rebuilt only when
  // its key inputs change.
  NSMutableArray<_MirageNeighborConversion *> *_neighborConversions;
  // One RGBA16Float intermediate per chain POSITION (not per entry id), so a
  // reorder reuses them and only a resize reallocates.
  NSMutableArray *_chainTextures;
}
// The reusable mini-viewer Position OSC set - one KKPositionMiniController per
// `#point osc` lane, all drawn/dragged uniformly (no "primary"). The
// Interaction category forwards every KKMiniViewerDelegate point method to it;
// Mirage only parses the source for the osc-point uniform names and feeds them
// in.
@property(nonatomic, strong, readonly) KKPointOSCSet *pointSet;
// The reusable mini-viewer rotation set - the mini sibling of the viewer's
// KKRotationOSC loop, one 3-ring gizmo per `osc={..}` lane. Interaction
// forwards the rotation draw + generic handle methods here; Mirage feeds it the
// rotate specs (label + active-axis bitmask + clip-centre) from the source.
@property(nonatomic, strong, readonly) KKRotationOSCSet *rotSet;
// The mini sibling of the viewer's `// @osc` control loop (directive sugar
// included): point glyphs, value rings, boxes - one control per block.
// Interaction forwards the draw + generic handle methods here; Mirage feeds it
// the source (which it parses + compiles through the shared
// MirageOSCBlockRuntime).
@property(nonatomic, strong, readonly) MirageExprMiniSet *exprSet;
// Re-derive the set's lane labels from the current shader source. Cheap no-op
// when the source is unchanged.
- (void)_syncMiniPointController;
// Re-derive the rotation set's specs from the current shader source. Cheap
// no-op when the source is unchanged.
- (void)_syncMiniRotController;
// Re-derive the custom `// @osc` handles from the current shader source. Cheap
// no-op when the source is unchanged.
- (void)_syncMiniExprController;

/// Entry-scoped source accessors. The chain asks these per entry; the OSC
/// sets ask them for the SELECTED entry.
/// The entry the on-screen controls belong to, defaulted to the sentinel.
- (NSString *)_oscEntryID;
/// A shader-authored (bare) key in that entry's namespace, idempotently.
- (NSString *)_oscScopedKey:(NSString *)key;
- (nullable NSString *)_customShaderSourceForEntry:(NSString *)entryID;
- (nullable NSString *)_customShaderSource;
/// All Custom sections from one entry's code lane, by name.
- (NSDictionary<NSString *, NSString *> *)_customSectionsForEntry:
    (NSString *)entryID;
@end

@interface MirageMiniViewerRenderer (Interaction)
@end

/// The preview's Metal plumbing, implemented in
/// MirageMiniViewerRenderer+Metal.m. Every one of these is a cache: the chain
/// calls them once per entry per draw, and they are what keeps that cheap.
@interface MirageMiniViewerRenderer (Metal)
- (nullable id<MTLRenderPipelineState>)
    _customPipelineForDevice:(id<MTLDevice>)device
                 pixelFormat:(MTLPixelFormat)format
                      source:(NSString *)userSource
                  bufferMode:(BOOL)bufferMode;
/// nil when `dest` is already tall enough to render into directly.
- (nullable id<MTLTexture>)hiResTargetForDest:(id<MTLTexture>)dest;
- (nullable id<MTLRenderPipelineState>)
    blitPipelineForDevice:(id<MTLDevice>)device
                   format:(MTLPixelFormat)format;
- (nullable id<MTLSamplerState>)linearSamplerForDevice:(id<MTLDevice>)device;
/// An _sRGB-typed view of the same IOSurface, so sampling returns LINEAR.
- (id<MTLTexture>)_linearSourceView:(id<MTLTexture>)source;
/// The `// #frames` neighbour textures for `source`, in DIRECTIVE order. Call
/// BEFORE opening any render encoder on `commandBuffer` - see the note on the
/// implementation.
- (NSArray *)_neighborTexturesForSource:(NSString *)source
                     technicalTransform:(BOOL)technicalTransform
                          commandBuffer:(id<MTLCommandBuffer>)commandBuffer;
@end

/// The preview's shader chain, implemented in
/// MirageMiniViewerRenderer+Chain.m. Reads the entry-scoped source accessors
/// above and drives the Metal category per entry.
@interface MirageMiniViewerRenderer (Chain)
@end

NS_ASSUME_NONNULL_END
