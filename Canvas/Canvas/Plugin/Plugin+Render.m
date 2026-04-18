/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "LayerList_Private.h"
#import "MarkerTessellation.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import "SketchFill.h"
#import "SketchPath.h"
#import "Tessellation.h"
#import <IOSurface/IOSurfaceObjC.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

static id<MTLRenderPipelineState> getOrCreatePipeline(
    NSString *key, uint64_t registryID, MTLPixelFormat pixelFormat,
    KKMetalDeviceCache *cache, id<MTLDevice> device, NSString *vertexName,
    NSString *fragmentName, BOOL blending, MTLPixelFormat stencilFormat) {
  id<MTLRenderPipelineState> ps = [cache pipelineStateForPluginID:key
                                                       registryID:registryID
                                                      pixelFormat:pixelFormat];
  if (ps)
    return ps;

  id<MTLLibrary> library = [device newDefaultLibrary];
  MTLRenderPipelineDescriptor *desc =
      [[MTLRenderPipelineDescriptor alloc] init];
  desc.vertexFunction = [library newFunctionWithName:vertexName];
  desc.fragmentFunction = [library newFunctionWithName:fragmentName];
  desc.colorAttachments[0].pixelFormat = pixelFormat;
  if (blending) {
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
  }
  if (stencilFormat != MTLPixelFormatInvalid)
    desc.stencilAttachmentPixelFormat = stencilFormat;
  if (!blending && stencilFormat != MTLPixelFormatInvalid)
    desc.colorAttachments[0].writeMask = MTLColorWriteMaskNone;

  NSError *error = nil;
  ps = [device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (ps)
    [cache registerPipelineState:ps
                     forPluginID:key
                      registryID:registryID
                     pixelFormat:pixelFormat];
  return ps;
}

/// Build a stencil triangle fan for a path, one fan per contour.
/// Each contour gets its own closed fan from its centroid so the stencil
/// winding is correct for even-odd compound fills.
/// Caller must free *outVerts.
static NSUInteger buildFillFan(KKBezierPath *path, float outputWidth,
                               float outputHeight,
                               CanvasFillVertex **outVerts) {
  NSUInteger segsPerCurve = 64;
  NSUInteger nc = path.contourCount;

  // First pass: compute total outline capacity.
  NSUInteger totalMax = 0;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    // Each contour is closed, so curveCount = length.
    totalMax += r.length * segsPerCurve + 1;
  }

  simd_float2 *outline = malloc(totalMax * sizeof(simd_float2));
  NSUInteger *fanStarts = malloc((nc + 1) * sizeof(NSUInteger));
  NSUInteger oc = 0;

  for (NSUInteger ci = 0; ci < nc; ci++) {
    fanStarts[ci] = oc;
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger cStart = r.location;
    NSUInteger cLen = r.length;
    // Closed contour: curveCount = length (last point wraps to first).
    for (NSUInteger c = 0; c < cLen; c++) {
      NSUInteger idx = cStart + c;
      NSUInteger nextIdx = cStart + ((c + 1) % cLen);
      for (NSUInteger s = 0; s < segsPerCurve; s++) {
        float t = (float)s / (float)segsPerCurve;
        simd_float2 pos = [path evaluatePointAtIndex:idx
                                           nextIndex:nextIdx
                                                 atT:t];
        outline[oc++] =
            (simd_float2){pos.x * outputWidth - outputWidth / 2.0f,
                          (1.0f - pos.y) * outputHeight - outputHeight / 2.0f};
      }
    }
  }
  fanStarts[nc] = oc; // sentinel

  // Build triangle fans — one per contour, each with its own centroid.
  CanvasFillVertex *fillVerts = malloc(oc * 3 * sizeof(CanvasFillVertex));
  NSUInteger ti = 0;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSUInteger start = fanStarts[ci];
    NSUInteger end = fanStarts[ci + 1];
    NSUInteger len = end - start;
    if (len < 2)
      continue;
    // Remove near-duplicate endpoint (closed paths that trace back to start).
    simd_float2 first = outline[start];
    simd_float2 last = outline[end - 1];
    float dx = first.x - last.x, dy = first.y - last.y;
    if (dx * dx + dy * dy < 1.0f)
      len--;
    if (len < 2)
      continue;
    simd_float2 center = {0, 0};
    for (NSUInteger i = 0; i < len; i++)
      center += outline[start + i];
    center /= (float)len;
    for (NSUInteger i = 0; i < len; i++) {
      NSUInteger cur = start + i;
      NSUInteger next = start + ((i + 1) % len);
      fillVerts[ti * 3 + 0].position = center;
      fillVerts[ti * 3 + 1].position = outline[cur];
      fillVerts[ti * 3 + 2].position = outline[next];
      ti++;
    }
  }
  free(outline);
  free(fanStarts);

  *outVerts = fillVerts;
  return ti;
}

static void renderFillForPath(KKBezierPath *path, float outputWidth,
                              float outputHeight, id<MTLDevice> device,
                              id<MTLCommandBuffer> commandBuffer,
                              id<MTLTexture> outputTexture,
                              id<MTLTexture> stencilTexture,
                              id<MTLRenderPipelineState> fillStencilPS,
                              id<MTLRenderPipelineState> fillColorPS,
                              id<MTLDepthStencilState> fillStencilDSState,
                              id<MTLDepthStencilState> fillColorDSState,
                              simd_uint2 viewportSize) {
  CanvasFillVertex *fillVerts = NULL;
  NSUInteger triCount =
      buildFillFan(path, outputWidth, outputHeight, &fillVerts);

  id<MTLBuffer> fillBuf =
      [device newBufferWithBytes:fillVerts
                          length:triCount * 3 * sizeof(CanvasFillVertex)
                         options:MTLResourceStorageModeShared];
  free(fillVerts);

  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = outputTexture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.stencilAttachment.texture = stencilTexture;
    rpd.stencilAttachment.loadAction = MTLLoadActionClear;
    rpd.stencilAttachment.storeAction = MTLStoreActionStore;
    rpd.stencilAttachment.clearStencil = 0;

    id<MTLRenderCommandEncoder> enc =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
    [enc setRenderPipelineState:fillStencilPS];
    [enc setDepthStencilState:fillStencilDSState];
    [enc setStencilReferenceValue:0];
    [enc setVertexBuffer:fillBuf offset:0 atIndex:0];
    [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle
            vertexStart:0
            vertexCount:triCount * 3];
    [enc endEncoding];
  }

  {
    float a = path.opacity;
    simd_float4 fc = {path.fillR * a, path.fillG * a, path.fillB * a, a};

    CanvasFillVertex quadVerts[6] = {
        {{-(float)outputWidth, -(float)outputHeight}},
        {{(float)outputWidth, -(float)outputHeight}},
        {{-(float)outputWidth, (float)outputHeight}},
        {{(float)outputWidth, -(float)outputHeight}},
        {{(float)outputWidth, (float)outputHeight}},
        {{-(float)outputWidth, (float)outputHeight}},
    };

    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = outputTexture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.stencilAttachment.texture = stencilTexture;
    rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
    rpd.stencilAttachment.storeAction = MTLStoreActionDontCare;

    id<MTLRenderCommandEncoder> enc =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
    [enc setRenderPipelineState:fillColorPS];
    [enc setDepthStencilState:fillColorDSState];
    [enc setStencilReferenceValue:0];
    [enc setVertexBytes:quadVerts length:sizeof(quadVerts) atIndex:0];
    [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
    [enc setFragmentBytes:&fc length:sizeof(fc) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [enc endEncoding];
  }
}

/// Write the shape stencil only (no color pass). Used to clip sketch fills.
static void renderFillStencilOnly(KKBezierPath *path, float outputWidth,
                                  float outputHeight, id<MTLDevice> device,
                                  id<MTLCommandBuffer> commandBuffer,
                                  id<MTLTexture> outputTexture,
                                  id<MTLTexture> stencilTexture,
                                  id<MTLRenderPipelineState> fillStencilPS,
                                  id<MTLDepthStencilState> fillStencilDSState,
                                  simd_uint2 viewportSize) {
  CanvasFillVertex *fillVerts = NULL;
  NSUInteger triCount =
      buildFillFan(path, outputWidth, outputHeight, &fillVerts);

  id<MTLBuffer> fillBuf =
      [device newBufferWithBytes:fillVerts
                          length:triCount * 3 * sizeof(CanvasFillVertex)
                         options:MTLResourceStorageModeShared];
  free(fillVerts);

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = outputTexture;
  rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  rpd.stencilAttachment.texture = stencilTexture;
  rpd.stencilAttachment.loadAction = MTLLoadActionClear;
  rpd.stencilAttachment.storeAction = MTLStoreActionStore;
  rpd.stencilAttachment.clearStencil = 0;

  id<MTLRenderCommandEncoder> enc =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
  [enc setRenderPipelineState:fillStencilPS];
  [enc setDepthStencilState:fillStencilDSState];
  [enc setStencilReferenceValue:0];
  [enc setVertexBuffer:fillBuf offset:0 atIndex:0];
  [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle
          vertexStart:0
          vertexCount:triCount * 3];
  [enc endEncoding];
}

static void renderStrokeForSinglePath(KKBezierPath *path, float outputWidth,
                                      float outputHeight, id<MTLDevice> device,
                                      id<MTLCommandBuffer> commandBuffer,
                                      id<MTLTexture> outputTexture,
                                      id<MTLRenderPipelineState> strokePS,
                                      simd_uint2 viewportSize);

static void renderStrokeForPath(KKBezierPath *path, float outputWidth,
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

  // --- Draw the stroke ---
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

  // --- Draw markers as separate draw calls ---
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
        CanvasVertex markerVerts[256];
        MTLPrimitiveType markerPrim = MTLPrimitiveTypeTriangleStrip;
        NSUInteger mc = 0;
        if (path.sketchEnabled && path.sketchRoughness > 0.0001f) {
          mc = KKTessellateSketchMarker(
              endMarker, endPos, eTan, eNorm, endMarkerSz, ew,
              path.sketchRoughness, path.sketchSeed, &markerPrim, markerVerts);
        } else {
          mc = KKTessellateMarker(endMarker, endPos, eTan, eNorm, endMarkerSz,
                                  ew, &markerPrim, markerVerts);
        }
        if (mc > 0) {
          MTLRenderPassDescriptor *rpd =
              [MTLRenderPassDescriptor renderPassDescriptor];
          rpd.colorAttachments[0].texture = outputTexture;
          rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
          rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
          id<MTLRenderCommandEncoder> enc =
              [commandBuffer renderCommandEncoderWithDescriptor:rpd];
          [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1,
                                         1}];
          [enc setRenderPipelineState:strokePS];
          id<MTLBuffer> buf =
              [device newBufferWithBytes:markerVerts
                                  length:mc * sizeof(CanvasVertex)
                                 options:MTLResourceStorageModeShared];
          [enc setVertexBuffer:buf offset:0 atIndex:0];
          [enc setVertexBytes:&viewportSize
                       length:sizeof(viewportSize)
                      atIndex:1];
          [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
          [enc drawPrimitives:markerPrim vertexStart:0 vertexCount:mc];
          [enc endEncoding];
        }
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
        simd_float2 sTan =
            (simd_float2){-sNorm.y, sNorm.x}; // outward = -path direction
        simd_float2 startPos = samples[0].position;
        CanvasVertex markerVerts[256];
        MTLPrimitiveType markerPrim = MTLPrimitiveTypeTriangleStrip;
        NSUInteger mc = 0;
        if (path.sketchEnabled && path.sketchRoughness > 0.0001f) {
          mc = KKTessellateSketchMarker(
              startMarker, startPos, sTan, sNorm, startMarkerSz, sw,
              path.sketchRoughness, path.sketchSeed, &markerPrim, markerVerts);
        } else {
          mc = KKTessellateMarker(startMarker, startPos, sTan, sNorm,
                                  startMarkerSz, sw, &markerPrim, markerVerts);
        }
        if (mc > 0) {
          MTLRenderPassDescriptor *rpd =
              [MTLRenderPassDescriptor renderPassDescriptor];
          rpd.colorAttachments[0].texture = outputTexture;
          rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
          rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
          id<MTLRenderCommandEncoder> enc =
              [commandBuffer renderCommandEncoderWithDescriptor:rpd];
          [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1,
                                         1}];
          [enc setRenderPipelineState:strokePS];
          id<MTLBuffer> buf =
              [device newBufferWithBytes:markerVerts
                                  length:mc * sizeof(CanvasVertex)
                                 options:MTLResourceStorageModeShared];
          [enc setVertexBuffer:buf offset:0 atIndex:0];
          [enc setVertexBytes:&viewportSize
                       length:sizeof(viewportSize)
                      atIndex:1];
          [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
          [enc drawPrimitives:markerPrim vertexStart:0 vertexCount:mc];
          [enc endEncoding];
        }
      }
    }
    free(samples);
  }
}

static void renderSketchFillForPath(KKBezierPath *origPath, float outputWidth,
                                    float outputHeight, id<MTLDevice> device,
                                    id<MTLCommandBuffer> commandBuffer,
                                    id<MTLTexture> outputTexture,
                                    id<MTLTexture> stencilTexture,
                                    id<MTLRenderPipelineState> strokePS,
                                    id<MTLDepthStencilState> fillColorDSState,
                                    simd_uint2 viewportSize,
                                    BOOL useStencilClip) {
  uint8_t fillStyle = origPath.sketchFillStyle;
  if (fillStyle == 0)
    return;

  KKHachureLine *lines = NULL;
  float sketchRough = origPath.sketchEnabled ? origPath.sketchRoughness : 0.0f;
  uint32_t sketchSeed = origPath.sketchEnabled ? origPath.sketchSeed : 0;
  NSUInteger lineCount = KKGenerateHachureLines(
      origPath, outputWidth, outputHeight, fillStyle, origPath.sketchFillGap,
      origPath.sketchFillAngle, sketchRough, sketchSeed, &lines);
  if (lineCount == 0 || !lines)
    return;

  if (origPath.sketchEnabled) {
    KKSketchifyHachureLines(&lines, &lineCount, origPath.sketchRoughness,
                            origPath.sketchBowing, origPath.sketchSeed,
                            outputWidth, outputHeight);
  }

  float fw = origPath.sketchFillWeight;
  float oa = origPath.opacity;
  simd_float4 color = {origPath.fillR * oa, origPath.fillG * oa,
                       origPath.fillB * oa, oa};
  float halfW = fw / 2.0f;

  // For dots mode: render small filled circles at regular intervals
  // along each hachure line instead of strokes.
  BOOL isDots = (fillStyle == 4);
  float dotRadius = fw * 1.5f;
  float dotSpacing = origPath.sketchFillGap;
  if (dotSpacing < dotRadius * 2.0f)
    dotSpacing = dotRadius * 2.0f;

  // Estimate max vertices needed.
  NSUInteger maxVerts;
  if (isDots) {
    // Each dot is a small circle fan: ~20 triangles * 3 verts.
    NSUInteger dotsPerLine = 50;
    maxVerts = lineCount * dotsPerLine * 60 + 256;
  } else {
    // Each line: 4 verts for a triangle strip + 2 degenerate bridge.
    maxVerts = lineCount * 6 + 256;
  }
  CanvasVertex *vertices = malloc(maxVerts * sizeof(CanvasVertex));
  NSUInteger vc = 0;

  if (isDots) {
    NSUInteger dotSegs = 16;
    for (NSUInteger i = 0; i < lineCount; i++) {
      simd_float2 a = lines[i].a;
      simd_float2 b = lines[i].b;
      // Convert to clip space.
      simd_float2 pa = {a.x - outputWidth / 2.0f,
                        (outputHeight - a.y) - outputHeight / 2.0f};
      simd_float2 pb = {b.x - outputWidth / 2.0f,
                        (outputHeight - b.y) - outputHeight / 2.0f};
      float dx = pb.x - pa.x;
      float dy = pb.y - pa.y;
      float len = sqrtf(dx * dx + dy * dy);
      if (len < 0.001f)
        continue;
      NSUInteger nDots = (NSUInteger)(len / dotSpacing) + 1;
      for (NSUInteger d = 0; d < nDots; d++) {
        float t = (nDots == 1) ? 0.5f : (float)d / (float)(nDots - 1);
        simd_float2 center = {pa.x + dx * t, pa.y + dy * t};
        // Emit triangle fan for a filled circle.
        for (NSUInteger s = 0; s < dotSegs; s++) {
          if (vc + 3 >= maxVerts) {
            maxVerts *= 2;
            vertices = realloc(vertices, maxVerts * sizeof(CanvasVertex));
          }
          float a1 = (float)s / (float)dotSegs * 2.0f * M_PI;
          float a2 = (float)(s + 1) / (float)dotSegs * 2.0f * M_PI;
          vertices[vc++] = (CanvasVertex){center, 1.0f, 0.0f};
          vertices[vc++] = (CanvasVertex){{center.x + cosf(a1) * dotRadius,
                                           center.y + sinf(a1) * dotRadius},
                                          1.0f,
                                          0.0f};
          vertices[vc++] = (CanvasVertex){{center.x + cosf(a2) * dotRadius,
                                           center.y + sinf(a2) * dotRadius},
                                          1.0f,
                                          0.0f};
        }
      }
    }
  } else {
    for (NSUInteger i = 0; i < lineCount; i++) {
      simd_float2 a = lines[i].a;
      simd_float2 b = lines[i].b;
      // Convert from pixel space to clip space (centered, Y-flipped).
      simd_float2 pa = {a.x - outputWidth / 2.0f,
                        (outputHeight - a.y) - outputHeight / 2.0f};
      simd_float2 pb = {b.x - outputWidth / 2.0f,
                        (outputHeight - b.y) - outputHeight / 2.0f};
      float dx = pb.x - pa.x;
      float dy = pb.y - pa.y;
      float len = sqrtf(dx * dx + dy * dy);
      if (len < 0.001f)
        continue;
      simd_float2 perp = {-dy / len * halfW, dx / len * halfW};

      if (vc > 0) {
        // Degenerate bridge.
        vertices[vc] = vertices[vc - 1];
        vc++;
        vertices[vc++] =
            (CanvasVertex){{pa.x + perp.x, pa.y + perp.y}, 1.0f, 0.0f};
      }
      vertices[vc++] =
          (CanvasVertex){{pa.x + perp.x, pa.y + perp.y}, 1.0f, 0.0f};
      vertices[vc++] =
          (CanvasVertex){{pa.x - perp.x, pa.y - perp.y}, 1.0f, 0.0f};
      vertices[vc++] =
          (CanvasVertex){{pb.x + perp.x, pb.y + perp.y}, 1.0f, 0.0f};
      vertices[vc++] =
          (CanvasVertex){{pb.x - perp.x, pb.y - perp.y}, 1.0f, 0.0f};
    }
  }

  free(lines);

  if (vc > 0) {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = outputTexture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (useStencilClip) {
      // Clip fill lines to the shape interior using the stencil written by
      // renderFillStencilOnly. Load (don't clear) so we keep the stencil data.
      rpd.stencilAttachment.texture = stencilTexture;
      rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
      rpd.stencilAttachment.storeAction = MTLStoreActionDontCare;
    }

    id<MTLRenderCommandEncoder> enc =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
    [enc setRenderPipelineState:strokePS];
    if (useStencilClip) {
      [enc setDepthStencilState:fillColorDSState];
      [enc setStencilReferenceValue:0];
    }

    id<MTLBuffer> vertexBuffer =
        [device newBufferWithBytes:vertices
                            length:vc * sizeof(CanvasVertex)
                           options:MTLResourceStorageModeShared];
    [enc setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
    [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
    MTLPrimitiveType prim =
        isDots ? MTLPrimitiveTypeTriangle : MTLPrimitiveTypeTriangleStrip;
    [enc drawPrimitives:prim vertexStart:0 vertexCount:vc];
    [enc endEncoding];
  }
  free(vertices);
}

@implementation CanvasPlugin (Render)

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  CanvasStrokeParams params;
  double width = 8.0;
  [paramGetAPI getFloatValue:&width
               fromParameter:kParamStrokeWidth
                      atTime:renderTime];
  params.strokeWidth = (float)width;

  double r = 1.0, g = 0.0, b = 0.0;
  [paramGetAPI getRedValue:&r
                greenValue:&g
                 blueValue:&b
             fromParameter:kParamStrokeColor
                    atTime:renderTime];
  params.r = (float)r;
  params.g = (float)g;
  params.b = (float)b;

  NSString *pathStr = nil;
  [paramGetAPI getStringParameterValue:&pathStr fromParameter:kParamPathData];

  NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
  if (pathStr.length > 0 && selIdx >= 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                       options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if ((NSUInteger)selIdx < paths.count && !paths[selIdx].isGroup) {
      KKParamsToPath(paramGetAPI, paths[selIdx]);
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      pathStr = [newBlob base64EncodedStringWithOptions:0];
    }
  }

  NSMutableData *state = [NSMutableData dataWithBytes:&params
                                               length:sizeof(params)];
  if (pathStr.length > 0)
    [state appendData:[pathStr dataUsingEncoding:NSUTF8StringEncoding]];
  *pluginState = state;
  return (*pluginState != nil);
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState || !destinationImage.ioSurface || sourceImages.count < 1) {
    if (outError != NULL)
      *outError =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_InvalidParameter
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Invalid plugin state received from host"
                          }];
    return NO;
  }

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLCommandQueue> commandQueue =
      [cache commandQueueWithRegistryID:registryID pixelFormat:pixelFormat];
  if (!commandQueue)
    return NO;

  @autoreleasepool {

    id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
    id<MTLTexture> outputTexture =
        [destinationImage metalTextureForDevice:device];
    id<MTLTexture> inputTexture =
        [sourceImages[0] metalTextureForDevice:device];

    float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                                destinationImage.tilePixelBounds.left);
    float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                                 destinationImage.tilePixelBounds.bottom);

    NSString *renderUUID = KKLayerUUIDForAPI(self.apiManager);
    if (renderUUID) {
      KKLayerInstanceState *renderState = KKLayerStateForUUID(renderUUID);
      renderState.canvasWidth = outputWidth;
      renderState.canvasHeight = outputHeight;
    }

    FxRect srcBounds = sourceImages[0].imagePixelBounds;
    FxMatrix44 *inv = sourceImages[0].inversePixelTransform;
    FxPoint2D ll = {srcBounds.left, srcBounds.bottom};
    FxPoint2D ur = {srcBounds.right, srcBounds.top};
    ll = [inv transform2DPoint:ll];
    ur = [inv transform2DPoint:ur];
    float pxW = srcBounds.right - srcBounds.left;
    float logicalW = ur.x - ll.x;
    float renderScale = (logicalW > 0) ? (pxW / logicalW) : 1.0f;

    CanvasStrokeParams strokeParams = {8.0f, 1.0f, 0.0f, 0.0f};
    NSArray<KKBezierPath *> *paths = @[];

    if (pluginState.length >= sizeof(CanvasStrokeParams)) {
      memcpy(&strokeParams, pluginState.bytes, sizeof(CanvasStrokeParams));
      if (pluginState.length > sizeof(CanvasStrokeParams)) {
        NSData *blobData = [pluginState
            subdataWithRange:NSMakeRange(sizeof(CanvasStrokeParams),
                                         pluginState.length -
                                             sizeof(CanvasStrokeParams))];
        NSString *blobStr =
            [[NSString alloc] initWithData:blobData
                                  encoding:NSUTF8StringEncoding];
        if (blobStr.length > 0) {
          NSData *decoded = [[NSData alloc] initWithBase64EncodedString:blobStr
                                                                options:0];
          if (decoded)
            paths = [KKBezierPath pathsFromBlob:decoded];
        }
      }
    }

    for (KKBezierPath *p in paths) {
      if (p.isRect && p.count >= 4) {
        simd_float2 pMin = {HUGE_VALF, HUGE_VALF};
        simd_float2 pMax = {-HUGE_VALF, -HUGE_VALF};
        for (NSUInteger i = 0; i < p.count; i++) {
          KKBezierPoint pt = [p pointAtIndex:i];
          pMin.x = fminf(pMin.x, pt.x);
          pMin.y = fminf(pMin.y, pt.y);
          pMax.x = fmaxf(pMax.x, pt.x);
          pMax.y = fmaxf(pMax.y, pt.y);
        }
        float rW = (pMax.x - pMin.x) * outputWidth;
        float rH = (pMax.y - pMin.y) * outputHeight;
        [p setRoundedRectWithMin:pMin
                             max:pMax
                      fractionTL:p.cornerRadiusTL
                      fractionTR:p.cornerRadiusTR
                      fractionBR:p.cornerRadiusBR
                      fractionBL:p.cornerRadiusBL
                     canvasWidth:rW
                    canvasHeight:rH];
      }
    }

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    commandBuffer.label = @"Canvas Command Buffer";
    [commandBuffer enqueue];

    {
      id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
      NSUInteger copyW = MIN(inputTexture.width, outputTexture.width);
      NSUInteger copyH = MIN(inputTexture.height, outputTexture.height);
      [blit copyFromTexture:inputTexture
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(copyW, copyH, 1)
                  toTexture:outputTexture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
      [blit endEncoding];
    }

    // Scale all pixel-space stroke properties by render quality so strokes
    // appear the same proportional size at any quality level.
    if (renderScale < 0.9999f) {
      for (KKBezierPath *p in paths) {
        p.strokeWidth *= renderScale;
        p.endWidth *= renderScale;
        p.dashLength *= renderScale;
        p.dashGap *= renderScale;
        p.dotGap *= renderScale;
        p.sketchFillGap *= renderScale;
        p.sketchFillWeight *= renderScale;
      }
    }

    // Keep original paths for sketch fill generation (hachure needs clean
    // geometry).
    NSMutableArray<KKBezierPath *> *origPathsMut =
        [NSMutableArray arrayWithCapacity:paths.count];
    NSMutableArray<KKBezierPath *> *renderPaths =
        [NSMutableArray arrayWithCapacity:paths.count];

    // Apply sketch jitter to paths that have it enabled.
    // When an open path has 2 strokes, split into two separate single-pass
    // paths so the tessellator doesn't draw a connecting line between the
    // merged passes.
    for (KKBezierPath *p in paths) {
      if (p.sketchEnabled && p.count >= 2 && !p.hidden) {
        BOOL needsSplit = !p.closed && p.sketchStrokes >= 2;
        if (needsSplit) {
          // Pass 1: primary stroke with markers.
          KKBezierPath *pass1 =
              KKSketchPath(p, p.sketchRoughness, p.sketchBowing, p.sketchSeed,
                           1, outputWidth, outputHeight);
          [renderPaths addObject:pass1];
          [origPathsMut addObject:p];
          // Pass 2: overlay stroke, different seed, no markers, no fill.
          KKBezierPath *pass2 = KKSketchPath(
              p, p.sketchRoughness, p.sketchBowing, p.sketchSeed ^ 0xFACE0042,
              1, outputWidth, outputHeight);
          pass2.fillEnabled = NO;
          pass2.startMarker = 0;
          pass2.endMarker = 0;
          [renderPaths addObject:pass2];
          [origPathsMut addObject:p];
        } else {
          [renderPaths
              addObject:KKSketchPath(p, p.sketchRoughness, p.sketchBowing,
                                     p.sketchSeed, p.sketchStrokes, outputWidth,
                                     outputHeight)];
          [origPathsMut addObject:p];
        }
      } else {
        [renderPaths addObject:p];
        [origPathsMut addObject:p];
      }
    }
    paths = renderPaths;
    NSArray<KKBezierPath *> *origPaths = origPathsMut;

    BOOL hasDrawablePaths = NO;
    for (KKBezierPath *p in paths) {
      if (p.count >= 2 && !p.hidden) {
        hasDrawablePaths = YES;
        break;
      }
    }
    if (!hasDrawablePaths) {
      [commandBuffer commit];
      [commandBuffer waitUntilCompleted];
      [cache returnCommandQueueToCache:commandQueue];
      return YES;
    }

    NSString *strokeKey =
        [NSString stringWithFormat:@"%@_stroke_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> strokePS =
        getOrCreatePipeline(strokeKey, registryID, pixelFormat, cache, device,
                            @"strokeVertexShader", @"strokeFragmentShader", YES,
                            MTLPixelFormatInvalid);
    if (!strokePS) {
      [cache returnCommandQueueToCache:commandQueue];
      return NO;
    }

    simd_uint2 viewportSize = {(unsigned int)outputWidth,
                               (unsigned int)outputHeight};

    MTLPixelFormat stencilFormat = MTLPixelFormatStencil8;

    NSString *fillStencilKey =
        [NSString stringWithFormat:@"%@_fillStencil_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> fillStencilPS = getOrCreatePipeline(
        fillStencilKey, registryID, pixelFormat, cache, device,
        @"fillVertexShader", @"fillFragmentShader", NO, stencilFormat);

    NSString *fillColorKey =
        [NSString stringWithFormat:@"%@_fillColor_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> fillColorPS = getOrCreatePipeline(
        fillColorKey, registryID, pixelFormat, cache, device,
        @"fillVertexShader", @"fillFragmentShader", YES, stencilFormat);

    // Stroke pipeline with stencil support for clipped sketch fills.
    NSString *strokeStencilKey =
        [NSString stringWithFormat:@"%@_strokeStencil_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> strokeStencilPS = getOrCreatePipeline(
        strokeStencilKey, registryID, pixelFormat, cache, device,
        @"strokeVertexShader", @"strokeFragmentShader", YES, stencilFormat);

    // Cache depth/stencil states — immutable, reusable across frames.
    static id<MTLDepthStencilState> sFillStencilDSState = nil;
    static id<MTLDepthStencilState> sFillColorDSState = nil;
    if (!sFillStencilDSState) {
      MTLStencilDescriptor *stencilInvertDesc =
          [[MTLStencilDescriptor alloc] init];
      stencilInvertDesc.stencilCompareFunction = MTLCompareFunctionAlways;
      stencilInvertDesc.depthStencilPassOperation = MTLStencilOperationInvert;
      MTLDepthStencilDescriptor *fillStencilDSDesc =
          [[MTLDepthStencilDescriptor alloc] init];
      fillStencilDSDesc.frontFaceStencil = stencilInvertDesc;
      fillStencilDSDesc.backFaceStencil = stencilInvertDesc;
      sFillStencilDSState =
          [device newDepthStencilStateWithDescriptor:fillStencilDSDesc];

      MTLStencilDescriptor *stencilTestDesc =
          [[MTLStencilDescriptor alloc] init];
      stencilTestDesc.stencilCompareFunction = MTLCompareFunctionNotEqual;
      stencilTestDesc.readMask = 0xFF;
      stencilTestDesc.stencilFailureOperation = MTLStencilOperationKeep;
      stencilTestDesc.depthStencilPassOperation = MTLStencilOperationZero;
      MTLDepthStencilDescriptor *fillColorDSDesc =
          [[MTLDepthStencilDescriptor alloc] init];
      fillColorDSDesc.frontFaceStencil = stencilTestDesc;
      fillColorDSDesc.backFaceStencil = stencilTestDesc;
      sFillColorDSState =
          [device newDepthStencilStateWithDescriptor:fillColorDSDesc];
    }
    id<MTLDepthStencilState> fillStencilDSState = sFillStencilDSState;
    id<MTLDepthStencilState> fillColorDSState = sFillColorDSState;

    // Cache stencil and intermediate textures — reuse when dimensions match.
    static id<MTLTexture> sCachedStencilTex = nil;
    static id<MTLTexture> sCachedIntermediateTex = nil;
    static NSUInteger sCachedTexW = 0, sCachedTexH = 0;
    static MTLPixelFormat sCachedIntPixFmt = MTLPixelFormatInvalid;
    NSUInteger texW = (NSUInteger)outputWidth;
    NSUInteger texH = (NSUInteger)outputHeight;

    if (sCachedTexW != texW || sCachedTexH != texH) {
      sCachedStencilTex = nil;
      sCachedIntermediateTex = nil;
      sCachedTexW = texW;
      sCachedTexH = texH;
      sCachedIntPixFmt = MTLPixelFormatInvalid;
    }

    id<MTLTexture> stencilTexture = nil;
    BOOL anyFill = NO;
    for (NSUInteger pi = 0; pi < paths.count; pi++) {
      if (paths[pi].fillEnabled && paths[pi].count >= 2 && !paths[pi].hidden) {
        anyFill = YES;
        break;
      }
    }
    if (anyFill && fillStencilPS && fillColorPS) {
      if (!sCachedStencilTex) {
        MTLTextureDescriptor *stencilTexDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:stencilFormat
                                         width:texW
                                        height:texH
                                     mipmapped:NO];
        stencilTexDesc.usage = MTLTextureUsageRenderTarget;
        stencilTexDesc.storageMode = MTLStorageModePrivate;
        sCachedStencilTex = [device newTextureWithDescriptor:stencilTexDesc];
      }
      stencilTexture = sCachedStencilTex;
    }

    // Composite pipeline: used to blit the intermediate texture onto the output
    // with per-object opacity applied once to the flattened fill+stroke.
    NSString *compositeKey =
        [NSString stringWithFormat:@"%@_composite_%lu", kPluginID,
                                   (unsigned long)pixelFormat];
    id<MTLRenderPipelineState> compositePS = getOrCreatePipeline(
        compositeKey, registryID, pixelFormat, cache, device,
        @"compositeVertexShader", @"compositeFragmentShader", YES,
        MTLPixelFormatInvalid);

    // Intermediate texture for per-object opacity compositing.
    id<MTLTexture> intermediateTexture = nil;
    if (compositePS) {
      if (!sCachedIntermediateTex || sCachedIntPixFmt != pixelFormat) {
        MTLTextureDescriptor *intDesc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
                                                               width:texW
                                                              height:texH
                                                           mipmapped:NO];
        intDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        intDesc.storageMode = MTLStorageModePrivate;
        sCachedIntermediateTex = [device newTextureWithDescriptor:intDesc];
        sCachedIntPixFmt = pixelFormat;
      }
      intermediateTexture = sCachedIntermediateTex;
    }

    for (NSUInteger pi = paths.count; pi > 0; pi--) {
      @autoreleasepool {
        KKBezierPath *path = paths[pi - 1];
        KKBezierPath *orig = origPaths[pi - 1];
        if (path.count < 2 || path.hidden)
          continue;

        float pathOpacity = path.opacity;
        BOOL needsIntermediate =
            intermediateTexture && compositePS && pathOpacity < 0.9999f;

        // When using intermediate compositing, render fill+stroke at full
        // opacity into a clear intermediate texture, then composite onto output
        // with the object's opacity.  This prevents overlapping primitives
        // (fill vs stroke, dashed segments, sketch fills) from showing through
        // each other.
        id<MTLTexture> target =
            needsIntermediate ? intermediateTexture : outputTexture;

        if (needsIntermediate) {
          // Temporarily force full opacity on the path objects so the render
          // helpers emit fully opaque colors.
          path.opacity = 1.0f;
          orig.opacity = 1.0f;

          // Clear the intermediate texture to transparent black.
          MTLRenderPassDescriptor *clearRPD =
              [MTLRenderPassDescriptor renderPassDescriptor];
          clearRPD.colorAttachments[0].texture = intermediateTexture;
          clearRPD.colorAttachments[0].loadAction = MTLLoadActionClear;
          clearRPD.colorAttachments[0].storeAction = MTLStoreActionStore;
          clearRPD.colorAttachments[0].clearColor =
              MTLClearColorMake(0, 0, 0, 0);
          id<MTLRenderCommandEncoder> clearEnc =
              [commandBuffer renderCommandEncoderWithDescriptor:clearRPD];
          [clearEnc endEncoding];
        }

        if (path.fillEnabled && orig.count >= 2 && fillStencilPS &&
            fillColorPS && stencilTexture) {
          // Always use the original (un-jittered) path for fill geometry.
          // buildFillFan handles multiple contours (compound paths) internally.
          if (path.sketchFillStyle > 0) {
            BOOL clipFill = !path.sketchEnabled;
            if (clipFill) {
              renderFillStencilOnly(orig, outputWidth, outputHeight, device,
                                    commandBuffer, target, stencilTexture,
                                    fillStencilPS, fillStencilDSState,
                                    viewportSize);
            }
            renderSketchFillForPath(orig, outputWidth, outputHeight, device,
                                    commandBuffer, target, stencilTexture,
                                    strokeStencilPS, fillColorDSState,
                                    viewportSize, clipFill);
          } else {
            KKBezierPath *fillPath = orig;
            if (orig.sketchEnabled && orig.sketchRoughness > 0.0001f) {
              fillPath =
                  KKSketchPath(orig, orig.sketchRoughness, orig.sketchBowing,
                               orig.sketchSeed, 1, outputWidth, outputHeight);
            }
            renderFillForPath(fillPath, outputWidth, outputHeight, device,
                              commandBuffer, target, stencilTexture,
                              fillStencilPS, fillColorPS, fillStencilDSState,
                              fillColorDSState, viewportSize);
          }
        }

        if (path.strokeEnabled) {
          renderStrokeForPath(path, outputWidth, outputHeight, device,
                              commandBuffer, target, strokePS, viewportSize);
        }

        if (needsIntermediate) {
          // Restore original opacity values.
          path.opacity = pathOpacity;
          orig.opacity = pathOpacity;

          // Composite the intermediate texture onto the output with opacity.
          MTLRenderPassDescriptor *compRPD =
              [MTLRenderPassDescriptor renderPassDescriptor];
          compRPD.colorAttachments[0].texture = outputTexture;
          compRPD.colorAttachments[0].loadAction = MTLLoadActionLoad;
          compRPD.colorAttachments[0].storeAction = MTLStoreActionStore;

          id<MTLRenderCommandEncoder> compEnc =
              [commandBuffer renderCommandEncoderWithDescriptor:compRPD];
          [compEnc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight,
                                             -1, 1}];
          [compEnc setRenderPipelineState:compositePS];
          [compEnc setFragmentTexture:intermediateTexture atIndex:0];
          [compEnc setFragmentBytes:&pathOpacity
                             length:sizeof(pathOpacity)
                            atIndex:0];
          [compEnc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                      vertexStart:0
                      vertexCount:4];
          [compEnc endEncoding];
        }
      } // per-path @autoreleasepool
    }

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

  } // @autoreleasepool

  [cache returnCommandQueueToCache:commandQueue];
  return YES;
}

@end
