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
  float rotation;       // Z radians, CCW; the in-plane spin (applied 2D on CPU)
  float posX, posY;     // normalised, 0.5 = no offset
  float rotX, rotY;     // X/Y tilt radians, applied via the perspective matrix
  float opacity; // 0..1, 1 = fully opaque (multiplies premultiplied RGBA)
} CanvasLayerTransform;

static CanvasLayerTransform CanvasLayerTransformIdentity(void) {
  return (CanvasLayerTransform){1.0f, 1.0f, 0.0f, 0.5f, 0.5f, 0.0f, 0.0f, 1.0f};
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
    } else if ([lane.label isEqualToString:@"Rotation"]) {
      // 3-axis Euler [X,Y,Z]°. Z (in-plane spin) is applied on the CPU in the
      // corner affine; X/Y tilt is applied via the perspective matrix in the
      // vertex shader (see CanvasLayerTiltMatrix).
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      const double kDegToRad = M_PI / 180.0;
      if (v.count > 0)
        t.rotX = (float)(v[0].doubleValue * kDegToRad);
      if (v.count > 1)
        t.rotY = (float)(v[1].doubleValue * kDegToRad);
      if (v.count > 2)
        t.rotation = (float)(v[2].doubleValue * kDegToRad);
    } else if ([lane.label isEqualToString:@"Opacity"]) {
      NSArray<NSNumber *> *v =
          KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
      if (v.count > 0)
        t.opacity = (float)(fmax(0.0, fmin(100.0, v[0].doubleValue)) / 100.0);
    }
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
// transformed point still in normalised object space. `aspect` is the canvas
// pixel aspect (outputWidth/outputHeight): object space is 0..1 in both axes
// but the canvas is W:H pixels, so the rotation must run in PIXEL space (scale
// x by aspect, rotate, unscale) or a Z-spin shears the layer by the aspect.
static simd_float2 CanvasTransformCorner(float nx, float ny,
                                         CanvasLayerTransform t, float cx,
                                         float cy, float aspect) {
  float x = (nx - cx) * t.scaleX;
  float y = (ny - cy) * t.scaleY;
  if (t.rotation != 0.0f) {
    float cs = cosf(t.rotation), sn = sinf(t.rotation);
    float a = (aspect > 0.0f) ? aspect : 1.0f;
    float rx = x * cs - y * sn / a;
    float ry = x * a * sn + y * cs;
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

// Per-layer forward transform fed to KKTransformVertexShader. Scale, Z-rotation
// and Position are already baked into the CPU corner verts; this adds only the
// X/Y tilt (about the layer centre) and a perspective projection (about the
// screen centre), so a layer with rotX=rotY=0 gets a pure perspective matrix
// that reproduces the orthographic 2D result at z=0. Composition is Ry*Rx with
// Z innermost (on the verts) to match the rotation OSC's Ry*Rx*Rz pose.
// `centerPx` is the layer centre in centered-pixel space; W,H the output dims.
static matrix_float4x4 CanvasLayerTiltMatrix(CanvasLayerTransform t,
                                             simd_float2 centerPx, float W,
                                             float H) {
  // Camera at distance camD on +Z: (x,y,z,1) -> (camD x, camD y, z, z + camD);
  // after the perspective divide, foreshortening scales by camD/(z + camD).
  float camD = fmaxf(W, H);
  matrix_float4x4 P = simd_matrix(
      simd_make_float4(camD, 0, 0, 0), simd_make_float4(0, camD, 0, 0),
      simd_make_float4(0, 0, 1, 1), simd_make_float4(0, 0, 0, camD));
  if (t.rotX == 0.0f && t.rotY == 0.0f)
    return P; // no tilt: pure perspective is orthographic at z=0
  float cx = cosf(t.rotX), sx = sinf(t.rotX);
  float cy = cosf(t.rotY), sy = sinf(t.rotY);
  matrix_float4x4 Rx = simd_matrix(
      simd_make_float4(1, 0, 0, 0), simd_make_float4(0, cx, sx, 0),
      simd_make_float4(0, -sx, cx, 0), simd_make_float4(0, 0, 0, 1));
  matrix_float4x4 Ry =
      simd_matrix(simd_make_float4(cy, 0, -sy, 0), simd_make_float4(0, 1, 0, 0),
                  simd_make_float4(sy, 0, cy, 0), simd_make_float4(0, 0, 0, 1));
  matrix_float4x4 Tneg =
      simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0),
                  simd_make_float4(0, 0, 1, 0),
                  simd_make_float4(-centerPx.x, -centerPx.y, 0, 1));
  matrix_float4x4 Tpos =
      simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0),
                  simd_make_float4(0, 0, 1, 0),
                  simd_make_float4(centerPx.x, centerPx.y, 0, 1));
  matrix_float4x4 model = simd_mul(Tpos, simd_mul(Ry, simd_mul(Rx, Tneg)));
  return simd_mul(P, model);
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
    float aspect = (outputHeight > 0.0f) ? (outputWidth / outputHeight) : 1.0f;
    simd_float2 br =
        CanvasTransformCorner(rect.max.x, rect.min.y, t, cx, cy, aspect);
    simd_float2 bl =
        CanvasTransformCorner(rect.min.x, rect.min.y, t, cx, cy, aspect);
    simd_float2 tr =
        CanvasTransformCorner(rect.max.x, rect.max.y, t, cx, cy, aspect);
    simd_float2 tl =
        CanvasTransformCorner(rect.min.x, rect.max.y, t, cx, cy, aspect);
    // Object space (0..1, centred at 0.5) -> pixel space across the output.
    simd_float2 scale = simd_make_float2(outputWidth, outputHeight);
    simd_float2 half = simd_make_float2(0.5f, 0.5f);
    br = (br - half) * scale;
    bl = (bl - half) * scale;
    tr = (tr - half) * scale;
    tl = (tl - half) * scale;
    // X/Y tilt + perspective is applied in the vertex shader about the layer
    // centre (the 2D scale/Z/position are already baked into the verts above).
    simd_float2 centerPx =
        (CanvasTransformCorner(cx, cy, t, cx, cy, aspect) - half) * scale;
    matrix_float4x4 tilt =
        CanvasLayerTiltMatrix(t, centerPx, outputWidth, outputHeight);

    KKVertex2D quad[4] = {
        {br, {1, 1}},
        {bl, {0, 1}},
        {tr, {1, 0}},
        {tl, {0, 0}},
    };
    [encoder setVertexBytes:&tilt
                     length:sizeof(tilt)
                    atIndex:KKVertexInputIndex_Transform];
    float opacity = t.opacity;
    [encoder setFragmentBytes:&opacity length:sizeof(opacity) atIndex:0];
    [encoder setVertexBytes:quad
                     length:sizeof(quad)
                    atIndex:KKVertexInputIndex_Vertices];
    [encoder setFragmentTexture:tex atIndex:KKTextureIndex_InputImage];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
  }
}
