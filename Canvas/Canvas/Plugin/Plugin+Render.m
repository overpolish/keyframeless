/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

static const float kMiterLimit = 4.0f;

static simd_float2 miterNormal(simd_float2 n1, simd_float2 n2) {
  simd_float2 avg = n1 + n2;
  float avgLen = simd_length(avg);
  if (avgLen < 1e-6f)
    return n1;
  avg /= avgLen;
  float d = simd_dot(avg, n1);
  if (d < 1e-6f)
    return n1;
  float extension = 1.0f / d;
  if (extension > kMiterLimit)
    extension = kMiterLimit;
  return avg * extension;
}

/// Compute the raw normal at a tessellation point. No join logic — each
/// segment gets its own perpendicular offset. Joins are handled in the
/// tessellator.
static simd_float2 normalAtPoint(KKBezierPath *path, NSUInteger c,
                                 NSUInteger segsPerCurve, NSUInteger i,
                                 float outputWidth, float outputHeight) {
  NSUInteger nextIdx = (c + 1) % path.count;
  float t = (float)i / (float)segsPerCurve;
  simd_float2 tangent = [path evaluateTangentAtIndex:c nextIndex:nextIdx atT:t];
  tangent.x *= outputWidth;
  tangent.y *= -outputHeight;
  float len = simd_length(tangent);
  if (len < 1e-2f) {
    float step = 1.0f / (float)segsPerCurve;
    float probeT = (t < 0.5f) ? t + step : t - step;
    probeT = fmaxf(0.0f, fminf(1.0f, probeT));
    simd_float2 probe = [path evaluateTangentAtIndex:c
                                           nextIndex:nextIdx
                                                 atT:probeT];
    probe.x *= outputWidth;
    probe.y *= -outputHeight;
    float probeLen = simd_length(probe);
    if (probeLen > len) {
      tangent = probe;
      len = probeLen;
    }
    if (len < 1e-6f) {
      simd_float2 p0 = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:0.0f];
      simd_float2 p1 = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:1.0f];
      tangent = (simd_float2){(p1.x - p0.x) * outputWidth,
                              (p0.y - p1.y) * outputHeight};
      len = simd_length(tangent);
    }
  }
  if (len < 1e-6f)
    tangent = (simd_float2){1.0f, 0.0f};
  else
    tangent /= len;
  return (simd_float2){-tangent.y, tangent.x};
}

static NSUInteger addRoundCap(CanvasVertex *vertices, NSUInteger vertexCount,
                              simd_float2 center, simd_float2 tangent,
                              simd_float2 normal, float halfWidth,
                              BOOL isStart) {
  NSUInteger capSegs = 16;
  simd_float2 capDir = isStart ? -tangent : tangent;

  // Degenerate bridge from the stroke body.
  if (vertexCount > 0) {
    vertices[vertexCount] = vertices[vertexCount - 1];
    vertexCount++;
  }

  for (NSUInteger i = 0; i <= capSegs; i++) {
    float angle = (float)i / (float)capSegs * M_PI;
    float cosA = cosf(angle);
    float sinA = sinf(angle);
    simd_float2 dir = normal * cosA + capDir * sinA;

    simd_float2 outer = center + dir * halfWidth;
    vertices[vertexCount].position = outer;
    vertices[vertexCount].edgeDistance = 0.0f;
    // Outer ring at capDistance=1 so the shader AA-trims it to match the
    // stroke body visual width.
    vertices[vertexCount].capDistance = 1.0f;
    vertexCount++;

    vertices[vertexCount].position = center;
    vertices[vertexCount].edgeDistance = 0.0f;
    vertices[vertexCount].capDistance = 0.0f;
    vertexCount++;

    // Degenerate bridge after first vertex pair.
    if (i == 0 && vertexCount >= 4) {
      vertices[vertexCount] = vertices[vertexCount - 2];
      vertexCount++;
      vertices[vertexCount] = vertices[vertexCount - 2];
      vertexCount++;
    }
  }
  return vertexCount;
}

/// Compute the raw (non-mitered) normal at the start of a curve segment.
static simd_float2 rawNormalAtSegStart(KKBezierPath *path, NSUInteger c,
                                       float outputWidth, float outputHeight) {
  NSUInteger nextIdx = (c + 1) % path.count;
  simd_float2 tangent = [path evaluateTangentAtIndex:c
                                           nextIndex:nextIdx
                                                 atT:0.0f];
  tangent.x *= outputWidth;
  tangent.y *= -outputHeight;
  float len = simd_length(tangent);
  if (len < 1e-6f) {
    simd_float2 a = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:0.0f];
    simd_float2 b = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:1.0f];
    tangent =
        (simd_float2){(b.x - a.x) * outputWidth, (a.y - b.y) * outputHeight};
    len = simd_length(tangent);
  }
  if (len < 1e-6f)
    return (simd_float2){-1.0f, 0.0f};
  tangent /= len;
  return (simd_float2){-tangent.y, tangent.x};
}

static NSUInteger tessellatePath(KKBezierPath *path, float strokeWidth,
                                 float outputWidth, float outputHeight,
                                 uint8_t lineCap, uint8_t lineJoin,
                                 CanvasVertex *vertices) {
  float aaPadding = 1.0f;
  float halfWidth = (strokeWidth / 2.0f) + aaPadding;
  NSUInteger segsPerCurve = 128;
  NSUInteger curveCount = path.count - 1;
  if (path.closed && path.count >= 2)
    curveCount = path.count;
  NSUInteger vertexCount = 0;
  BOOL isOpen = !path.closed;

  // Square cap: extend endpoints outward by halfWidth along the tangent.
  // We track the first/last centered positions and tangents.
  simd_float2 startCenter = {0, 0}, endCenter = {0, 0};
  simd_float2 startTangent = {0, 0}, endTangent = {0, 0};
  simd_float2 startNormal = {0, 0}, endNormal = {0, 0};

  for (NSUInteger c = 0; c < curveCount; c++) {
    // Tessellate this segment with raw normals (no join logic).
    simd_float2 segEndCenter = {0, 0}, segEndNormal = {0, 0};
    simd_float2 segStartCenter = {0, 0}, segStartNormal = {0, 0};

    for (NSUInteger i = 0; i <= segsPerCurve; i++) {
      float t = (float)i / (float)segsPerCurve;
      NSUInteger nextIdx = (c + 1) % path.count;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      simd_float2 normal =
          normalAtPoint(path, c, segsPerCurve, i, outputWidth, outputHeight);

      simd_float2 pixelPos = {pos.x * outputWidth,
                              (1.0f - pos.y) * outputHeight};
      simd_float2 centered = {pixelPos.x - outputWidth / 2.0f,
                              pixelPos.y - outputHeight / 2.0f};

      if (i == 0) {
        segStartCenter = centered;
        segStartNormal = normal;
      }
      if (i == segsPerCurve) {
        segEndCenter = centered;
        segEndNormal = normal;
      }

      BOOL isFirstPoint = (c == 0 && i == 0);
      BOOL isLastPoint = (c == curveCount - 1 && i == segsPerCurve);
      if (isFirstPoint) {
        startCenter = centered;
        startNormal = normal;
        startTangent = (simd_float2){normal.y, -normal.x};
      }
      if (isLastPoint) {
        endCenter = centered;
        endNormal = normal;
        endTangent = (simd_float2){normal.y, -normal.x};
      }

      // For miter joins, override the boundary normals with the miter.
      if (lineJoin == 0) {
        if (i == segsPerCurve &&
            (c < curveCount - 1 || (path.closed && c == curveCount - 1))) {
          NSUInteger nextC = (c < curveCount - 1) ? (c + 1) % path.count : 0;
          simd_float2 nextN =
              rawNormalAtSegStart(path, nextC, outputWidth, outputHeight);
          normal = miterNormal(normal, nextN);
          // Update end tracking for caps.
          if (isLastPoint) {
            endNormal = normal;
            endTangent = (simd_float2){normal.y, -normal.x};
          }
        } else if (i == 0 && (c > 0 || (path.closed && c == 0))) {
          NSUInteger prevC = (c > 0) ? c - 1 : curveCount - 1;
          simd_float2 prevN =
              normalAtPoint(path, prevC, segsPerCurve, segsPerCurve,
                            outputWidth, outputHeight);
          normal = miterNormal(prevN, normal);
          if (isFirstPoint) {
            startNormal = normal;
            startTangent = (simd_float2){normal.y, -normal.x};
          }
        }
      }

      // Skip the first point of non-first segments for bevel/round —
      // the join geometry handles the transition.
      if (i == 0 && c > 0 && lineJoin != 0)
        continue;

      // Degenerate bridge between segments for miter.
      if (i == 0 && c > 0 && lineJoin == 0 && vertexCount > 0) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
      }

      vertices[vertexCount].position = centered + normal * halfWidth;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = centered - normal * halfWidth;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
    }

    // Emit join geometry at curve boundaries for bevel/round.
    BOOL atJoin = (c < curveCount - 1) || (path.closed && c == curveCount - 1);
    if (atJoin && lineJoin != 0) {
      simd_float2 n1 = segEndNormal; // outgoing normal of this segment
      NSUInteger nextC = (c + 1) % curveCount;
      if (path.closed && c == curveCount - 1)
        nextC = 0;
      simd_float2 n2 =
          rawNormalAtSegStart(path, nextC, outputWidth, outputHeight);

      // Determine which side is outside of the bend.
      float cross = n1.x * n2.y - n1.y * n2.x;
      float side = (cross >= 0.0f) ? -1.0f : 1.0f;

      simd_float2 jCenter = segEndCenter;
      simd_float2 outerEnd = jCenter + n1 * halfWidth * side;
      simd_float2 outerStart = jCenter + n2 * halfWidth * side;

      // End the current strip at the junction with raw normal.
      // (already done by the loop above)

      // Degenerate bridge from strip to join geometry.
      if (vertexCount > 0) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
      }

      if (lineJoin == 1) {
        // Round join: fan from outerEnd to outerStart through center.
        float dot = simd_dot(n1 * side, n2 * side);
        dot = fmaxf(-1.0f, fminf(1.0f, dot));
        float angle = acosf(dot);

        if (angle > 1e-4f) {
          simd_float2 on1 = n1 * side;
          float sweepCross = on1.x * (n2.x * side) - on1.y * (n2.y * side);
          // Actually recompute properly
          simd_float2 on2 = n2 * side;
          sweepCross = on1.x * on2.y - on1.y * on2.x;
          float dir = (sweepCross >= 0.0f) ? 1.0f : -1.0f;

          NSUInteger segs = (NSUInteger)fmaxf(4.0f, angle / (M_PI / 16.0f));

          CanvasVertex first;
          first.position = jCenter + on1 * halfWidth;
          first.edgeDistance = 0.0f;
          first.capDistance = 0.0f;
          vertices[vertexCount] = first;
          vertexCount++;
          vertices[vertexCount] = first;
          vertexCount++;

          for (NSUInteger s = 0; s <= segs; s++) {
            float st = (float)s / (float)segs;
            float a = st * angle * dir;
            float cosA = cosf(a);
            float sinA = sinf(a);
            simd_float2 rotated = {on1.x * cosA - on1.y * sinA,
                                   on1.x * sinA + on1.y * cosA};
            vertices[vertexCount].position = jCenter + rotated * halfWidth;
            vertices[vertexCount].edgeDistance = 0.0f;
            vertices[vertexCount].capDistance = 1.0f;
            vertexCount++;
            vertices[vertexCount].position = jCenter;
            vertices[vertexCount].edgeDistance = 0.0f;
            vertices[vertexCount].capDistance = 0.0f;
            vertexCount++;
          }
        }
      } else {
        // Bevel join: single triangle on the outside.
        CanvasVertex first;
        first.position = outerEnd;
        first.edgeDistance = 0.0f;
        first.capDistance = 0.0f;
        vertices[vertexCount] = first;
        vertexCount++;
        vertices[vertexCount] = first;
        vertexCount++;

        vertices[vertexCount].position = outerEnd;
        vertices[vertexCount].edgeDistance = 0.0f;
        vertices[vertexCount].capDistance = 1.0f;
        vertexCount++;
        vertices[vertexCount].position = jCenter;
        vertices[vertexCount].edgeDistance = 0.0f;
        vertices[vertexCount].capDistance = 0.0f;
        vertexCount++;
        vertices[vertexCount].position = outerStart;
        vertices[vertexCount].edgeDistance = 0.0f;
        vertices[vertexCount].capDistance = 1.0f;
        vertexCount++;
      }

      // Bridge from join to next segment: emit the next segment's first
      // point with its own normal to start the new strip cleanly.
      if (c < curveCount - 1) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;

        // Emit junction point with next segment's normal.
        vertices[vertexCount].position = jCenter + n2 * halfWidth;
        vertices[vertexCount].edgeDistance = 1.0f;
        vertices[vertexCount].capDistance = 0.0f;
        vertexCount++;
        vertices[vertexCount].position = jCenter - n2 * halfWidth;
        vertices[vertexCount].edgeDistance = -1.0f;
        vertices[vertexCount].capDistance = 0.0f;
        vertexCount++;
      }
    } else if (c < curveCount - 1 && lineJoin == 0) {
      // Miter: strip is already continuous, just bridge.
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
    }
  }

  // Caps for open paths.
  if (isOpen && lineCap != 0 && curveCount > 0) {
    if (lineCap == 1) {
      // Round caps.
      vertexCount = addRoundCap(vertices, vertexCount, endCenter, endTangent,
                                endNormal, halfWidth, NO);
      if (vertexCount > 0) {
        vertices[vertexCount] = vertices[vertexCount - 1];
        vertexCount++;
      }
      CanvasVertex startFirst;
      startFirst.position = startCenter + startNormal * halfWidth;
      startFirst.edgeDistance = 0.0f;
      startFirst.capDistance = 0.0f;
      vertices[vertexCount] = startFirst;
      vertexCount++;
      vertices[vertexCount] = startFirst;
      vertexCount++;
      vertexCount = addRoundCap(vertices, vertexCount, startCenter,
                                startTangent, startNormal, halfWidth, YES);
    } else if (lineCap == 2) {
      // Square caps: extend a rectangle of strokeWidth/2 beyond each endpoint.
      float ext = strokeWidth / 2.0f;

      // End cap.
      simd_float2 eTop = endCenter + endNormal * halfWidth;
      simd_float2 eBot = endCenter - endNormal * halfWidth;
      simd_float2 eTopExt = eTop + endTangent * ext;
      simd_float2 eBotExt = eBot + endTangent * ext;

      // Degenerate bridge from stroke body.
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
      vertices[vertexCount].position = eTop;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
      // Rectangle quad as triangle strip: eTop, eBot, eTopExt, eBotExt.
      vertices[vertexCount].position = eTop;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = eBot;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = eTopExt;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = eBotExt;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;

      // Start cap (extends in -tangent direction).
      simd_float2 sTop = startCenter + startNormal * halfWidth;
      simd_float2 sBot = startCenter - startNormal * halfWidth;
      simd_float2 sTopExt = sTop - startTangent * ext;
      simd_float2 sBotExt = sBot - startTangent * ext;

      // Degenerate bridge.
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
      vertices[vertexCount].position = sTopExt;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount] = vertices[vertexCount - 1];
      vertexCount++;
      // Rectangle quad.
      vertices[vertexCount].position = sTopExt;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = sBotExt;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = sTop;
      vertices[vertexCount].edgeDistance = 1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
      vertices[vertexCount].position = sBot;
      vertices[vertexCount].edgeDistance = -1.0f;
      vertices[vertexCount].capDistance = 0.0f;
      vertexCount++;
    }
  }

  return vertexCount;
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

  // Patch selected path from current param values so the render reflects
  // inspector edits immediately (before pathData is persisted).
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

  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
  id<MTLTexture> outputTexture =
      [destinationImage metalTextureForDevice:device];
  id<MTLTexture> inputTexture = [sourceImages[0] metalTextureForDevice:device];

  float outputWidth = (float)(destinationImage.tilePixelBounds.right -
                              destinationImage.tilePixelBounds.left);
  float outputHeight = (float)(destinationImage.tilePixelBounds.top -
                               destinationImage.tilePixelBounds.bottom);

  CanvasStrokeParams strokeParams = {8.0f, 1.0f, 0.0f, 0.0f};
  NSArray<KKBezierPath *> *paths = @[];

  if (pluginState.length >= sizeof(CanvasStrokeParams)) {
    memcpy(&strokeParams, pluginState.bytes, sizeof(CanvasStrokeParams));
    if (pluginState.length > sizeof(CanvasStrokeParams)) {
      NSData *blobData = [pluginState
          subdataWithRange:NSMakeRange(sizeof(CanvasStrokeParams),
                                       pluginState.length -
                                           sizeof(CanvasStrokeParams))];
      NSString *blobStr = [[NSString alloc] initWithData:blobData
                                                encoding:NSUTF8StringEncoding];
      if (blobStr.length > 0) {
        NSData *decoded = [[NSData alloc] initWithBase64EncodedString:blobStr
                                                              options:0];
        if (decoded)
          paths = [KKBezierPath pathsFromBlob:decoded];
      }
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

  NSString *strokeKey = [NSString
      stringWithFormat:@"%@_stroke_%lu", kPluginID, (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> strokePS =
      [cache pipelineStateForPluginID:strokeKey
                           registryID:registryID
                          pixelFormat:pixelFormat];
  if (!strokePS) {
    id<MTLLibrary> library = [device newDefaultLibrary];
    MTLRenderPipelineDescriptor *desc =
        [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [library newFunctionWithName:@"strokeVertexShader"];
    desc.fragmentFunction =
        [library newFunctionWithName:@"strokeFragmentShader"];
    desc.colorAttachments[0].pixelFormat = pixelFormat;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;

    NSError *error = nil;
    strokePS = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!strokePS) {
      [cache returnCommandQueueToCache:commandQueue];
      return NO;
    }
    [cache registerPipelineState:strokePS
                     forPluginID:strokeKey
                      registryID:registryID
                     pixelFormat:pixelFormat];
  }

  simd_uint2 viewportSize = {(unsigned int)outputWidth,
                             (unsigned int)outputHeight};

  // Build fill pipeline states on demand (stencil + color passes).
  MTLPixelFormat stencilFormat = MTLPixelFormatStencil8;

  NSString *fillStencilKey =
      [NSString stringWithFormat:@"%@_fillStencil_%lu", kPluginID,
                                 (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> fillStencilPS =
      [cache pipelineStateForPluginID:fillStencilKey
                           registryID:registryID
                          pixelFormat:pixelFormat];

  NSString *fillColorKey =
      [NSString stringWithFormat:@"%@_fillColor_%lu", kPluginID,
                                 (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> fillColorPS =
      [cache pipelineStateForPluginID:fillColorKey
                           registryID:registryID
                          pixelFormat:pixelFormat];

  if (!fillStencilPS || !fillColorPS) {
    id<MTLLibrary> library = [device newDefaultLibrary];

    // Stencil pass: no color writes, just stencil invert.
    {
      MTLRenderPipelineDescriptor *desc =
          [[MTLRenderPipelineDescriptor alloc] init];
      desc.vertexFunction = [library newFunctionWithName:@"fillVertexShader"];
      desc.fragmentFunction =
          [library newFunctionWithName:@"fillFragmentShader"];
      desc.colorAttachments[0].pixelFormat = pixelFormat;
      desc.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
      desc.stencilAttachmentPixelFormat = stencilFormat;

      NSError *error = nil;
      fillStencilPS = [device newRenderPipelineStateWithDescriptor:desc
                                                             error:&error];
      if (fillStencilPS)
        [cache registerPipelineState:fillStencilPS
                         forPluginID:fillStencilKey
                          registryID:registryID
                         pixelFormat:pixelFormat];
    }

    // Color pass: draw where stencil is non-zero.
    {
      MTLRenderPipelineDescriptor *desc =
          [[MTLRenderPipelineDescriptor alloc] init];
      desc.vertexFunction = [library newFunctionWithName:@"fillVertexShader"];
      desc.fragmentFunction =
          [library newFunctionWithName:@"fillFragmentShader"];
      desc.colorAttachments[0].pixelFormat = pixelFormat;
      desc.colorAttachments[0].blendingEnabled = YES;
      desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
      desc.colorAttachments[0].destinationRGBBlendFactor =
          MTLBlendFactorOneMinusSourceAlpha;
      desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
      desc.colorAttachments[0].destinationAlphaBlendFactor =
          MTLBlendFactorOneMinusSourceAlpha;
      desc.stencilAttachmentPixelFormat = stencilFormat;

      NSError *error = nil;
      fillColorPS = [device newRenderPipelineStateWithDescriptor:desc
                                                           error:&error];
      if (fillColorPS)
        [cache registerPipelineState:fillColorPS
                         forPluginID:fillColorKey
                          registryID:registryID
                         pixelFormat:pixelFormat];
    }
  }

  // Stencil depth state objects for fill.
  MTLStencilDescriptor *stencilInvertDesc = [[MTLStencilDescriptor alloc] init];
  stencilInvertDesc.stencilCompareFunction = MTLCompareFunctionAlways;
  stencilInvertDesc.depthStencilPassOperation = MTLStencilOperationInvert;

  MTLDepthStencilDescriptor *fillStencilDSDesc =
      [[MTLDepthStencilDescriptor alloc] init];
  fillStencilDSDesc.frontFaceStencil = stencilInvertDesc;
  fillStencilDSDesc.backFaceStencil = stencilInvertDesc;
  id<MTLDepthStencilState> fillStencilDSState =
      [device newDepthStencilStateWithDescriptor:fillStencilDSDesc];

  MTLStencilDescriptor *stencilTestDesc = [[MTLStencilDescriptor alloc] init];
  stencilTestDesc.stencilCompareFunction = MTLCompareFunctionNotEqual;
  stencilTestDesc.readMask = 0xFF;
  stencilTestDesc.stencilFailureOperation = MTLStencilOperationKeep;
  stencilTestDesc.depthStencilPassOperation = MTLStencilOperationZero;

  MTLDepthStencilDescriptor *fillColorDSDesc =
      [[MTLDepthStencilDescriptor alloc] init];
  fillColorDSDesc.frontFaceStencil = stencilTestDesc;
  fillColorDSDesc.backFaceStencil = stencilTestDesc;
  id<MTLDepthStencilState> fillColorDSState =
      [device newDepthStencilStateWithDescriptor:fillColorDSDesc];

  // Create stencil texture matching output dimensions.
  id<MTLTexture> stencilTexture = nil;
  BOOL anyFill = NO;
  for (NSUInteger pi = 0; pi < paths.count; pi++) {
    if (paths[pi].fillEnabled && paths[pi].count >= 3 && !paths[pi].hidden) {
      anyFill = YES;
      break;
    }
  }
  if (anyFill && fillStencilPS && fillColorPS) {
    MTLTextureDescriptor *stencilTexDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:stencilFormat
                                                           width:outputWidth
                                                          height:outputHeight
                                                       mipmapped:NO];
    stencilTexDesc.usage = MTLTextureUsageRenderTarget;
    stencilTexDesc.storageMode = MTLStorageModePrivate;
    stencilTexture = [device newTextureWithDescriptor:stencilTexDesc];
  }

  // Render in reverse: index 0 is drawn last (on top), matching layer list.
  for (NSUInteger pi = paths.count; pi > 0; pi--) {
    KKBezierPath *path = paths[pi - 1];
    if (path.count < 2 || path.hidden)
      continue;

    // Fill (behind stroke): stencil-based even-odd fill.
    if (path.fillEnabled && path.count >= 3 && fillStencilPS && fillColorPS &&
        stencilTexture) {
      NSUInteger segsPerCurve = 64;
      BOOL isClosed = path.closed;
      NSUInteger curveCount = isClosed ? path.count : (path.count - 1);
      NSUInteger outlineCount = curveCount * segsPerCurve + (isClosed ? 0 : 1);
      simd_float2 *outline = malloc(outlineCount * sizeof(simd_float2));
      NSUInteger oc = 0;
      for (NSUInteger c = 0; c < curveCount; c++) {
        NSUInteger nextIdx = isClosed ? ((c + 1) % path.count) : (c + 1);
        for (NSUInteger s = 0; s < segsPerCurve; s++) {
          float t = (float)s / (float)segsPerCurve;
          simd_float2 pos = [path evaluatePointAtIndex:c
                                             nextIndex:nextIdx
                                                   atT:t];
          simd_float2 px = {pos.x * outputWidth - outputWidth / 2.0f,
                            (1.0f - pos.y) * outputHeight -
                                outputHeight / 2.0f};
          outline[oc++] = px;
        }
      }
      if (!isClosed) {
        simd_float2 pos = [path evaluatePointAtIndex:curveCount - 1
                                           nextIndex:curveCount
                                                 atT:1.0f];
        simd_float2 px = {pos.x * outputWidth - outputWidth / 2.0f,
                          (1.0f - pos.y) * outputHeight - outputHeight / 2.0f};
        outline[oc++] = px;
      }

      // Centroid
      simd_float2 center = {0, 0};
      for (NSUInteger i = 0; i < oc; i++)
        center += outline[i];
      center /= (float)oc;

      // Fan triangles from centroid
      NSUInteger triCount = oc;
      CanvasFillVertex *fillVerts =
          malloc(triCount * 3 * sizeof(CanvasFillVertex));
      for (NSUInteger i = 0; i < triCount; i++) {
        NSUInteger next = (i + 1) % oc;
        fillVerts[i * 3 + 0].position = center;
        fillVerts[i * 3 + 1].position = outline[i];
        fillVerts[i * 3 + 2].position = outline[next];
      }
      free(outline);

      id<MTLBuffer> fillBuf =
          [device newBufferWithBytes:fillVerts
                              length:triCount * 3 * sizeof(CanvasFillVertex)
                             options:MTLResourceStorageModeShared];
      free(fillVerts);

      // Pass 1: Stencil — draw fan triangles, invert stencil bit, no color.
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
        [enc setVertexBytes:&viewportSize
                     length:sizeof(viewportSize)
                    atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:triCount * 3];
        [enc endEncoding];
      }

      // Pass 2: Color — full-screen quad where stencil != 0.
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
        [enc setVertexBytes:&viewportSize
                     length:sizeof(viewportSize)
                    atIndex:1];
        [enc setFragmentBytes:&fc length:sizeof(fc) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6];
        [enc endEncoding];
      }
    }

    // Stroke
    if (path.strokeEnabled) {
      float sw = path.strokeWidth;
      float oa = path.opacity;
      simd_float4 color = {path.strokeR * oa, path.strokeG * oa,
                           path.strokeB * oa, oa};

      NSUInteger segsPerCurve = 128;
      NSUInteger curveCount = path.count - 1;
      if (path.closed && path.count >= 2)
        curveCount = path.count;
      NSUInteger capExtra = (!path.closed && path.lineCap != 0) ? 256 : 0;
      // Round joins can emit up to ~40 verts per join; budget 48 per join.
      NSUInteger joinExtra = (path.lineJoin != 0) ? curveCount * 48 : 0;
      NSUInteger maxVertices =
          curveCount * ((segsPerCurve + 1) * 2 + 2) + 2 + capExtra + joinExtra;
      CanvasVertex *vertices =
          (CanvasVertex *)malloc(maxVertices * sizeof(CanvasVertex));
      NSUInteger vertexCount =
          tessellatePath(path, sw, outputWidth, outputHeight, path.lineCap,
                         path.lineJoin, vertices);

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
      free(vertices);
    }
  }

  [commandBuffer commit];
  [commandBuffer waitUntilCompleted];
  [cache returnCommandQueueToCache:commandQueue];
  return YES;
}

@end
#pragma clang diagnostic pop
