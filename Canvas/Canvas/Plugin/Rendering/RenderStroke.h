/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>

/// Render the stroke (and markers) for a path. Handles contour splitting,
/// dashed/dotted styles, and start/end markers.
void KKRenderStrokeForPath(KKBezierPath *_Nonnull path, float outputWidth, float outputHeight,
                           id<MTLDevice> _Nonnull device, id<MTLCommandBuffer> _Nonnull commandBuffer,
                           id<MTLTexture> _Nonnull outputTexture, id<MTLRenderPipelineState> _Nonnull strokePS,
                           simd_uint2 viewportSize);
