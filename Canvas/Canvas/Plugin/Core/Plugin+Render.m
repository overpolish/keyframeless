/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "LayerList_Private.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"
#import "RenderFill.h"
#import "RenderImage.h"
#import "RenderStroke.h"
#import "ShaderTypes.h"
#import "SketchPath.h"
#import <IOSurface/IOSurfaceObjC.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

static NSDictionary<NSString *, KKBezierPath *> *
_kkIndexGroupsByID(NSArray<KKBezierPath *> *paths) {
  NSMutableDictionary<NSString *, KKBezierPath *> *out = nil;
  for (KKBezierPath *g in paths) {
    if (g.isGroup && g.groupID.length) {
      if (!out)
        out = [NSMutableDictionary dictionary];
      out[g.groupID] = g;
    }
  }
  return out;
}

/// Identity 3x3 affine. Used for draw calls that don't carry a per-path
/// transform (off-screen image effects, fullscreen-quad fill color pass).
static CanvasPathTransform _kkIdentityPathTransform(void) {
  CanvasPathTransform x;
  x.m = matrix_identity_float3x3;
  x.mInv = matrix_identity_float3x3;
  return x;
}

/// Object-space bbox of a single (non-group) path. Approximates curves with
/// 16 samples per segment, matching the OSC's bboxCenterOfPath:.
static BOOL _kkPathBounds(KKBezierPath *p, simd_float2 *outMin,
                          simd_float2 *outMax) {
  if (p.count == 0)
    return NO;
  NSUInteger segCount = p.count - 1;
  if (p.closed && p.count >= 2)
    segCount = p.count;
  simd_float2 first = [p evaluatePointAtIndex:0 nextIndex:0 atT:0.0f];
  float minX = first.x, minY = first.y, maxX = first.x, maxY = first.y;
  for (NSUInteger c = 0; c < segCount; c++) {
    NSUInteger nextIdx = (c + 1) % p.count;
    for (NSUInteger s = 0; s <= 16; s++) {
      float t = (float)s / 16.0f;
      simd_float2 pos = [p evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      minX = fminf(minX, pos.x);
      minY = fminf(minY, pos.y);
      maxX = fmaxf(maxX, pos.x);
      maxY = fmaxf(maxY, pos.y);
    }
  }
  *outMin = (simd_float2){minX, minY};
  *outMax = (simd_float2){maxX, maxY};
  return YES;
}

/// Object-space bbox center keyed by layerID, for both groups (union of
/// descendants) and individual paths. (0.5, 0.5) is returned when a group
/// has no points yet — matches OSC fallback so anchor handles don't snap to
/// (0,0) on empty groups.
static NSDictionary<NSString *, NSData *> *
_kkBboxCentersByLayerID(NSArray<KKBezierPath *> *paths) {
  NSMutableDictionary<NSString *, NSData *> *centers =
      [NSMutableDictionary dictionary];
  // First pass: non-group paths.
  NSMutableDictionary<NSString *, NSData *> *pathBboxMin =
      [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString *, NSData *> *pathBboxMax =
      [NSMutableDictionary dictionary];
  for (KKBezierPath *p in paths) {
    if (p.isGroup || !p.layerID.length)
      continue;
    simd_float2 bmin, bmax;
    if (!_kkPathBounds(p, &bmin, &bmax))
      continue;
    pathBboxMin[p.layerID] = [NSData dataWithBytes:&bmin length:sizeof(bmin)];
    pathBboxMax[p.layerID] = [NSData dataWithBytes:&bmax length:sizeof(bmax)];
    simd_float2 c = (bmin + bmax) * 0.5f;
    centers[p.layerID] = [NSData dataWithBytes:&c length:sizeof(c)];
  }
  // Second pass: groups, by walking descendants. Iterate until stable so
  // sub-groups resolve via earlier-resolved children. Cap iterations to
  // group count + 1 so a malformed cycle can't spin forever.
  NSUInteger maxRounds = paths.count + 1;
  for (NSUInteger round = 0; round < maxRounds; round++) {
    BOOL grew = NO;
    for (KKBezierPath *g in paths) {
      if (!g.isGroup || !g.groupID.length)
        continue;
      if (centers[g.layerID])
        continue;
      simd_float2 gmin = {HUGE_VALF, HUGE_VALF};
      simd_float2 gmax = {-HUGE_VALF, -HUGE_VALF};
      BOOL found = NO;
      for (KKBezierPath *child in paths) {
        if (![child.parentGroupID isEqualToString:g.groupID])
          continue;
        NSData *cMin = pathBboxMin[child.layerID];
        NSData *cMax = pathBboxMax[child.layerID];
        if (!cMin || !cMax)
          continue;
        simd_float2 cmin, cmax;
        [cMin getBytes:&cmin length:sizeof(cmin)];
        [cMax getBytes:&cmax length:sizeof(cmax)];
        gmin = simd_min(gmin, cmin);
        gmax = simd_max(gmax, cmax);
        found = YES;
      }
      if (found && g.layerID.length) {
        pathBboxMin[g.layerID] = [NSData dataWithBytes:&gmin
                                                length:sizeof(gmin)];
        pathBboxMax[g.layerID] = [NSData dataWithBytes:&gmax
                                                length:sizeof(gmax)];
        simd_float2 c = (gmin + gmax) * 0.5f;
        centers[g.layerID] = [NSData dataWithBytes:&c length:sizeof(c)];
        grew = YES;
      }
    }
    if (!grew)
      break;
  }
  return centers;
}

/// Build the local 3x3 affine for one path/group in centered-pixel space:
/// `T(translate) · T(anchor) · S(scale) · T(-anchor)`. The anchor is an
/// object-space offset from the path's bbox center; the bbox center comes
/// from `centers` so groups resolve via their descendants. Y is flipped
/// because bezier points live in Y-up object space while pixel space is
/// Y-down.
static matrix_float3x3
_kkLocalMatrix(KKBezierPath *p, NSDictionary<NSString *, NSData *> *centers,
               float W, float H) {
  float pxTx = p.translateX * W;
  float pxTy = -p.translateY * H;
  simd_float2 bboxCenter = (simd_float2){0.5f, 0.5f};
  if (p.layerID.length) {
    NSData *d = centers[p.layerID];
    if (d.length >= sizeof(bboxCenter))
      [d getBytes:&bboxCenter length:sizeof(bboxCenter)];
  }
  float anchorObjX = bboxCenter.x + p.anchorX;
  float anchorObjY = bboxCenter.y + p.anchorY;
  float ax = (anchorObjX - 0.5f) * W;
  float ay = (0.5f - anchorObjY) * H;
  float sx = p.scaleX;
  float sy = p.scaleY;
  return simd_matrix(
      simd_make_float3(sx, 0, 0), simd_make_float3(0, sy, 0),
      simd_make_float3(pxTx + ax * (1.0f - sx), pxTy + ay * (1.0f - sy), 1));
}

/// Build the per-path forward + inverse affine in centered-pixel space.
/// Composes `path`'s own local matrix with each enabled ancestor group's
/// local matrix (parent matrices multiply on the left). Walks parentGroupID
/// with a depth cap so a cyclic parent reference can't spin forever.
static CanvasPathTransform
_kkBuildPathTransform(KKBezierPath *path,
                      NSDictionary<NSString *, KKBezierPath *> *groupsByID,
                      NSDictionary<NSString *, NSData *> *bboxCenters,
                      float outputWidth, float outputHeight) {
  if (!path.transformEnabled)
    return _kkIdentityPathTransform();
  matrix_float3x3 m =
      _kkLocalMatrix(path, bboxCenters, outputWidth, outputHeight);
  NSString *parentID = path.parentGroupID;
  NSUInteger depth = 0;
  while (parentID.length && depth++ < 32) {
    KKBezierPath *g = groupsByID[parentID];
    if (!g)
      break;
    if (g.transformEnabled)
      m = simd_mul(_kkLocalMatrix(g, bboxCenters, outputWidth, outputHeight),
                   m);
    parentID = g.parentGroupID;
  }
  CanvasPathTransform x;
  x.m = m;
  x.mInv = simd_inverse(m);
  return x;
}

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

@implementation CanvasPlugin (Render)

/// Build the per-sample evaluated paths blob for `sampleTime`. Decodes
/// `baseBlob` afresh each call so per-sample mutations don't leak across
/// samples. Returns nil when there are no paths.
- (NSData *)_kkSamplePathsBlobFromBaseBlob:(NSData *)baseBlob
                               paramGetAPI:
                                   (id<FxParameterRetrievalAPI_v6>)paramGetAPI
                                     lanes:(NSArray<KKTimingLane *> *)lanes
                                sampleTime:(CMTime)sampleTime
                               effectStart:(CMTime)effectStart
                              effectDurSec:(double)effectDurSec {
  if (baseBlob.length == 0)
    return nil;
  NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:baseBlob];

  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  NSIndexSet *sel = uuid ? KKCanvasCurrentSelection(uuid) : nil;
  if (sel.count > 0) {
    KKParamsToSelectedPaths(paramGetAPI, sel, paths);
  } else {
    NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
    if (selIdx >= 0 && (NSUInteger)selIdx < paths.count &&
        !paths[selIdx].isGroup)
      KKParamsToPath(paramGetAPI, paths[selIdx]);
  }

  if (lanes.count && effectDurSec > 0) {
    double frac = MAX(0.0, MIN(1.0, (CMTimeGetSeconds(sampleTime) -
                                     CMTimeGetSeconds(effectStart)) /
                                        effectDurSec));
    [CanvasPlugin kkApplyLanes:lanes atFraction:frac toPaths:paths];
  }
  // Per-path translate/rotate/scale lives on KKBezierPath as properties
  // (translateX/Y, future scale/rotate); the render side composes them
  // into a per-path matrix and applies it in the vertex shader. Nothing
  // to bake into points here.
  return [KKBezierPath blobFromPaths:paths];
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];

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

  // Snapshot motion-blur state. When transitionsOnly is set and no lane is
  // mid-transition at this frame, drop blur so the cheap single-pass path
  // wins (mirrors MagicMove).
  KKMotionBlurState mbState =
      [KKMotionBlur snapshotStateWithParameterAPI:paramGetAPI
                                        timingAPI:timingAPI
                                           atTime:renderTime
                                          quality:qualityLevel];
  if (mbState.enabled && mbState.transitionsOnly &&
      ![self multiStageAnyLaneInTransitionAtTime:renderTime])
    mbState.enabled = false;
  // Canvas's per-path render assumes the sample target is sized to the
  // final output. Opt out of subframe downscaling so sample dims match
  // outputWidth/Height (KKMotionBlur header documents this opt-out).
  mbState.subframeScale = 1.0f;

  NSString *baseStr = nil;
  [paramGetAPI getStringParameterValue:&baseStr fromParameter:kParamPathData];
  NSData *baseBlob = baseStr.length
                         ? [[NSData alloc] initWithBase64EncodedString:baseStr
                                                               options:0]
                         : nil;

  NSString *lanesJSON = nil;
  [paramGetAPI getStringParameterValue:&lanesJSON
                         fromParameter:kKKParamMultiStageData];
  NSArray<KKTimingLane *> *lanes =
      lanesJSON.length ? [KKTimingLane lanesFromJSON:lanesJSON] : nil;
  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double effectDurSec = CMTimeGetSeconds(effectDuration);

  NSArray<NSValue *> *sampleTimes =
      mbState.enabled
          ? [KKMotionBlur sampleTimesForState:mbState renderTime:renderTime]
          : @[ [NSValue valueWithBytes:&renderTime objCType:@encode(CMTime)] ];

  NSMutableArray<NSData *> *sampleBlobs =
      [NSMutableArray arrayWithCapacity:sampleTimes.count];
  for (NSValue *tv in sampleTimes) {
    CMTime t = kCMTimeZero;
    [tv getValue:&t];
    NSData *blob = [self _kkSamplePathsBlobFromBaseBlob:baseBlob
                                            paramGetAPI:paramGetAPI
                                                  lanes:lanes
                                             sampleTime:t
                                            effectStart:effectStart
                                           effectDurSec:effectDurSec];
    [sampleBlobs addObject:(blob ?: [NSData data])];
  }

  // Layout: [CanvasStrokeParams | KKMotionBlurState | uint32 sampleCount |
  //         (uint32 blobLen | blobBytes) × sampleCount]
  NSMutableData *state = [NSMutableData data];
  [state appendBytes:&params length:sizeof(params)];
  [state appendBytes:&mbState length:sizeof(mbState)];
  uint32_t sampleCount = (uint32_t)sampleBlobs.count;
  [state appendBytes:&sampleCount length:sizeof(sampleCount)];
  for (NSData *blob in sampleBlobs) {
    uint32_t len = (uint32_t)blob.length;
    [state appendBytes:&len length:sizeof(len)];
    if (len)
      [state appendData:blob];
  }
  *pluginState = state;
  return (*pluginState != nil);
}

- (void)renderPath:(KKBezierPath *)path
          originalPath:(KKBezierPath *)orig
             transform:(CanvasPathTransform)pathXform
                target:(id<MTLTexture>)target
           outputWidth:(float)outputWidth
          outputHeight:(float)outputHeight
                device:(id<MTLDevice>)device
         commandBuffer:(id<MTLCommandBuffer>)commandBuffer
          viewportSize:(simd_uint2)viewportSize
               imagePS:(id<MTLRenderPipelineState>)imagePS
              strokePS:(id<MTLRenderPipelineState>)strokePS
         fillStencilPS:(id<MTLRenderPipelineState>)fillStencilPS
           fillColorPS:(id<MTLRenderPipelineState>)fillColorPS
       strokeStencilPS:(id<MTLRenderPipelineState>)strokeStencilPS
    fillStencilDSState:(id<MTLDepthStencilState>)fillStencilDSState
      fillColorDSState:(id<MTLDepthStencilState>)fillColorDSState
        stencilTexture:(id<MTLTexture>)stencilTexture {
  if (path.isImage && path.imagePath && imagePS) {
    id<MTLTexture> imgTex = KKGetOrLoadImageTexture(path.imagePath, device);
    if (imgTex) {
      KKBezierPoint bl = [path pointAtIndex:0];
      KKBezierPoint br = [path pointAtIndex:1];
      KKBezierPoint tr = [path pointAtIndex:2];
      KKBezierPoint tl = [path pointAtIndex:3];
      float hw = outputWidth / 2.0f;
      float hh = outputHeight / 2.0f;

      id<MTLTexture> drawTex =
          KKProcessImageWithEffects(imgTex, path, device, commandBuffer);

      float scaleX = (float)drawTex.width / (float)imgTex.width;
      float scaleY = (float)drawTex.height / (float)imgTex.height;
      float cx = (bl.x + tr.x) * 0.5f;
      float cy = (bl.y + tr.y) * 0.5f;

      CanvasFillVertex quadVerts[4] = {
          {{(cx + (bl.x - cx) * scaleX) * outputWidth - hw,
            (1.0f - (cy + (bl.y - cy) * scaleY)) * outputHeight - hh}},
          {{(cx + (br.x - cx) * scaleX) * outputWidth - hw,
            (1.0f - (cy + (br.y - cy) * scaleY)) * outputHeight - hh}},
          {{(cx + (tl.x - cx) * scaleX) * outputWidth - hw,
            (1.0f - (cy + (tl.y - cy) * scaleY)) * outputHeight - hh}},
          {{(cx + (tr.x - cx) * scaleX) * outputWidth - hw,
            (1.0f - (cy + (tr.y - cy) * scaleY)) * outputHeight - hh}},
      };

      float opacity = path.opacity;
      MTLRenderPassDescriptor *rpd =
          [MTLRenderPassDescriptor renderPassDescriptor];
      rpd.colorAttachments[0].texture = target;
      rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
      rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

      id<MTLRenderCommandEncoder> enc =
          [commandBuffer renderCommandEncoderWithDescriptor:rpd];
      [enc setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
      [enc setRenderPipelineState:imagePS];
      [enc setVertexBytes:quadVerts length:sizeof(quadVerts) atIndex:0];
      [enc setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:1];
      [enc setVertexBytes:&pathXform length:sizeof(pathXform) atIndex:2];
      [enc setFragmentTexture:drawTex atIndex:0];
      [enc setFragmentBytes:&opacity length:sizeof(opacity) atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:4];
      [enc endEncoding];
    }
  } else if (path.fillEnabled && orig.count >= 2 && fillStencilPS &&
             fillColorPS && stencilTexture) {
    if (path.sketchFillStyle > 0) {
      KKBezierPath *clipPath = orig;
      if (orig.sketchEnabled && orig.sketchRoughness > 0.0001f) {
        clipPath = KKSketchPath(orig, orig.sketchRoughness, orig.sketchBowing,
                                orig.sketchSeed, 1, outputWidth, outputHeight);
      }
      KKRenderFillStencilOnly(clipPath, pathXform, outputWidth, outputHeight,
                              device, commandBuffer, target, stencilTexture,
                              fillStencilPS, fillStencilDSState, viewportSize);
      KKRenderSketchFillForPath(orig, pathXform, outputWidth, outputHeight,
                                device, commandBuffer, target, stencilTexture,
                                strokeStencilPS, fillColorDSState, viewportSize,
                                YES);
    } else {
      KKBezierPath *fillPath = orig;
      if (orig.sketchEnabled && orig.sketchRoughness > 0.0001f) {
        fillPath = KKSketchPath(orig, orig.sketchRoughness, orig.sketchBowing,
                                orig.sketchSeed, 1, outputWidth, outputHeight);
      }
      KKRenderFillForPath(fillPath, pathXform, outputWidth, outputHeight,
                          device, commandBuffer, target, stencilTexture,
                          fillStencilPS, fillColorPS, fillStencilDSState,
                          fillColorDSState, viewportSize);
      if (strokePS) {
        KKRenderFillAAOutline(fillPath, pathXform, outputWidth, outputHeight,
                              device, commandBuffer, target, strokePS,
                              viewportSize);
      }
    }
  }

  if (!path.isImage && path.strokeEnabled) {
    KKRenderStrokeForPath(path, pathXform, outputWidth, outputHeight, device,
                          commandBuffer, target, strokePS, viewportSize);
  }
}

/// Decode a sample's path blob from pluginState. Returns the inner
/// `paths` array, plus the count of bytes consumed (so callers can advance
/// to the next sample). Sets *paths to an empty array if the sample's blob
/// is empty.
static BOOL _kkDecodeSampleAt(NSData *pluginState, NSUInteger offset,
                              NSMutableArray<KKBezierPath *> **paths,
                              NSUInteger *bytesConsumed) {
  if (offset + sizeof(uint32_t) > pluginState.length)
    return NO;
  uint32_t blobLen = 0;
  [pluginState getBytes:&blobLen range:NSMakeRange(offset, sizeof(blobLen))];
  NSUInteger payloadStart = offset + sizeof(uint32_t);
  if (payloadStart + blobLen > pluginState.length)
    return NO;
  NSData *blob =
      blobLen
          ? [pluginState subdataWithRange:NSMakeRange(payloadStart, blobLen)]
          : nil;
  *paths = blob ? [KKBezierPath pathsFromBlob:blob] : [NSMutableArray array];
  *bytesConsumed = sizeof(uint32_t) + blobLen;
  return YES;
}

/// Renders one Canvas frame (paths → target). Encodes onto `commandBuffer`
/// but does NOT commit/wait — caller owns lifetime. `sampleIndex` < 0 uses
/// the static texture cache (single-frame path); ≥ 0 fetches per-sample
/// scratch textures from `KKMotionBlur` so concurrent samples on the same
/// command buffer don't share state.
- (BOOL)_kkRenderFrameWithDevice:(id<MTLDevice>)device
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                          target:(id<MTLTexture>)targetTexture
                    inputTexture:(id<MTLTexture>)inputTexture
                     outputWidth:(float)outputWidth
                    outputHeight:(float)outputHeight
                     renderScale:(float)renderScale
                           cache:(KKMetalDeviceCache *)cache
                      registryID:(uint64_t)registryID
                     pixelFormat:(MTLPixelFormat)pixelFormat
                           paths:(NSMutableArray<KKBezierPath *> *)inputPaths
                     sampleIndex:(int)sampleIndex {
  // Fix up rounded rect geometry.
  for (KKBezierPath *p in inputPaths) {
    if (p.isRect && !p.isImage && p.count >= 4) {
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

  // Blit upstream input → target so the canvas composites over it.
  {
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    NSUInteger copyW = MIN(inputTexture.width, targetTexture.width);
    NSUInteger copyH = MIN(inputTexture.height, targetTexture.height);
    [blit copyFromTexture:inputTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(copyW, copyH, 1)
                toTexture:targetTexture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
  }

  // Scale pixel-space stroke properties by render quality.
  if (renderScale < 0.9999f) {
    for (KKBezierPath *p in inputPaths) {
      p.strokeWidth *= renderScale;
      p.endWidth *= renderScale;
      p.dashLength *= renderScale;
      p.dashGap *= renderScale;
      p.dotGap *= renderScale;
      p.sketchFillGap *= renderScale;
      p.sketchFillWeight *= renderScale;
    }
  }

  // Apply sketch jitter — produces (renderPaths, origPaths) pairs.
  NSMutableArray<KKBezierPath *> *origPathsMut =
      [NSMutableArray arrayWithCapacity:inputPaths.count];
  NSMutableArray<KKBezierPath *> *renderPaths =
      [NSMutableArray arrayWithCapacity:inputPaths.count];
  for (KKBezierPath *p in inputPaths) {
    if (p.sketchEnabled && p.count >= 2 && !p.hidden) {
      BOOL needsSplit = !p.closed && p.sketchStrokes >= 2;
      if (needsSplit) {
        KKBezierPath *pass1 =
            KKSketchPath(p, p.sketchRoughness, p.sketchBowing, p.sketchSeed, 1,
                         outputWidth, outputHeight);
        [renderPaths addObject:pass1];
        [origPathsMut addObject:p];
        KKBezierPath *pass2 = KKSketchPath(p, p.sketchRoughness, p.sketchBowing,
                                           p.sketchSeed ^ 0xFACE0042, 1,
                                           outputWidth, outputHeight);
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
  NSArray<KKBezierPath *> *paths = renderPaths;
  NSArray<KKBezierPath *> *origPaths = origPathsMut;

  BOOL hasDrawablePaths = NO;
  for (KKBezierPath *p in paths) {
    if (p.count >= 2 && !p.hidden) {
      hasDrawablePaths = YES;
      break;
    }
  }
  if (!hasDrawablePaths)
    return YES; // background blit already laid down — nothing else to do

  NSString *strokeKey = [NSString
      stringWithFormat:@"%@_stroke_%lu", kPluginID, (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> strokePS = getOrCreatePipeline(
      strokeKey, registryID, pixelFormat, cache, device, @"strokeVertexShader",
      @"strokeFragmentShader", YES, MTLPixelFormatInvalid);
  if (!strokePS)
    return NO;

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
      fillColorKey, registryID, pixelFormat, cache, device, @"fillVertexShader",
      @"fillFragmentShader", YES, stencilFormat);

  NSString *strokeStencilKey =
      [NSString stringWithFormat:@"%@_strokeStencil_%lu", kPluginID,
                                 (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> strokeStencilPS = getOrCreatePipeline(
      strokeStencilKey, registryID, pixelFormat, cache, device,
      @"strokeVertexShader", @"strokeFragmentShader", YES, stencilFormat);

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

    MTLStencilDescriptor *stencilTestDesc = [[MTLStencilDescriptor alloc] init];
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

  NSUInteger texW = (NSUInteger)outputWidth;
  NSUInteger texH = (NSUInteger)outputHeight;

  BOOL anyFill = NO;
  for (KKBezierPath *p in paths) {
    if (p.fillEnabled && p.count >= 2 && !p.hidden) {
      anyFill = YES;
      break;
    }
  }

  NSString *compositeKey =
      [NSString stringWithFormat:@"%@_composite_%lu", kPluginID,
                                 (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> compositePS =
      getOrCreatePipeline(compositeKey, registryID, pixelFormat, cache, device,
                          @"compositeVertexShader", @"compositeFragmentShader",
                          YES, MTLPixelFormatInvalid);

  NSString *imageKey = [NSString
      stringWithFormat:@"%@_image_%lu", kPluginID, (unsigned long)pixelFormat];
  id<MTLRenderPipelineState> imagePS = getOrCreatePipeline(
      imageKey, registryID, pixelFormat, cache, device, @"imageVertexShader",
      @"imageFragmentShader", YES, MTLPixelFormatInvalid);

  // Stencil + intermediate textures: motion-blur path uses per-sample
  // scratch textures (multiple samples ride the same command buffer);
  // single-frame path keeps the static cache.
  id<MTLTexture> stencilTexture = nil;
  id<MTLTexture> intermediateTexture = nil;

  if (sampleIndex >= 0) {
    if (anyFill && fillStencilPS && fillColorPS) {
      stencilTexture =
          [KKMotionBlur scratchTextureForKey:@"canvas.stencil"
                                 sampleIndex:sampleIndex
                                       width:texW
                                      height:texH
                                      format:stencilFormat
                                       usage:MTLTextureUsageRenderTarget
                                      device:device];
    }
    if (compositePS) {
      intermediateTexture =
          [KKMotionBlur scratchTextureForKey:@"canvas.intermediate"
                                 sampleIndex:sampleIndex
                                       width:texW
                                      height:texH
                                      format:pixelFormat
                                       usage:MTLTextureUsageRenderTarget |
                                             MTLTextureUsageShaderRead
                                      device:device];
    }
  } else {
    static id<MTLTexture> sCachedStencilTex = nil;
    static id<MTLTexture> sCachedIntermediateTex = nil;
    static NSUInteger sCachedTexW = 0, sCachedTexH = 0;
    static MTLPixelFormat sCachedIntPixFmt = MTLPixelFormatInvalid;

    if (sCachedTexW != texW || sCachedTexH != texH) {
      sCachedStencilTex = nil;
      sCachedIntermediateTex = nil;
      sCachedTexW = texW;
      sCachedTexH = texH;
      sCachedIntPixFmt = MTLPixelFormatInvalid;
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
  }

  NSDictionary<NSString *, KKBezierPath *> *groupsByID =
      _kkIndexGroupsByID(origPaths);
  NSDictionary<NSString *, NSData *> *bboxCenters =
      _kkBboxCentersByLayerID(origPaths);

  for (NSUInteger pi = paths.count; pi > 0; pi--) {
    @autoreleasepool {
      KKBezierPath *path = paths[pi - 1];
      KKBezierPath *orig = origPaths[pi - 1];
      if (path.count < 2 || path.hidden)
        continue;
      CanvasPathTransform pathXform = _kkBuildPathTransform(
          orig, groupsByID, bboxCenters, outputWidth, outputHeight);

      float pathOpacity = path.opacity;
      BOOL needsIntermediate =
          intermediateTexture && compositePS && pathOpacity < 0.9999f;

      id<MTLTexture> drawTarget =
          needsIntermediate ? intermediateTexture : targetTexture;

      if (needsIntermediate) {
        path.opacity = 1.0f;
        orig.opacity = 1.0f;

        MTLRenderPassDescriptor *clearRPD =
            [MTLRenderPassDescriptor renderPassDescriptor];
        clearRPD.colorAttachments[0].texture = intermediateTexture;
        clearRPD.colorAttachments[0].loadAction = MTLLoadActionClear;
        clearRPD.colorAttachments[0].storeAction = MTLStoreActionStore;
        clearRPD.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLRenderCommandEncoder> clearEnc =
            [commandBuffer renderCommandEncoderWithDescriptor:clearRPD];
        [clearEnc endEncoding];
      }

      [self renderPath:path
                originalPath:orig
                   transform:pathXform
                      target:drawTarget
                 outputWidth:outputWidth
                outputHeight:outputHeight
                      device:device
               commandBuffer:commandBuffer
                viewportSize:viewportSize
                     imagePS:imagePS
                    strokePS:strokePS
               fillStencilPS:fillStencilPS
                 fillColorPS:fillColorPS
             strokeStencilPS:strokeStencilPS
          fillStencilDSState:fillStencilDSState
            fillColorDSState:fillColorDSState
              stencilTexture:stencilTexture];

      if (needsIntermediate) {
        path.opacity = pathOpacity;
        orig.opacity = pathOpacity;

        MTLRenderPassDescriptor *compRPD =
            [MTLRenderPassDescriptor renderPassDescriptor];
        compRPD.colorAttachments[0].texture = targetTexture;
        compRPD.colorAttachments[0].loadAction = MTLLoadActionLoad;
        compRPD.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLRenderCommandEncoder> compEnc =
            [commandBuffer renderCommandEncoderWithDescriptor:compRPD];
        [compEnc
            setViewport:(MTLViewport){0, 0, outputWidth, outputHeight, -1, 1}];
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
    }
  }
  return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  [KKPlugin multiStageRenderTickForAPI:self.apiManager
                                atTime:renderTime
                                sender:self];

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

  // Decode header (CanvasStrokeParams + KKMotionBlurState + sample count)
  // and locate each sample's path-blob slice within pluginState.
  NSUInteger headerLen =
      sizeof(CanvasStrokeParams) + sizeof(KKMotionBlurState) + sizeof(uint32_t);
  if (pluginState.length < headerLen)
    return NO;
  KKMotionBlurState mbState;
  [pluginState getBytes:&mbState
                  range:NSMakeRange(sizeof(CanvasStrokeParams),
                                    sizeof(KKMotionBlurState))];
  uint32_t sampleCount = 0;
  [pluginState getBytes:&sampleCount
                  range:NSMakeRange(sizeof(CanvasStrokeParams) +
                                        sizeof(KKMotionBlurState),
                                    sizeof(uint32_t))];
  if (sampleCount == 0)
    return NO;

  NSMutableArray<NSNumber *> *sampleOffsets =
      [NSMutableArray arrayWithCapacity:sampleCount];
  {
    NSUInteger off = headerLen;
    for (uint32_t i = 0; i < sampleCount; i++) {
      [sampleOffsets addObject:@(off)];
      if (off + sizeof(uint32_t) > pluginState.length)
        return NO;
      uint32_t blobLen = 0;
      [pluginState getBytes:&blobLen range:NSMakeRange(off, sizeof(blobLen))];
      off += sizeof(uint32_t) + blobLen;
      if (off > pluginState.length)
        return NO;
    }
  }

  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:destinationImage];
  uint64_t registryID = destinationImage.deviceRegistryID;
  id<MTLDevice> device = [cache deviceWithRegistryID:registryID];

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

  if (mbState.enabled && sampleCount > 1) {
    __weak typeof(self) weakSelf = self;
    NSData *capturedState = pluginState;
    NSArray<NSNumber *> *capturedOffsets = sampleOffsets;
    BOOL applied = [KKMotionBlur
        applyToDestinationImage:destinationImage
                   sourceImages:sourceImages
                          state:mbState
                     renderTime:renderTime
                    renderBlock:^BOOL(int sampleIndex,
                                      id<MTLTexture> sampleDest,
                                      id<MTLCommandBuffer> commandBuffer,
                                      NSArray<id<MTLTexture>> *inputTextures) {
                      __strong typeof(weakSelf) strongSelf = weakSelf;
                      if (!strongSelf || inputTextures.count == 0)
                        return NO;
                      if ((NSUInteger)sampleIndex >= capturedOffsets.count)
                        return NO;
                      NSUInteger off =
                          capturedOffsets[sampleIndex].unsignedIntegerValue;
                      NSMutableArray<KKBezierPath *> *paths = nil;
                      NSUInteger consumed = 0;
                      if (!_kkDecodeSampleAt(capturedState, off, &paths,
                                             &consumed))
                        return NO;
                      return
                          [strongSelf _kkRenderFrameWithDevice:device
                                                 commandBuffer:commandBuffer
                                                        target:sampleDest
                                                  inputTexture:inputTextures[0]
                                                   outputWidth:outputWidth
                                                  outputHeight:outputHeight
                                                   renderScale:renderScale
                                                         cache:cache
                                                    registryID:registryID
                                                   pixelFormat:pixelFormat
                                                         paths:paths
                                                   sampleIndex:sampleIndex];
                    }];
    if (applied)
      return YES;
    // Fall through on failure — render the un-blurred frame.
  }

  id<MTLCommandQueue> commandQueue =
      [cache commandQueueWithRegistryID:registryID pixelFormat:pixelFormat];
  if (!commandQueue)
    return NO;

  @autoreleasepool {
    id<MTLTexture> outputTexture =
        [destinationImage metalTextureForDevice:device];
    id<MTLTexture> inputTexture =
        [sourceImages[0] metalTextureForDevice:device];

    NSMutableArray<KKBezierPath *> *paths = nil;
    NSUInteger consumed = 0;
    if (!_kkDecodeSampleAt(pluginState, sampleOffsets[0].unsignedIntegerValue,
                           &paths, &consumed))
      paths = [NSMutableArray array];

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    commandBuffer.label = @"Canvas Command Buffer";
    [commandBuffer enqueue];

    BOOL ok = [self _kkRenderFrameWithDevice:device
                               commandBuffer:commandBuffer
                                      target:outputTexture
                                inputTexture:inputTexture
                                 outputWidth:outputWidth
                                outputHeight:outputHeight
                                 renderScale:renderScale
                                       cache:cache
                                  registryID:registryID
                                 pixelFormat:pixelFormat
                                       paths:paths
                                 sampleIndex:-1];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
    [cache returnCommandQueueToCache:commandQueue];
    return ok;
  }
}

@end
