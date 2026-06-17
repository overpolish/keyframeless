/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h"
#import "CanvasImageTexture.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KKShape.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <simd/simd.h>

// A layer's transform at a clip fraction, in normalised object space. Composed
// about the layer's own centre as Scale -> Rotate -> (Position offset), so the
// pieces stack the way a 2D affine does: adding Rotation later is just feeding
// `rotation`, and a parent group's transform would pre-multiply this. The kit
// vertex shader takes raw pixel-space verts (no matrix uniform), so we apply
// the affine to the four corners on the CPU.
typedef struct {
  float scaleX, scaleY; // 1.0 = 100%
  float rotation;       // radians, CCW; 0 = none (no Rotation lane yet)
  float posX, posY;     // normalised, 0.5 = no offset
} CanvasLayerTransform;

static CanvasLayerTransform CanvasLayerTransformIdentity(void) {
  return (CanvasLayerTransform){1.0f, 1.0f, 0.0f, 0.5f, 0.5f};
}

// A layer's transform from an in-memory timeline (the popover's live-edited
// copy, so a mini-viewer handle drag previews before it persists), shared by
// the path-backed reader below.
static CanvasLayerTransform CanvasLayerTransformFromTimeline(KKTimeline *tl,
                                                             double frac) {
  CanvasLayerTransform t = CanvasLayerTransformIdentity();
  for (KKLane *lane in tl.lanes) {
    if ([lane.label isEqualToString:@"Scale"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      // Overshoot/elastic easing can dip scale below 0; clamp rather than flip.
      if (v.count > 0)
        t.scaleX = (float)(fmax(0.0, v[0].doubleValue) / 100.0);
      if (v.count > 1)
        t.scaleY = (float)(fmax(0.0, v[1].doubleValue) / 100.0);
    } else if ([lane.label isEqualToString:@"Position"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        t.posX = (float)v[0].doubleValue;
      if (v.count > 1)
        t.posY = (float)v[1].doubleValue;
    }
    // Rotation lane slots in here once the template exists:
    //   t.rotation = (float)(degrees * M_PI / 180.0);
  }
  return t;
}

static CanvasLayerTransform CanvasLayerTransformAtFraction(KKBezierPath *path,
                                                           double frac) {
  if (path.animationJSON.length == 0)
    return CanvasLayerTransformIdentity();
  return CanvasLayerTransformFromTimeline(
      [KKTimeline timelineFromJSON:path.animationJSON], frac);
}

// Map a normalised object-space corner through the layer's transform: scale,
// then rotate, about the pivot (cx,cy), then offset by Position. Returns the
// transformed point still in normalised object space.
static simd_float2 CanvasTransformCorner(float nx, float ny,
                                         CanvasLayerTransform t, float cx,
                                         float cy) {
  float x = (nx - cx) * t.scaleX;
  float y = (ny - cy) * t.scaleY;
  if (t.rotation != 0.0f) {
    float cs = cosf(t.rotation), sn = sinf(t.rotation);
    float rx = x * cs - y * sn;
    float ry = x * sn + y * cs;
    x = rx;
    y = ry;
  }
  x += cx + (t.posX - 0.5f);
  // Position is authored in the kit's Y-DOWN convention (the mini-viewer
  // overlay + the viewer Position OSC both treat posY=0 as the top), but our
  // object space is Y-UP (Y=0 at the bottom), so the Y offset flips sign -
  // otherwise dragging the handle up moves the layer down. X agrees (rightward
  // in both).
  y += cy - (t.posY - 0.5f);
  return simd_make_float2(x, y);
}

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

void CanvasEncodeImageLayers(
    NSArray<KKBezierPath *> *layers, id<MTLRenderCommandEncoder> encoder,
    id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *cache, float outputWidth,
    float outputHeight, double frac, NSString *overrideLayerID,
    KKTimeline *overrideTimeline) {
  if (!encoder || !device)
    return;
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
    // Negative frac = caller wants the static rect (no transform). Transform
    // all four corners about the layer's own centre so a future rotation keeps
    // the quad rigid (axis-aligned scalars couldn't express it). The selected
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
    simd_float2 br = CanvasTransformCorner(rect.max.x, rect.min.y, t, cx, cy);
    simd_float2 bl = CanvasTransformCorner(rect.min.x, rect.min.y, t, cx, cy);
    simd_float2 tr = CanvasTransformCorner(rect.max.x, rect.max.y, t, cx, cy);
    simd_float2 tl = CanvasTransformCorner(rect.min.x, rect.max.y, t, cx, cy);
    // Object space (0..1, centred at 0.5) -> pixel space across the output.
    simd_float2 scale = simd_make_float2(outputWidth, outputHeight);
    simd_float2 half = simd_make_float2(0.5f, 0.5f);
    br = (br - half) * scale;
    bl = (bl - half) * scale;
    tr = (tr - half) * scale;
    tl = (tl - half) * scale;

    KKVertex2D quad[4] = {
        {br, {1, 1}},
        {bl, {0, 1}},
        {tr, {1, 0}},
        {tl, {0, 0}},
    };
    [encoder setVertexBytes:quad
                     length:sizeof(quad)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setFragmentTexture:tex atIndex:KKTextureIndex_InputImage];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
  }
}
