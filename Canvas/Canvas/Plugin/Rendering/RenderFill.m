/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "RenderFill.h"
#import "SketchFill.h"
#import "SketchPath.h"

NSUInteger KKBuildFillFan(KKBezierPath *path, float outputWidth,
                          float outputHeight, CanvasFillVertex **outVerts) {
  NSUInteger segsPerCurve = 64;
  NSUInteger nc = path.contourCount;

  // First pass: compute total outline capacity.
  NSUInteger totalMax = 0;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
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
    // Remove near-duplicate endpoint.
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

void KKRenderFillForPath(KKBezierPath *path, float outputWidth,
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
      KKBuildFillFan(path, outputWidth, outputHeight, &fillVerts);

  id<MTLBuffer> fillBuf =
      [device newBufferWithBytes:fillVerts
                          length:triCount * 3 * sizeof(CanvasFillVertex)
                         options:MTLResourceStorageModeShared];
  free(fillVerts);

  // Stencil pass.
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

  // Color pass.
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

void KKRenderFillStencilOnly(KKBezierPath *path, float outputWidth,
                             float outputHeight, id<MTLDevice> device,
                             id<MTLCommandBuffer> commandBuffer,
                             id<MTLTexture> outputTexture,
                             id<MTLTexture> stencilTexture,
                             id<MTLRenderPipelineState> fillStencilPS,
                             id<MTLDepthStencilState> fillStencilDSState,
                             simd_uint2 viewportSize) {
  CanvasFillVertex *fillVerts = NULL;
  NSUInteger triCount =
      KKBuildFillFan(path, outputWidth, outputHeight, &fillVerts);

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

void KKRenderSketchFillForPath(KKBezierPath *origPath, float outputWidth,
                               float outputHeight, id<MTLDevice> device,
                               id<MTLCommandBuffer> commandBuffer,
                               id<MTLTexture> outputTexture,
                               id<MTLTexture> stencilTexture,
                               id<MTLRenderPipelineState> strokePS,
                               id<MTLDepthStencilState> fillColorDSState,
                               simd_uint2 viewportSize, BOOL useStencilClip) {
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

  BOOL isDots = (fillStyle == 4);
  float dotRadius = fw * 1.5f;
  float dotSpacing = origPath.sketchFillGap;
  if (dotSpacing < dotRadius * 2.0f)
    dotSpacing = dotRadius * 2.0f;

  NSUInteger maxVerts;
  if (isDots) {
    NSUInteger dotsPerLine = 50;
    maxVerts = lineCount * dotsPerLine * 60 + 256;
  } else {
    maxVerts = lineCount * 6 + 256;
  }
  CanvasVertex *vertices = malloc(maxVerts * sizeof(CanvasVertex));
  NSUInteger vc = 0;

  if (isDots) {
    NSUInteger dotSegs = 16;
    for (NSUInteger i = 0; i < lineCount; i++) {
      simd_float2 a = lines[i].a;
      simd_float2 b = lines[i].b;
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
