/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RenderStroke.h"
#import "CanvasGradientBuilder.h"
#import "MarkerTessellation.h"
#import "ShaderTypes.h"
#import "Tessellation.h"

static void buildStrokeGradientParams(KKBezierPath *path, float outputWidth,
                                      float outputHeight,
                                      CanvasGradientParams *out) {
  CanvasGradientParams p = {0};
  float oa = path.opacity;
  p.solidColor = (simd_float4){path.strokeR * oa, path.strokeG * oa,
                               path.strokeB * oa, oa};
  p.opacity = oa;
  if (!KKBuildCanvasGradientSamples(path, YES, &p)) {
    *out = p;
    return;
  }
  float pad = fmaxf(path.strokeWidth, path.endWidth) * 0.5f;
  KKCanvasPathBBoxCenteredPx(path, outputWidth, outputHeight, pad, &p.bboxMin,
                             &p.bboxMax);
  *out = p;
}

static void
renderMarker(uint8_t marker, simd_float2 pos, simd_float2 tangent,
             simd_float2 normal, float markerSize, float strokeW,
             KKBezierPath *path, CanvasPathTransform pathXform,
             float outputWidth, float outputHeight, id<MTLDevice> device,
             id<MTLCommandBuffer> commandBuffer, id<MTLTexture> outputTexture,
             id<MTLRenderPipelineState> strokePS, simd_uint2 viewportSize,
             CanvasGradientParams *gradParams) {
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
  [enc setViewport:(MTLViewport){0, 0, (double)viewportSize.x, (double)viewportSize.y, -1, 1}];
  [enc setRenderPipelineState:strokePS];
  id<MTLBuffer> buf = [device newBufferWithBytes:markerVerts
                                          length:mc * sizeof(CanvasVertex)
                                         options:MTLResourceStorageModeShared];
  [enc setVertexBuffer:buf offset:0 atIndex:0];
  [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
  [enc setVertexBytes:&pathXform length:sizeof(pathXform) atIndex:2];
  [enc setFragmentBytes:gradParams length:sizeof(*gradParams) atIndex:0];
  [enc setFragmentBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
  [enc setFragmentBytes:&pathXform length:sizeof(pathXform) atIndex:2];
  [enc drawPrimitives:markerPrim vertexStart:0 vertexCount:mc];
  [enc endEncoding];
}

static void renderStrokeForSinglePath(
    KKBezierPath *path, CanvasPathTransform pathXform, float outputWidth,
    float outputHeight, id<MTLDevice> device,
    id<MTLCommandBuffer> commandBuffer, id<MTLTexture> outputTexture,
    id<MTLRenderPipelineState> strokePS, simd_uint2 viewportSize) {
  float sw = path.strokeWidth;
  float ew = (path.endWidth > 0) ? path.endWidth : sw;

  CanvasGradientParams gradParams;
  buildStrokeGradientParams(path, outputWidth, outputHeight, &gradParams);

  // Compute total arc length up front so draw-on fractions can be converted
  // to absolute trim offsets and combined with marker pullback.
  float totalArc = 0.0f;
  if (path.count >= 2) {
    PathSample *arcSamples = NULL;
    NSUInteger arcCount =
        KKSamplePathPolyline(path, outputWidth, outputHeight, &arcSamples);
    if (arcCount >= 2)
      totalArc = arcSamples[arcCount - 1].arcLength;
    free(arcSamples);
  }
  float drawOnStart = fmaxf(0.0f, fminf(1.0f, path.drawOnStart));
  float drawOnEnd = fmaxf(0.0f, fminf(1.0f, path.drawOnEnd));
  float drawOnStartArc = drawOnStart * totalArc;
  float drawOnEndArc = (1.0f - drawOnEnd) * totalArc;
  BOOL drawOnTrimsStart = drawOnStart > 0.0f;
  BOOL drawOnTrimsEnd = drawOnEnd < 1.0f;
  BOOL drawOnTrims = drawOnTrimsStart || drawOnTrimsEnd;

  // Marker animation: as draw-on approaches an endpoint, the marker grows in
  // place over a window equal to its own arc footprint. Below the window the
  // marker is fully suppressed; inside it the size and the trim pullback both
  // scale by `progress`, which keeps the small marker hugging the stroke tip.
  float startMarkerSzFull = sw * path.startMarkerSize;
  float endMarkerSzFull = ew * path.endMarkerSize;
  float startPullbackFull =
      path.startMarker != 0
          ? KKMarkerPullback(path.startMarker, startMarkerSzFull)
          : 0.0f;
  float endPullbackFull =
      path.endMarker != 0 ? KKMarkerPullback(path.endMarker, endMarkerSzFull)
                          : 0.0f;
  if (path.startMarker != 0 && startPullbackFull <= 0.0f)
    startPullbackFull = 0.001f;
  if (path.endMarker != 0 && endPullbackFull <= 0.0f)
    endPullbackFull = 0.001f;

  // Markers with no natural pullback (circle/square/arrowhead/line) still need
  // an animation window. Use the marker's physical size as a uniform fallback;
  // for arrows the size is already comparable to the pullback.
  float startWindow = fmaxf(startPullbackFull, startMarkerSzFull);
  float endWindow = fmaxf(endPullbackFull, endMarkerSzFull);
  float startProgress =
      (path.startMarker != 0 && startWindow > 0.0f)
          ? fmaxf(0.0f, fminf(1.0f, 1.0f - drawOnStartArc / startWindow))
          : 0.0f;
  float endProgress =
      (path.endMarker != 0 && endWindow > 0.0f)
          ? fmaxf(0.0f, fminf(1.0f, 1.0f - drawOnEndArc / endWindow))
          : 0.0f;
  // When the opposite side's draw-on eats into the visible range, the marker
  // also has no stroke to attach to. Fade by the remaining stroke length so a
  // collapsed range hides both markers symmetrically.
  float visibleStrokeLen =
      fmaxf(0.0f, totalArc - drawOnStartArc - drawOnEndArc);
  if (startWindow > 0.0f)
    startProgress *= fminf(1.0f, visibleStrokeLen / startWindow);
  if (endWindow > 0.0f)
    endProgress *= fminf(1.0f, visibleStrokeLen / endWindow);
  if (path.closed) {
    startProgress = 0.0f;
    endProgress = 0.0f;
  }

  uint8_t startMarker = startProgress > 0.0f ? path.startMarker : 0;
  uint8_t endMarker = endProgress > 0.0f ? path.endMarker : 0;
  BOOL hasMarkers = !path.closed && (startMarker != 0 || endMarker != 0);
  float startMarkerSz = startMarkerSzFull * startProgress;
  float endMarkerSz = endMarkerSzFull * endProgress;
  float startPullback = startPullbackFull * startProgress;
  float endPullback = endPullbackFull * endProgress;

  // Origin shift: rotate where arc-length=0 lives on the path. The visible
  // region is [origin + drawOnStartArc, origin + (totalArc - drawOnEndArc)]
  // in absolute arc terms; if it crosses totalArc we render in two passes.
  // Origin shift suppresses markers (they'd float at the original endpoints,
  // which are now mid-stroke).
  float origin = fmaxf(0.0f, fminf(1.0f, path.drawOnOrigin));
  BOOL hasOrigin = origin > 0.0f && totalArc > 0.0f;
  if (hasOrigin) {
    startMarker = 0;
    endMarker = 0;
    hasMarkers = NO;
    startMarkerSz = 0;
    endMarkerSz = 0;
    startPullback = 0;
    endPullback = 0;
  }

  float startTrim = fmaxf(startPullback, drawOnStartArc);
  float endTrim = fmaxf(endPullback, drawOnEndArc);

  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;

  // Marching-ants phase: path.marchingAntsOffset is a fraction of the dash
  // cycle (already includes the time-driven advance baked in at sample time).
  // Convert to arc-length here since cycle is per-style.
  float dashCycle = path.dashLength + path.dashGap;
  float dotCycle = sw + path.dotGap;
  float dashedPhase = path.marchingAntsOffset * dashCycle;
  float dottedPhase = path.marchingAntsOffset * dotCycle;

  // Helper: tessellate + draw one stroke "range" (single startTrim/endTrim
  // pair). Called once for the no-origin case, twice for the wrap case.
  // `wrapSeam` says whether this strip is one half of an origin-shifted wrap
  // pair (the seam at totalArc/0 continues into a partner strip). Standalone
  // trims pass NO so the tessellator doesn't emit corner geometry past the
  // visible end.
  void (^emitRange)(float, float, BOOL) = ^(float st, float et, BOOL wrapSeam) {
    CanvasVertex *vertices = NULL;
    NSUInteger vertexCount = 0;
    if (path.strokeStyle == 1) {
      NSUInteger dashedSegs = 512;
      NSUInteger maxVertices = curveCount * dashedSegs * 12 + 8192;
      vertices = malloc(maxVertices * sizeof(CanvasVertex));
      vertexCount = KKTessellateDashedPath(
          path, sw, ew, outputWidth, outputHeight, path.dashLength,
          path.dashGap, path.lineJoin, st, et, dashedPhase, vertices);
    } else if (path.strokeStyle == 2) {
      NSUInteger maxVertices = curveCount * segsPerCurve * 4 + 4096;
      vertices = malloc(maxVertices * sizeof(CanvasVertex));
      vertexCount =
          KKTessellateDottedPath(path, sw, ew, outputWidth, outputHeight,
                                 path.dotGap, st, et, dottedPhase, vertices);
    } else if (hasMarkers || drawOnTrims || hasOrigin) {
      NSUInteger joinExtra = (path.lineJoin != 0) ? curveCount * 48 : 0;
      NSUInteger maxVertices =
          curveCount * ((segsPerCurve + 1) * 2 + 2) + 256 + joinExtra;
      vertices = malloc(maxVertices * sizeof(CanvasVertex));
      vertexCount = KKTessellateTrimmedPath(
          path, sw, ew, outputWidth, outputHeight, path.lineCap, path.lineJoin,
          st, et, wrapSeam, vertices);
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
      [enc setViewport:(MTLViewport){0, 0, (double)viewportSize.x, (double)viewportSize.y, -1, 1}];
      [enc setRenderPipelineState:strokePS];

      id<MTLBuffer> vertexBuffer =
          [device newBufferWithBytes:vertices
                              length:vertexCount * sizeof(CanvasVertex)
                             options:MTLResourceStorageModeShared];
      [enc setVertexBuffer:vertexBuffer offset:0 atIndex:0];
      [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
      [enc setVertexBytes:&pathXform length:sizeof(pathXform) atIndex:2];
      [enc setFragmentBytes:&gradParams length:sizeof(gradParams) atIndex:0];
      [enc setFragmentBytes:&viewportSize
                     length:sizeof(viewportSize)
                    atIndex:1];
      [enc setFragmentBytes:&pathXform length:sizeof(pathXform) atIndex:2];
      [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:vertexCount];
      [enc endEncoding];
    }
    free(vertices);
  };

  if (!hasOrigin) {
    emitRange(startTrim, endTrim, NO);
  } else {
    float originArc = origin * totalArc;
    float visStart = fmodf(originArc + drawOnStartArc, totalArc);
    float visLen = totalArc - drawOnStartArc - drawOnEndArc;
    if (visLen <= 0) {
      // Empty visible region — nothing to draw.
    } else if (visStart + visLen <= totalArc) {
      // Single contiguous range — no seam crossed.
      emitRange(visStart, totalArc - (visStart + visLen), NO);
    } else {
      // Wraps past totalArc — emit two ranges sharing the same dash phase.
      // Both halves flag wrapSeam=YES so the tessellator emits the corner
      // join at the meeting point.
      emitRange(visStart, 0.0f, YES);
      float remainder = (visStart + visLen) - totalArc;
      emitRange(0.0f, totalArc - remainder, YES);
    }
  }

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
                     pathXform, outputWidth, outputHeight, device,
                     commandBuffer, outputTexture, strokePS, viewportSize,
                     &gradParams);
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
                     path, pathXform, outputWidth, outputHeight, device,
                     commandBuffer, outputTexture, strokePS, viewportSize,
                     &gradParams);
      }
    }
    free(samples);
  }
}

void KKRenderStrokeForPath(KKBezierPath *path, CanvasPathTransform pathXform,
                           float outputWidth, float outputHeight,
                           id<MTLDevice> device,
                           id<MTLCommandBuffer> commandBuffer,
                           id<MTLTexture> outputTexture,
                           id<MTLRenderPipelineState> strokePS,
                           simd_uint2 viewportSize) {
  NSArray<KKBezierPath *> *contours = [path splitContours];
  if (contours) {
    for (KKBezierPath *sub in contours)
      renderStrokeForSinglePath(sub, pathXform, outputWidth, outputHeight,
                                device, commandBuffer, outputTexture, strokePS,
                                viewportSize);
    return;
  }
  renderStrokeForSinglePath(path, pathXform, outputWidth, outputHeight, device,
                            commandBuffer, outputTexture, strokePS,
                            viewportSize);
}
