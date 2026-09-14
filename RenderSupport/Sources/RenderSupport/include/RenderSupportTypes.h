/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <simd/simd.h>
typedef enum RSRenderVertexIndex {
    RSRenderVertexIndexVertices = 0,
    RSRenderVertexIndexViewportSize = 1
} RSRenderVertexIndex;
#define RS_RENDER_BLUR_MAX_SAMPLES 128
typedef struct {
    vector_float2 position;
    vector_float2 textureCoordinate;
} RSRenderVertex2D;

enum { RSRenderTextureIndexInputImage = 0 };
