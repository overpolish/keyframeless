/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Velocity-buffer motion-blur reconstruction (McGuire 2012 / Guertin 2014),
/// shared across plugins. Given a rendered COLOUR texture and a per-pixel
/// screen-space VELOCITY texture (RG16Float, pixel displacement over the shutter,
/// +x right / +y down in the texture's own space), it reconstructs a
/// motion-blurred image in three cheap passes - TileMax -> NeighborMax -> a
/// fixed-tap reconstruction gather - whose cost is INDEPENDENT of blur length
/// (handled by the tile reach, not a sample count).
///
/// Intended use is PER-LAYER (per-object): render one layer's colour into a
/// transparent full-frame texture and its analytic velocity into a matching
/// RG16Float texture, reconstruct, then composite the result. Premultiplied
/// colour means a moving layer smears softly into its own transparent margin, and
/// compositing per layer sidesteps the single-velocity-per-pixel artifact of a
/// full-screen velocity buffer (two layers overlapping a pixel can't both blur).
///
/// This is the "Fast" technique; KKMotionBlur's sample-and-accumulate remains the
/// universal "Accurate" path (footage content smear, extreme in-shutter
/// rotation). Plugins that draw through KKTransformVertexShader get a matching
/// velocity buffer for free via the paired velocity shader.
@interface KKMotionBlurReconstruct : NSObject

/// Encodes the three reconstruction passes onto `commandBuffer`, writing the
/// blurred result into `dest` (overwrites; not blended). `color` and `velocity`
/// must share `dest`'s dimensions; `velocity` must be RG16Float with ShaderRead.
/// `tileSize` (px, e.g. 32) bounds the maximum blur reach; a velocity longer than
/// one tile is clamped. `sampleCount` is the gather tap count (clamped 3..31;
/// ~9-15 is plenty). The caller owns / pools `dest`, `color` and `velocity` and
/// commits the command buffer. Returns NO on setup failure (the caller should
/// fall back to its unblurred composite).
+ (BOOL)encodeReconstructionToTexture:(id<MTLTexture>)dest
                         colorTexture:(id<MTLTexture>)color
                      velocityTexture:(id<MTLTexture>)velocity
                             tileSize:(int)tileSize
                          sampleCount:(int)sampleCount
                           registryID:(uint64_t)registryID
                               device:(id<MTLDevice>)device
                        commandBuffer:(id<MTLCommandBuffer>)commandBuffer;

@end

NS_ASSUME_NONNULL_END
