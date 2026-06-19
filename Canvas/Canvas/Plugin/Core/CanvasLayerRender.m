/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h"
#import "CanvasImageTexture.h"
#import "CanvasLayerTransform.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKPluginHost.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KKShape.h>
#import <simd/simd.h>

NSMutableArray<KKBezierPath *> *CanvasReadLayerPaths(id<PROAPIAccessing> api,
                                                     id target) {
  if (!api)
    return [NSMutableArray array];
  id<FxCustomParameterActionAPI_v4> action =
      [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action)
    return [NSMutableArray array];
  id token = target ?: (id)action;
  [action startAction:token];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *b64 = KKReadCustomParamString(getAPI, kParamLayerData);
  [action endAction:token];
  if (b64.length == 0)
    return [NSMutableArray array];
  NSData *blob = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
  NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
  return paths ?: [NSMutableArray array];
}

void CanvasEncodeSourceTile(id<MTLRenderCommandEncoder> encoder,
                            id<MTLTexture> source, float imageWidth,
                            float imageHeight, float tileShiftX,
                            float tileShiftY) {
  if (!encoder || !source)
    return;
  // A full-image identity quad: same image-centered pixel space + tile-shift as
  // the layers, so the source tiles the same way (correct in the sub-tiled,
  // reverse-Y library preview). For a full-frame render shift=0 -> m4=P, which
  // reproduces the orthographic full-frame source draw.
  matrix_float4x4 m4 = CanvasLayerTiltMatrix(
      CanvasLayerTransformIdentity(), simd_make_float2(0.0f, 0.0f), imageWidth,
      imageHeight, simd_make_float2(tileShiftX, tileShiftY));
  float halfW = imageWidth * 0.5f, halfH = imageHeight * 0.5f;
  KKVertex2D quad[4] = {
      {{halfW, -halfH}, {1, 1}},
      {{-halfW, -halfH}, {0, 1}},
      {{halfW, halfH}, {1, 0}},
      {{-halfW, halfH}, {0, 0}},
  };
  float opacity = 1.0f; // image pipeline's opacity fragment reads buffer 0
  [encoder setVertexBytes:&m4
                   length:sizeof(m4)
                  atIndex:KKVertexInputIndex_Transform];
  [encoder setVertexBytes:quad
                   length:sizeof(quad)
                  atIndex:KKVertexInputIndex_Vertices];
  [encoder setFragmentBytes:&opacity length:sizeof(opacity) atIndex:0];
  [encoder setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
              vertexStart:0
              vertexCount:4];
}

// One ready-to-draw image layer: its full transform, verts, opacity, texture,
// and its 3D centre depth (for back-to-front sorting). `order` is the original
// layer-stack draw order (bottom-first), the tiebreak for equal depth so flat /
// untilted layers keep strict layer-list stacking.
typedef struct {
  matrix_float4x4 matrix;
  KKVertex2D quad[4];
  float opacity;
  __unsafe_unretained id<MTLTexture> tex;
  float depth;
  NSInteger order;
} CanvasDrawItem;

void CanvasEncodeImageLayers(
    NSArray<KKBezierPath *> *layers, id<MTLRenderCommandEncoder> encoder,
    id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *cache, float imageWidth,
    float imageHeight, float tileShiftX, float tileShiftY, double frac,
    NSString *overrideLayerID, KKTimeline *overrideTimeline) {
  if (!encoder || !device || layers.count == 0)
    return;
  simd_float2 tileShift = simd_make_float2(tileShiftX, tileShiftY);
  simd_float2 scale = simd_make_float2(imageWidth, imageHeight);
  simd_float2 half = simd_make_float2(0.5f, 0.5f);

  // Build pass: gather each drawable layer's transform + verts + 3D centre
  // depth, in bottom-first stack order.
  CanvasDrawItem *items = malloc(sizeof(CanvasDrawItem) * layers.count);
  NSInteger count = 0;
  for (NSInteger i = (NSInteger)layers.count - 1; i >= 0; i--) {
    KKBezierPath *path = layers[i];
    if (!path.isImage || path.hidden || path.isGroup || !path.imagePath.length)
      continue;
    if (![path.shape isKindOfClass:[KKRectShape class]])
      continue;

    id<MTLTexture> tex =
        CanvasImageTextureForPath(path.imagePath, device, cache);
    if (!tex)
      continue;

    KKRectShape *rect = (KKRectShape *)path.shape;
    // Negative frac = caller wants the static rect (no transform). The selected
    // layer (overrideLayerID) reads the live popover timeline so a mini-viewer
    // handle drag previews before it persists into the layer's animationJSON.
    CanvasLayerTransform t;
    if (frac < 0.0)
      t = CanvasLayerTransformIdentity();
    else if (overrideTimeline && overrideLayerID.length &&
             [path.layerID isEqualToString:overrideLayerID])
      t = CanvasLayerTransformFromTimeline(overrideTimeline, frac);
    else
      t = CanvasLayerTransformAtFraction(path, frac);
    float cx = (rect.min.x + rect.max.x) * 0.5f;
    float cy = (rect.min.y + rect.max.y) * 0.5f;
    // Compose the layer's full 3D model with each ancestor group's so a parent
    // group moves/scales/spins/tilts its members as a rigid unit. RAW rect-corner
    // verts go to the shader; ALL of scale/rotation(X,Y,Z)/position/perspective
    // live in the matrix so the axes compose correctly even when combined.
    CanvasGroupXform groups[kCanvasGroupXformCap];
    NSInteger ng = CanvasBuildGroupXforms(
        layers, (NSUInteger)i, frac, overrideLayerID, overrideTimeline, groups,
        kCanvasGroupXformCap);
    matrix_float4x4 m = CanvasComposedModelMatrix(t, simd_make_float2(cx, cy),
                                                  groups, ng, scale, tileShift);
    // Group opacity multiplies the member's (a 40% group halves a 50% member).
    float opacity = t.opacity;
    for (NSInteger k = 0; k < ng; k++)
      opacity *= groups[k].t.opacity;
    // 3D centre depth: the layer's own rotation pivots about its centre (so the
    // centre's depth comes from the GROUP's tilt). Use the RAW view-space z
    // (cClip.z, which the perspective passes through unchanged) - comparable
    // across layers, whereas z/w isn't now that camD scales per layer.
    simd_float2 cPx = (simd_make_float2(cx, cy) - half) * scale;
    simd_float4 cClip = simd_mul(m, simd_make_float4(cPx.x, cPx.y, 0.0f, 1.0f));
    float depth = cClip.z;

    items[count].matrix = m;
    items[count].quad[0] =
        (KKVertex2D){(simd_make_float2(rect.max.x, rect.min.y) - half) * scale,
                     {1, 1}};
    items[count].quad[1] =
        (KKVertex2D){(simd_make_float2(rect.min.x, rect.min.y) - half) * scale,
                     {0, 1}};
    items[count].quad[2] =
        (KKVertex2D){(simd_make_float2(rect.max.x, rect.max.y) - half) * scale,
                     {1, 0}};
    items[count].quad[3] =
        (KKVertex2D){(simd_make_float2(rect.min.x, rect.max.y) - half) * scale,
                     {0, 0}};
    items[count].opacity = opacity;
    items[count].tex = tex;
    items[count].depth = depth;
    items[count].order = count;
    count++;
  }

  // Back-to-front by 3D depth so a layer rotated physically in front (e.g. a
  // group tilted past edge-on) draws on top. Equal depth (flat / untilted layers
  // all at z=0) falls back to layer-stack order, so normal 2D stacking is
  // unchanged. Painter's order - correct for the non-intersecting image planes
  // Canvas composites (a depth buffer would be needed for intersecting quads).
  qsort_b(items, (size_t)count, sizeof(CanvasDrawItem),
          ^int(const void *a, const void *b) {
            const CanvasDrawItem *ia = a, *ib = b;
            if (ia->depth > ib->depth)
              return -1;
            if (ia->depth < ib->depth)
              return 1;
            return ia->order < ib->order ? -1 : (ia->order > ib->order ? 1 : 0);
          });

  for (NSInteger j = 0; j < count; j++) {
    CanvasDrawItem *it = &items[j];
    [encoder setVertexBytes:&it->matrix
                     length:sizeof(it->matrix)
                    atIndex:KKVertexInputIndex_Transform];
    [encoder setFragmentBytes:&it->opacity length:sizeof(it->opacity) atIndex:0];
    [encoder setVertexBytes:it->quad
                     length:sizeof(it->quad)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setFragmentTexture:it->tex atIndex:KKTextureIndex_InputImage];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
  }
  free(items);
}
