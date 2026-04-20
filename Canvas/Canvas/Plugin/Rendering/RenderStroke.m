/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "RenderStroke.h"
#import "MarkerTessellation.h"
#import "ShaderTypes.h"
#import "Tessellation.h"

static void renderMarker(uint8_t marker, simd_float2 pos, simd_float2 tangent,
                         simd_float2 normal, float markerSize, float strokeW,
                         KKBezierPath *path, float outputWidth,
                         float outputHeight, id<MTLDevice> device,
                         id<MTLCommandBuffer> commandBuffer,
                         id<MTLTexture> outputTexture,
                         id<MTLRenderPipelineState> strokePS,
                         simd_uint2 viewportSize, simd_float4 color) {
  CanvasVertex markerVerts[256];
  MTLPrimitiveType markerPrim = MTLPrimitiveTypeTriangleStrip;
  NSUInteger mc = 0;
  if (path.sketchEnabled && path.sketchRoughness > 0.0001f) {
    mc = KKTessellateSketchMarker(marker, pos, tangent, normal, markerSize,
                                  strokeW, path.sketchRoughness,
                                  path.sketchSeed, &markerPrim, markerVerts);
  } else {
    mc = KKTessellateMarker(marker, pos, tangent, normal, markerSize, strokeW,
                            &markerPrim, markerVerts);
  }
  if (mc == 0)
    return;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = outputTexture;
  rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
  [enc setRenderPipelineState:strokePS];
  id<MTLBuffer> buf = [device newBufferWithBytes:markerVerts
                                          length:mc * sizeof(CanvasVertex)
                                         options:MTLResourceStorageModeShared];
  [enc setVertexBuffer:buf offset:0 atIndex:0];
  [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
  [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
  [enc drawPrimitives:markerPrim vertexStart:0 vertexCount:mc];
  [enc endEncoding];
}

static void renderStrokeForSinglePath(KKBezierPath *path, float outputWidth,
                                      float outputHeight, id<MTLDevice> device,
                                      id<MTLCommandBuffer> commandBuffer,
                                      id<MTLTexture> outputTexture,
                                      id<MTLRenderPipelineState> strokePS,
                                      simd_uint2 viewportSize) {
  float sw = path.strokeWidth;
  float ew = (path.endWidth > 0) ? path.endWidth : sw;
  float oa = path.opacity;
  simd_float4 color = {path.strokeR * oa, path.strokeG * oa, path.strokeB * oa,
                       oa};

  uint8_t startMarker = path.startMarker;
  uint8_t endMarker = path.endMarker;
  BOOL hasMarkers = !path.closed && (startMarker != 0 || endMarker != 0);
  float startMarkerSz = sw * path.startMarkerSize;
  float endMarkerSz = ew * path.endMarkerSize;
  float startPullback =
      hasMarkers ? KKMarkerPullback(startMarker, startMarkerSz) : 0;
  float endPullback = hasMarkers ? KKMarkerPullback(endMarker, endMarkerSz) : 0;
  // Any marker present at an endpoint needs a positive trim so
  // KKTessellateTrimmedPath suppresses the cap at that end.
  if (startMarker != 0 && startPullback <= 0.0f)
    startPullback = 0.001f;
  if (endMarker != 0 && endPullback <= 0.0f)
    endPullback = 0.001f;

  CanvasVertex *vertices = NULL;
  NSUInteger vertexCount = 0;
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;

  if (path.strokeStyle == 1) {
    NSUInteger maxVertices = curveCount * segsPerCurve * 12 + 8192;
    vertices = malloc(maxVertices * sizeof(CanvasVertex));
    vertexCount = KKTessellateDashedPath(path, sw, ew, outputWidth,
                                         outputHeight, path.dashLength,
                                         path.dashGap, path.lineJoin, vertices);
  } else if (path.strokeStyle == 2) {
    NSUInteger maxVertices = curveCount * segsPerCurve * 4 + 4096;
    vertices = malloc(maxVertices * sizeof(CanvasVertex));
    vertexCount = KKTessellateDottedPath(path, sw, ew, outputWidth,
                                         outputHeight, path.dotGap, vertices);
  } else if (hasMarkers) {
    NSUInteger maxVertices = curveCount * ((segsPerCurve + 1) * 2 + 2) + 256;
    vertices = malloc(maxVertices * sizeof(CanvasVertex));
    vertexCount = KKTessellateTrimmedPath(
        path, sw, ew, outputWidth, outputHeight, path.lineCap, path.lineJoin,
        startPullback, endPullback, vertices);
  } else {
    NSUInteger capExtra = (!path.closed && path.lineCap != 0) ? 256 : 0;
    NSUInteger joinExtra = (path.lineJoin != 0) ? curveCount * 48 : 0;
    NSUInteger maxVertices =
        curveCount * ((segsPerCurve + 1) * 2 + 2) + 2 + capExtra + joinExtra;
    vertices = malloc(maxVertices * sizeof(CanvasVertex));
    vertexCount = KKTessellatePath(path, sw, ew, outputWidth, outputHeight,
                                   path.lineCap, path.lineJoin, vertices);
  }

  if (vertexCount > 0 && vertices) {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = outputTexture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLRenderCommandEncoder> enc =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
    [enc setRenderPipelineState:strokePS];

    id<MTLBuffer> vertexBuffer =
        [device newBufferWithBytes:vertices
                            length:vertexCount * sizeof(CanvasVertex)
                           options:MTLResourceStorageModeShared];
    [enc setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
    [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:vertexCount];
    [enc endEncoding];
  }
  free(vertices);

  // Draw markers as separate draw calls.
  if (hasMarkers && path.count >= 2) {
    PathSample *samples = NULL;
    NSUInteger sampleCount =
        KKSamplePathPolyline(path, outputWidth, outputHeight, &samples);

    if (sampleCount >= 2) {
      float totalArc = samples[sampleCount - 1].arcLength;
      NSUInteger hint = 0;

      if (endMarker != 0) {
        float minTangentPull = endMarkerSz * 0.3f;
        float pullbackArc = totalArc - fmaxf(endPullback, minTangentPull);
        if (pullbackArc < 0.0f)
          pullbackArc = 0.0f;
        PathSample pullbackSample =
            KKSampleAtArc(samples, sampleCount, pullbackArc, &hint);
        simd_float2 eNorm = pullbackSample.normal;
        simd_float2 eTan = (simd_float2){eNorm.y, -eNorm.x};
        simd_float2 endPos = samples[sampleCount - 1].position;
        renderMarker(endMarker, endPos, eTan, eNorm, endMarkerSz, ew, path,
                     outputWidth, outputHeight, device, commandBuffer,
                     outputTexture, strokePS, viewportSize, color);
      }

      if (startMarker != 0) {
        float minTangentPull = startMarkerSz * 0.3f;
        float pullbackArc = fmaxf(startPullback, minTangentPull);
        if (pullbackArc > totalArc)
          pullbackArc = totalArc;
        hint = 0;
        PathSample pullbackSample =
            KKSampleAtArc(samples, sampleCount, pullbackArc, &hint);
        simd_float2 sNorm = pullbackSample.normal;
        simd_float2 sTan = (simd_float2){-sNorm.y, sNorm.x};
        simd_float2 startPos = samples[0].position;
        renderMarker(startMarker, startPos, sTan, sNorm, startMarkerSz, sw,
                     path, outputWidth, outputHeight, device, commandBuffer,
                     outputTexture, strokePS, viewportSize, color);
      }
    }
    free(samples);
  }
}

void KKRenderStrokeForPath(KKBezierPath *path, float outputWidth,
                           float outputHeight, id<MTLDevice> device,
                           id<MTLCommandBuffer> commandBuffer,
                           id<MTLTexture> outputTexture,
                           id<MTLRenderPipelineState> strokePS,
                           simd_uint2 viewportSize) {
  NSArray<KKBezierPath *> *contours = [path splitContours];
  if (contours) {
    for (KKBezierPath *sub in contours)
      renderStrokeForSinglePath(sub, outputWidth, outputHeight, device,
                                commandBuffer, outputTexture, strokePS,
                                viewportSize);
    return;
  }
  renderStrokeForSinglePath(path, outputWidth, outputHeight, device,
                            commandBuffer, outputTexture, strokePS,
                            viewportSize);
}
