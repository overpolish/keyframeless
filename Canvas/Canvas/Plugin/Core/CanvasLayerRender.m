/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h"
#import "CanvasCornerFillet.h"
#import "CanvasImageTexture.h"
#import "CanvasLayerTransform.h"
#import "CanvasMarkerTessellate.h"
#import "CanvasPathMorph.h"
#import "CanvasStrokeTessellate.h"
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
    // group moves/scales/spins/tilts its members as a rigid unit. RAW
    // rect-corner verts go to the shader; ALL of
    // scale/rotation(X,Y,Z)/position/perspective live in the matrix so the axes
    // compose correctly even when combined.
    CanvasGroupXform groups[kCanvasGroupXformCap];
    NSInteger ng =
        CanvasBuildGroupXforms(layers, (NSUInteger)i, frac, overrideLayerID,
                               overrideTimeline, groups, kCanvasGroupXformCap);
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
    items[count].quad[0] = (KKVertex2D){
        (simd_make_float2(rect.max.x, rect.min.y) - half) * scale, {1, 1}};
    items[count].quad[1] = (KKVertex2D){
        (simd_make_float2(rect.min.x, rect.min.y) - half) * scale, {0, 1}};
    items[count].quad[2] = (KKVertex2D){
        (simd_make_float2(rect.max.x, rect.max.y) - half) * scale, {1, 0}};
    items[count].quad[3] = (KKVertex2D){
        (simd_make_float2(rect.min.x, rect.max.y) - half) * scale, {0, 0}};
    items[count].opacity = opacity;
    items[count].tex = tex;
    items[count].depth = depth;
    items[count].order = count;
    count++;
  }

  // Back-to-front by 3D depth so a layer rotated physically in front (e.g. a
  // group tilted past edge-on) draws on top. Equal depth (flat / untilted
  // layers all at z=0) falls back to layer-stack order, so normal 2D stacking
  // is unchanged. Painter's order - correct for the non-intersecting image
  // planes Canvas composites (a depth buffer would be needed for intersecting
  // quads).
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
    [encoder setFragmentBytes:&it->opacity
                       length:sizeof(it->opacity)
                      atIndex:0];
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

simd_float2 CanvasLayerObjectCenter(KKBezierPath *path) {
  if (!path || path.isGroup)
    return simd_make_float2(0.5f, 0.5f); // groups pivot on their stored Anchor
  if ([path.shape isKindOfClass:[KKRectShape class]]) {
    KKRectShape *r = (KKRectShape *)path.shape;
    return (r.min + r.max) * 0.5f;
  }
  if ([path.shape isKindOfClass:[KKEllipseShape class]]) {
    KKEllipseShape *e = (KKEllipseShape *)path.shape;
    return (e.min + e.max) * 0.5f;
  }
  if (path.count == 0)
    return simd_make_float2(0.5f, 0.5f);
  KKBezierPoint p0 = [path pointAtIndex:0];
  simd_float2 lo = simd_make_float2(p0.x, p0.y), hi = lo;
  for (NSUInteger i = 1; i < path.count; i++) {
    KKBezierPoint p = [path pointAtIndex:i];
    lo = simd_min(lo, simd_make_float2(p.x, p.y));
    hi = simd_max(hi, simd_make_float2(p.x, p.y));
  }
  return (lo + hi) * 0.5f;
}

// Bake the per-vertex gradient position (0..1) into each strip vertex's
// textureCoordinate.x (unused by the solid path), so KKGradientLineFragment
// just samples the LUT. Both modes pivot on the layer (bbox) centre, like a
// fill gradient: LINEAR runs along the angle and is normalised by the bbox's
// extent IN THAT DIRECTION (so it spans the layer and reaches both end colours
// at any angle, instead of compressing); RADIAL is a circle from the centre
// out, sized to the larger bbox dimension (per-axis d/bbSize collapses on a
// horizontal / vertical line whose bbox is ~0 in one axis). Angle matches the
// circular knob: 0 deg up, 90 right, 180 down -> object-space dir (sin, cos).
// The bbox+angle gradient fill, computed once from the stroke geometry (and,
// when present, the marker geometry so the gradient spans the WHOLE drawn
// shape) and then applied to both the stroke and the marker verts so they share
// one continuous gradient.
typedef struct {
  simd_float2 center, dir;
  float halfExtent, maxDim;
  int type; // cv.gradientType
} CanvasGradientFill;

// `extra` (optional, e.g. the marker verts) extends the bbox so the gradient
// reaches t=0/1 at the outermost drawn point, not just the stroke path's.
static CanvasGradientFill
CanvasComputeGradientFill(KKBezierPath *geom, float imageWidth,
                          float imageHeight, float strokeStart, float strokeEnd,
                          float strokeScale, KKColorLanesValue cv,
                          const KKVertex2D *extra, NSUInteger extraCount) {
  simd_float2 bbMin = simd_make_float2(FLT_MAX, FLT_MAX);
  simd_float2 bbMax = simd_make_float2(-FLT_MAX, -FLT_MAX);
  for (NSUInteger pi = 0; pi < geom.count; pi++) {
    KKBezierPoint pt = [geom pointAtIndex:pi];
    float px = (pt.x - 0.5f) * imageWidth;
    float py = (pt.y - 0.5f) * imageHeight;
    bbMin = simd_make_float2(fminf(bbMin.x, px), fminf(bbMin.y, py));
    bbMax = simd_make_float2(fmaxf(bbMax.x, px), fmaxf(bbMax.y, py));
  }
  float pad = 0.5f * fmaxf(strokeStart, strokeEnd) * strokeScale;
  bbMin -= pad;
  bbMax += pad;
  for (NSUInteger i = 0; i < extraCount; i++) {
    simd_float2 p = extra[i].position;
    bbMin = simd_make_float2(fminf(bbMin.x, p.x), fminf(bbMin.y, p.y));
    bbMax = simd_make_float2(fmaxf(bbMax.x, p.x), fmaxf(bbMax.y, p.y));
  }
  simd_float2 bbCenter = (bbMin + bbMax) * 0.5f;
  simd_float2 bbSize = simd_make_float2(fmaxf(bbMax.x - bbMin.x, 1.0f),
                                        fmaxf(bbMax.y - bbMin.y, 1.0f));
  float th = cv.gradientAngle;
  simd_float2 dir = simd_make_float2(sinf(th), cosf(th));
  CanvasGradientFill g;
  g.center = bbCenter;
  g.dir = dir;
  // Half the bbox extent measured along `dir` (its support function), so the
  // gradient reaches t=0/1 at the bbox edge in the gradient direction.
  g.halfExtent = fmaxf(
      0.5f * bbSize.x * fabsf(dir.x) + 0.5f * bbSize.y * fabsf(dir.y), 1.0e-3f);
  g.maxDim = fmaxf(bbSize.x, bbSize.y);
  g.type = cv.gradientType;
  return g;
}

static void CanvasApplyGradientFill(KKVertex2D *verts, NSUInteger vc,
                                    CanvasGradientFill g) {
  for (NSUInteger vi = 0; vi < vc; vi++) {
    simd_float2 d = verts[vi].position - g.center;
    float gt = (g.type == 1)
                   ? simd_dot(d, g.dir) / (2.0f * g.halfExtent) + 0.5f // linear
                   : 2.0f * simd_length(d) / fmaxf(g.maxDim, 1.0f);    // radial
    gt = gt < 0.0f ? 0.0f : (gt > 1.0f ? 1.0f : gt);
    verts[vi].textureCoordinate.x = gt;
  }
}

// Encode ONE vector layer's stroke (skipping image / group / hidden /
// stroke-off layers via early return). Pulled out of the per-layer loop so
// CanvasEncodeVectorLayers stays a thin walk; the context bundles the shared
// render inputs. The objects are __unsafe_unretained - the struct lives only
// for the synchronous call and the caller retains them throughout.
typedef struct {
  __unsafe_unretained NSArray<KKBezierPath *> *layers;
  __unsafe_unretained id<MTLRenderCommandEncoder> encoder;
  __unsafe_unretained id<MTLDevice> device;
  float imageWidth, imageHeight;
  simd_float2 scale, tileShift;
  double frac;
  __unsafe_unretained NSString *overrideLayerID;
  __unsafe_unretained KKTimeline *overrideTimeline;
  float strokeScale;
  double elapsedSec;
  __unsafe_unretained id<MTLRenderPipelineState> solidPS, gradientPS, dashPS;
} CanvasVectorEncodeCtx;

// One end's resolved marker animation for a NON-offset draw-on reveal. `reveal`
// is how far THIS end is drawn (end side: drawOn.end; start side: 1-drawOn.start
// - so both ends share one symmetric formula). Arrow / Arrowhead (marker 1 / 4)
// RIDE the visible tip pointing in the drawing direction, growing in over their
// footprint as the line leaves the start; the others sit FIXED at the true end
// and animate in from one stroke-width over the reveal tail. `lineBound` is the
// (possibly ramped-to-complete-early) reveal to feed the line for this end (end
// side -> lineEnd; start side -> 1-lineBound).
typedef struct {
  uint8_t marker; // 0 = suppressed
  float sizePx;
  float pullback;
  float trim;      // marker anchor: arc trimmed from this end (0 = true end)
  float lineBound; // reveal to render the line to for this end
} CanvasEndMarkerAnim;

static CanvasEndMarkerAnim CanvasResolveEndMarker(uint8_t marker, float fullPx,
                                                  float fullPullback,
                                                  float reveal, float totalArc,
                                                  float strokeWidthPx,
                                                  float visibleLen) {
  const float kMarkerReveal = 0.15f; // reveal tail a fixed marker grows in over
  CanvasEndMarkerAnim r = {marker, fullPx, fullPullback, 0.0f, reveal};
  if (marker == 0)
    return r;
  if (marker == 1 || marker == 4) { // Arrow / Arrowhead: ride the visible tip
    float window = fmaxf(fullPullback, fullPx);
    float p = window > 0.0f ? fminf(1.0f, visibleLen / window) : 1.0f;
    r.sizePx = fullPx * p;
    r.pullback = fullPullback * p;
    r.trim = (1.0f - reveal) * totalArc; // ride the tip
    if (p <= 0.001f)
      r.marker = 0;
    return r;
  }
  // Circle / Square / Line: fixed at the true end, grow in from 100%.
  float p = fminf(
      1.0f, fmaxf(0.0f, (reveal - (1.0f - kMarkerReveal)) / kMarkerReveal));
  if (p <= 0.001f) {
    r.marker = 0;
    return r;
  }
  r.sizePx = strokeWidthPx + (fullPx - strokeWidthPx) * p; // 100% -> configured
  // Complete the line to the true end over the first half of the tail so the
  // fixed marker sits on the finished tip (identity below the tail = no over-draw).
  r.lineBound = fminf(1.0f, (1.0f - kMarkerReveal) +
                                (reveal - (1.0f - kMarkerReveal)) * 2.0f);
  return r;
}

// Resolved draw-on + endpoint-marker render state for one stroked layer, lifted
// out of CanvasEncodeOneVectorLayer (the most-iterated logic, behind one
// boundary). The line is fed [lineStart, lineEnd] rotated by `offset`; the
// markers their animated size / pullback / trim. `active` gates the dashed/dotted
// draw-on + the cap-headroom bump; `collapsed` (raw span empty) means skip the
// stroke entirely.
typedef struct {
  float lineStart, lineEnd, offset;
  uint8_t startMarker, endMarker;
  float sMarkerPx, eMarkerPx;
  float startPullback, endPullback;
  float markerStartTrim, markerEndTrim;
  BOOL active;
  BOOL collapsed;
} CanvasDrawOnRender;

static CanvasDrawOnRender CanvasResolveStrokeDrawOn(
    KKBezierPath *path, KKBezierPath *geom, double evalFrac,
    NSString *overrideLayerID, KKTimeline *overrideTimeline, float strokeStart,
    float strokeEnd, float strokeScale, float imageWidth, float imageHeight) {
  uint8_t startMarker = 0, endMarker = 0;
  float startMul = path.startMarkerSize, endMul = path.endMarkerSize;
  CanvasStrokeMarkersAtFraction(path, evalFrac, overrideLayerID, overrideTimeline,
                                &startMarker, &endMarker, &startMul, &endMul);
  float sMarkerPxFull = strokeStart * strokeScale * startMul;
  float eMarkerPxFull = strokeEnd * strokeScale * endMul;
  float startPullbackFull =
      startMarker ? CanvasMarkerPullback(startMarker, sMarkerPxFull) : 0.0f;
  float endPullbackFull =
      endMarker ? CanvasMarkerPullback(endMarker, eMarkerPxFull) : 0.0f;
  CanvasStrokeDrawOn drawOn =
      CanvasStrokeDrawOnAtFraction(path, evalFrac, overrideLayerID, overrideTimeline);
  float totalArc = CanvasContourTotalArc(geom, imageWidth, imageHeight);

  CanvasDrawOnRender r = {drawOn.start,    drawOn.end,       drawOn.offset,
                          startMarker,     endMarker,        sMarkerPxFull,
                          eMarkerPxFull,   startPullbackFull, endPullbackFull,
                          0.0f,            0.0f,             NO,
                          NO};
  r.active = totalArc > 0.0f &&
             (drawOn.start > 0.0f || drawOn.end < 1.0f || drawOn.offsetEngaged);
  r.collapsed = totalArc > 0.0f &&
                (drawOn.start + (1.0f - drawOn.end)) * totalArc >= totalArc - 0.5f;

  if (drawOn.offsetEngaged) {
    // An OFFSET spin rotates the visible window around the path: keep the markers
    // on its (shifted) ends, full size, riding the spin - at full reveal too (the
    // cut/seam stays where the offset puts it).
    float L = totalArc;
    float a = drawOn.start * L;
    float visLen = (drawOn.end - drawOn.start) * L;
    if (L > 0.0f && visLen > 0.5f) {
      float winStart = fmodf(drawOn.offset * L + a, L);
      if (winStart < 0.0f)
        winStart += L;
      // endPos uses the SAME wrap decision the stroke tessellator does, so the
      // markers land on the rendered window ends (no mismatch at the wrap or a
      // wrapped-0 full reveal).
      float w1 = winStart + visLen;
      float endPos = (w1 > L + 0.5f) ? (w1 - L) : w1;
      r.markerStartTrim = winStart;
      r.markerEndTrim = fmaxf(0.0f, L - endPos);
      float wsS = fmaxf(sMarkerPxFull, 1.0f);
      float wsE = fmaxf(eMarkerPxFull, 1.0f);
      // GROW-IN as the visible span opens (animate in, not pop) + SEAM smoothing
      // on PARTIAL reveals only (a full reveal's ends sit AT the natural endpoints
      // and must not shrink - that was the flash-disappear).
      float sf = fminf(1.0f, visLen / wsS);
      float ef = fminf(1.0f, visLen / wsE);
      if (visLen < L - 0.5f) {
        sf *= fminf(1.0f, fminf(winStart, L - winStart) / wsS);
        ef *= fminf(1.0f, fminf(endPos, L - endPos) / wsE);
      }
      r.sMarkerPx = sMarkerPxFull * sf;
      r.eMarkerPx = eMarkerPxFull * ef;
      r.startPullback = startPullbackFull * sf;
      r.endPullback = endPullbackFull * ef;
      if (sf <= 0.001f)
        r.startMarker = 0;
      if (ef <= 0.001f)
        r.endMarker = 0;
    } else {
      r.startMarker = 0;
      r.endMarker = 0;
    }
  } else if (r.active) {
    float visibleLen = fmaxf(0.0f, (drawOn.end - drawOn.start) * totalArc);
    CanvasEndMarkerAnim e =
        CanvasResolveEndMarker(endMarker, eMarkerPxFull, endPullbackFull,
                               drawOn.end, totalArc, strokeEnd * strokeScale,
                               visibleLen);
    r.endMarker = e.marker;
    r.eMarkerPx = e.sizePx;
    r.endPullback = e.pullback;
    r.markerEndTrim = e.trim;
    r.lineEnd = e.lineBound;
    CanvasEndMarkerAnim s = CanvasResolveEndMarker(
        startMarker, sMarkerPxFull, startPullbackFull, 1.0f - drawOn.start,
        totalArc, strokeStart * strokeScale, visibleLen);
    r.startMarker = s.marker;
    r.sMarkerPx = s.sizePx;
    r.startPullback = s.pullback;
    r.markerStartTrim = s.trim;
    r.lineStart = 1.0f - s.lineBound;
  }
  return r;
}

static void CanvasEncodeOneVectorLayer(const CanvasVectorEncodeCtx *ctx,
                                       NSInteger i) {
  NSArray<KKBezierPath *> *layers = ctx->layers;
  id<MTLRenderCommandEncoder> encoder = ctx->encoder;
  id<MTLDevice> device = ctx->device;
  float imageWidth = ctx->imageWidth, imageHeight = ctx->imageHeight;
  simd_float2 scale = ctx->scale, tileShift = ctx->tileShift;
  double frac = ctx->frac;
  // Fraction to EVALUATE lanes at (a static preview, frac < 0, reads frame 0).
  // `frac < 0.0` itself stays the static-preview branch test elsewhere.
  double evalFrac = frac < 0.0 ? 0.0 : frac;
  NSString *overrideLayerID = ctx->overrideLayerID;
  KKTimeline *overrideTimeline = ctx->overrideTimeline;
  float strokeScale = ctx->strokeScale;
  double elapsedSec = ctx->elapsedSec;
  id<MTLRenderPipelineState> solidPS = ctx->solidPS,
                             gradientPS = ctx->gradientPS, dashPS = ctx->dashPS;
  KKBezierPath *path = layers[i];
  if (path.isImage || path.isGroup || path.hidden)
    return;
  if (!CanvasStrokeEnabledAtFraction(path, evalFrac, overrideLayerID,
                                     overrideTimeline))
    return;
  // Effective Start/End widths from the Stroke Width lane at this fraction
  // (px), falling back to the flat strokeWidth/endWidth. The stroke tapers
  // Start -> End along each contour; a static preview (frac < 0) reads frac
  // 0.
  float strokeStart = path.strokeWidth;
  float strokeEnd = path.strokeWidth;
  CanvasStrokeWidthAtFraction(path, evalFrac, overrideLayerID, overrideTimeline,
                              &strokeStart, &strokeEnd);
  if (path.count < 2 || (strokeStart <= 0.0f && strokeEnd <= 0.0f))
    return;

  // Geometry AT this fraction: the base points for a constant path, or the
  // interpolated shape between the Points keyposes' snapshots for an animated
  // one. (Static-rect preview, frac < 0, uses the base.)
  KKBezierPath *geom =
      (frac < 0.0) ? path : CanvasPathMorphedAtFraction(path, frac);
  if (geom.count < 2)
    return;
  // Round any per-anchor corners into the display fillet before stroking
  // (aspect-correct; no-op when nothing is rounded).
  if (geom.hasCornerRadii)
    geom = CanvasPathByExpandingCorners(
        geom, imageHeight > 0 ? (float)imageWidth / (float)imageHeight : 1.0f);

  uint8_t lineCap = path.lineCap, lineJoin = path.lineJoin;
  CanvasStrokeCapJoinAtFraction(path, evalFrac, overrideLayerID,
                                overrideTimeline, &lineCap, &lineJoin);
  // Draw-on reveal + endpoint-marker animation (the line shows [lineStart,
  // lineEnd] rotated by offset; the markers ride / grow per type). Nothing
  // visible at this fraction (raw span empty) -> skip the stroke.
  CanvasDrawOnRender dor = CanvasResolveStrokeDrawOn(
      path, geom, evalFrac, overrideLayerID, overrideTimeline, strokeStart,
      strokeEnd, strokeScale, imageWidth, imageHeight);
  if (dor.collapsed)
    return;
  // Dash pattern (Solid / Dashed / Dotted). The dash metrics are absolute px,
  // so they scale with the render like the widths (strokeScale handles the
  // thumbnail downscale).
  CanvasStrokeStyle ss = CanvasStrokeStyleAtFraction(path, evalFrac,
                                                     overrideLayerID,
                                                     overrideTimeline);
  float dashLen = ss.dashLength * strokeScale;
  float dashGap = ss.dashGap * strokeScale;
  float dotGap = ss.dotGap * strokeScale;
  // Dashed (style 1) draws the SOLID stroke geometry (correct corners) and
  // masks the dash pattern by per-vertex arc length in KKStrokeDashFragment, so
  // it needs the dash pipeline + an arc buffer. Falls back to a plain solid
  // stroke if the dash pipeline is unavailable.
  BOOL dashed = (ss.style == 1) && dashPS != nil;
  BOOL dotted = (ss.style == 2);
  NSUInteger cap =
      dotted ? CanvasDottedStrokeVertexCapacity(geom, strokeStart * strokeScale,
                                                dotGap, imageWidth, imageHeight)
             : CanvasStrokeVertexCapacity(geom);
  // A draw-on reveal can cut the contour into two pieces (an offset wrap), each
  // with its own pair of caps - budget two extra round-cap fans beyond the
  // base.
  if (dor.active && !dotted)
    cap += 128;
  if (cap == 0)
    return;
  KKVertex2D *verts = malloc(sizeof(KKVertex2D) * cap);
  float *arc = dashed ? malloc(sizeof(float) * cap) : NULL;
  NSUInteger vc;
  // Marching-ants phase (px): elapsed seconds x speed (cycles/sec) x the
  // pattern's pixel period, so speed = 1 advances one dash/dot per second. A
  // static preview (frac < 0) and zero speed leave it at 0.
  float dotsCycle = strokeStart * strokeScale + dotGap;
  float dashCycle = fmaxf(dashLen + dashGap, 1.0f);
  float dotPhase =
      (frac < 0.0) ? 0.0f : (float)(elapsedSec * ss.marchSpeed) * dotsCycle;
  float dashPhase =
      (frac < 0.0) ? 0.0f : (float)(elapsedSec * ss.marchSpeed) * dashCycle;
  if (dotted) {
    vc = CanvasTessellateDottedStroke(geom, strokeStart * strokeScale,
                                      strokeEnd * strokeScale, imageWidth,
                                      imageHeight, dotGap, dotPhase,
                                      dor.lineStart, dor.lineEnd, dor.offset,
                                      verts, cap);
  } else {
    // Solid + dashed share this strip (dashed masks the pattern in the
    // fragment). Draw-on extracts the visible arc window [Start, End] rotated
    // by Offset for an open OR closed contour, pulling the stroke back behind
    // any endpoint markers. With the defaults (0 / 100 / 0) it emits the whole
    // stroke unchanged.
    vc = CanvasTessellateStrokeDrawOn(
        geom, strokeStart * strokeScale, strokeEnd * strokeScale, imageWidth,
        imageHeight, lineCap, lineJoin, dor.lineStart, dor.lineEnd, dor.offset,
        dor.startPullback, dor.endPullback, verts, cap, arc);
  }
  if (vc < 4) {
    free(verts);
    free(arc);
    return;
  }

  CanvasLayerTransform t;
  if (frac < 0.0)
    t = CanvasLayerTransformIdentity();
  else if (overrideTimeline && overrideLayerID.length &&
           [path.layerID isEqualToString:overrideLayerID])
    t = CanvasLayerTransformFromTimeline(overrideTimeline, frac);
  else
    t = CanvasLayerTransformAtFraction(path, frac);

  CanvasGroupXform groups[kCanvasGroupXformCap];
  NSInteger ng =
      CanvasBuildGroupXforms(layers, (NSUInteger)i, frac, overrideLayerID,
                             overrideTimeline, groups, kCanvasGroupXformCap);
  matrix_float4x4 m = CanvasComposedModelMatrix(
      t, CanvasLayerObjectCenter(geom), groups, ng, scale, tileShift);

  float opacity = t.opacity * path.opacity;
  for (NSInteger k = 0; k < ng; k++)
    opacity *= groups[k].t.opacity;
  // Stroke colour from the shared colour lanes (Solid / Gradient, no
  // Dynamic), falling back to the flat strokeR,G,B.
  KKColorLanesValue cv = CanvasStrokeColorAtFraction(
      path, evalFrac, overrideLayerID, overrideTimeline);
  BOOL useGradient = (cv.mode == KKColorModeGradient) && gradientPS != nil;

  // Tessellate the endpoint markers (from the untrimmed `geom`): they share the
  // stroke's colour + gradient, so they're part of the gradient bbox and baked
  // with the same fill. Open-marker bar thickness = the local stroke width.
  KKVertex2D *mverts = NULL;
  NSUInteger mvc = 0;
  if (dor.startMarker != 0 || dor.endMarker != 0) {
    NSUInteger mcap = CanvasMarkerVertexCapacity();
    mverts = malloc(sizeof(KKVertex2D) * mcap);
    // An Arrow rides its draw-on tip (markerStartTrim / markerEndTrim); other
    // markers stay at the true end (trim 0). Size grows via sMarkerPx /
    // eMarkerPx and the draw-on stroke pulls back under the marker.
    mvc = CanvasTessellateMarkers(
        geom, imageWidth, imageHeight, dor.startMarker, dor.endMarker,
        dor.sMarkerPx, dor.eMarkerPx, strokeStart * strokeScale,
        strokeEnd * strokeScale, dor.markerStartTrim, dor.markerEndTrim, mverts,
        mcap);
  }

  // One continuous gradient over the stroke + markers: compute the fill from
  // both, then bake the stroke and marker verts with it.
  if (useGradient) {
    CanvasGradientFill gfill =
        CanvasComputeGradientFill(geom, imageWidth, imageHeight, strokeStart,
                                  strokeEnd, strokeScale, cv, mverts, mvc);
    CanvasApplyGradientFill(verts, vc, gfill);
    if (mvc >= 3)
      CanvasApplyGradientFill(mverts, mvc, gfill);
  }
  // sRGB -> linear (the render's working space), matching the gradient
  // fragment's pow(2.2). Pure-channel colours are unchanged; midtones darken
  // to their correct linear value so a solid matches the editor + a gradient
  // stop.
  simd_float3 solid = cv.solidColor;
  simd_float4 color = simd_make_float4(powf(solid.x, 2.2f), powf(solid.y, 2.2f),
                                       powf(solid.z, 2.2f), opacity);

  id<MTLRenderPipelineState> ps =
      dashed ? dashPS : (useGradient ? gradientPS : solidPS);
  [encoder setRenderPipelineState:ps];
  [encoder setVertexBytes:&m
                   length:sizeof(m)
                  atIndex:KKVertexInputIndex_Transform];
  // The vertex array goes through an MTLBuffer, not setVertexBytes: a complex
  // path (e.g. an imported SVG) tessellates well past setVertexBytes' 4 KB
  // inline cap, which aborts. (The original Canvas render used a buffer here
  // too; the v3 rewrite regressed it to inline bytes.)
  id<MTLBuffer> vbuf = [device newBufferWithBytes:verts
                                           length:sizeof(KKVertex2D) * vc
                                          options:MTLResourceStorageModeShared];
  [encoder setVertexBuffer:vbuf offset:0 atIndex:KKVertexInputIndex_Vertices];
  if (dashed) {
    // Per-vertex arc length for the dash mask + the dash uniforms (cycle, on
    // length, phase) and the colour (solid or gradient LUT).
    id<MTLBuffer> abuf =
        [device newBufferWithBytes:arc
                            length:sizeof(float) * vc
                           options:MTLResourceStorageModeShared];
    [encoder setVertexBuffer:abuf
                      offset:0
                     atIndex:KKVertexInputIndex_StrokeArc];
    KKStrokeDashParams dp;
    dp.solidColor = color;
    dp.cycle = dashCycle;
    dp.onLength = dashLen;
    dp.phase = dashPhase; // marching-ants animation
    dp.opacity = opacity;
    dp.useGradient = useGradient ? 1 : 0;
    [encoder setFragmentBytes:&dp length:sizeof(dp) atIndex:0];
    if (useGradient)
      [encoder setFragmentBytes:cv.gradientLUT
                         length:sizeof(cv.gradientLUT)
                        atIndex:1];
  } else if (useGradient) {
    [encoder setFragmentBytes:cv.gradientLUT
                       length:sizeof(cv.gradientLUT)
                      atIndex:0];
    [encoder setFragmentBytes:&opacity length:sizeof(opacity) atIndex:1];
  } else {
    [encoder setFragmentBytes:&color length:sizeof(color) atIndex:0];
  }
  // The solid + dashed strokes are one triangle strip (the dash is masked in
  // the fragment); a dotted stroke is a triangle LIST of independent discs.
  [encoder drawPrimitives:(dotted ? MTLPrimitiveTypeTriangle
                                  : MTLPrimitiveTypeTriangleStrip)
              vertexStart:0
              vertexCount:vc];
  free(verts);
  free(arc);

  // Draw the markers (triangle list, on top of the stroke) with the SAME colour
  // treatment as the stroke - the gradient LUT when the stroke is a gradient
  // (coords baked above), else the solid colour. Never dashed. The transform
  // matrix `m` set above is still bound on the encoder.
  if (mvc >= 3) {
    [encoder setRenderPipelineState:(useGradient ? gradientPS : solidPS)];
    id<MTLBuffer> mbuf =
        [device newBufferWithBytes:mverts
                            length:sizeof(KKVertex2D) * mvc
                           options:MTLResourceStorageModeShared];
    [encoder setVertexBuffer:mbuf offset:0 atIndex:KKVertexInputIndex_Vertices];
    if (useGradient) {
      [encoder setFragmentBytes:cv.gradientLUT
                         length:sizeof(cv.gradientLUT)
                        atIndex:0];
      [encoder setFragmentBytes:&opacity length:sizeof(opacity) atIndex:1];
    } else {
      [encoder setFragmentBytes:&color length:sizeof(color) atIndex:0];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:mvc];
  }
  free(mverts);
}

void CanvasEncodeVectorLayers(
    NSArray<KKBezierPath *> *layers, id<MTLRenderCommandEncoder> encoder,
    id<MTLDevice> device, float imageWidth, float imageHeight, float tileShiftX,
    float tileShiftY, double frac, NSString *overrideLayerID,
    KKTimeline *overrideTimeline, float strokeScale, double elapsedSec,
    id<MTLRenderPipelineState> solidPS, id<MTLRenderPipelineState> gradientPS,
    id<MTLRenderPipelineState> dashPS) {
  if (!encoder || !device || layers.count == 0)
    return;
  if (strokeScale <= 0.0f)
    strokeScale = 1.0f;
  simd_float2 scale = simd_make_float2(imageWidth, imageHeight);
  simd_float2 tileShift = simd_make_float2(tileShiftX, tileShiftY);

  // Bottom-first (array index 0 = topmost, drawn last) so vector layers stack
  // like the image pass. No depth sort yet - strokes draw after the images.
  CanvasVectorEncodeCtx ctx = {
      .layers = layers,
      .encoder = encoder,
      .device = device,
      .imageWidth = imageWidth,
      .imageHeight = imageHeight,
      .scale = scale,
      .tileShift = tileShift,
      .frac = frac,
      .overrideLayerID = overrideLayerID,
      .overrideTimeline = overrideTimeline,
      .strokeScale = strokeScale,
      .elapsedSec = elapsedSec,
      .solidPS = solidPS,
      .gradientPS = gradientPS,
      .dashPS = dashPS,
  };
  for (NSInteger i = (NSInteger)layers.count - 1; i >= 0; i--)
    CanvasEncodeOneVectorLayer(&ctx, i);
}

simd_float3x3 CanvasSquareToQuadHomography(CGPoint p0, CGPoint p1, CGPoint p2,
                                           CGPoint p3) {
  double dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x;
  double dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y;
  double a, b, c, d, e, f, g, h;
  if (fabs(dx3) < 1e-9 && fabs(dy3) < 1e-9) {
    // Parallelogram = affine, no perspective term.
    a = p1.x - p0.x;
    b = p2.x - p1.x;
    c = p0.x;
    d = p1.y - p0.y;
    e = p2.y - p1.y;
    f = p0.y;
    g = 0;
    h = 0;
  } else {
    double den = dx1 * dy2 - dx2 * dy1;
    if (fabs(den) < 1e-12)
      return matrix_identity_float3x3; // degenerate, don't blow up
    g = (dx3 * dy2 - dx2 * dy3) / den;
    h = (dx1 * dy3 - dx3 * dy1) / den;
    a = p1.x - p0.x + g * p1.x;
    b = p3.x - p0.x + h * p3.x;
    c = p0.x;
    d = p1.y - p0.y + g * p1.y;
    e = p3.y - p0.y + h * p3.y;
    f = p0.y;
  }
  return simd_matrix(simd_make_float3((float)a, (float)d, (float)g),
                     simd_make_float3((float)b, (float)e, (float)h),
                     simd_make_float3((float)c, (float)f, 1.0f));
}
