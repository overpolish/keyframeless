/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h"
#import "CanvasImageTexture.h"
#import "CanvasLayerTimeline.h"
#import "Constants.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKPluginHost.h>
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
// and Position are already baked into the CPU corner verts (in full-IMAGE
// centered-pixel space); this adds only the X/Y tilt and a perspective
// projection ABOUT THE LAYER CENTRE (not the image centre), plus a final TILE
// shift that repositions the image-space result into the current render tile.
// Centring the perspective on the layer (Tneg -> rotate -> P -> Tpos) keeps a
// tilted layer's foreshortening LOCKED as it's dragged around: the layer is its
// own vanishing point, so its appearance doesn't change with screen position
// (matches Magic Move). Tpos sits AFTER P, so it's a post-divide screen offset
// (like Tshift) - it never re-introduces a position-dependent foreshortening.
// rotX=rotY=0 + shift=0 gives a pure perspective matrix == orthographic at z=0.
// `centerPx` is the layer centre in image-centered-pixel space; W,H the image
// dims; `tileShift` the image->tile pixel offset.
static matrix_float4x4 CanvasLayerTiltMatrix(CanvasLayerTransform t,
                                             simd_float2 centerPx, float W,
                                             float H, simd_float2 tileShift) {
  // Camera at distance camD on +Z: (x,y,z,1) -> (camD x, camD y, z, z + camD);
  // after the perspective divide, foreshortening scales by camD/(z + camD).
  float camD = fmaxf(W, H);
  matrix_float4x4 P = simd_matrix(
      simd_make_float4(camD, 0, 0, 0), simd_make_float4(0, camD, 0, 0),
      simd_make_float4(0, 0, 1, 1), simd_make_float4(0, 0, 0, camD));
  // Tile shift OUTSIDE the perspective (homogeneous translate by shift*w) =
  // constant post-divide screen offset, so it doesn't move the vanishing point.
  matrix_float4x4 Tshift =
      simd_matrix(simd_make_float4(1, 0, 0, 0), simd_make_float4(0, 1, 0, 0),
                  simd_make_float4(0, 0, 1, 0),
                  simd_make_float4(tileShift.x, tileShift.y, 0, 1));
  matrix_float4x4 PS = simd_mul(Tshift, P); // Tshift · P
  if (t.rotX == 0.0f && t.rotY == 0.0f)
    return PS; // no tilt: perspective (ortho at z=0) + tile shift
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
  // Tpos · P · Ry · Rx · Tneg: translate the layer centre to the origin, tilt,
  // project (perspective now about the layer centre), translate back as a
  // post-divide screen offset. Tshift then nudges into the render tile.
  matrix_float4x4 R = simd_mul(Ry, Rx);
  matrix_float4x4 model = simd_mul(Tpos, simd_mul(P, simd_mul(R, Tneg)));
  return simd_mul(Tshift, model); // Tshift · Tpos · P · R · Tneg
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

void CanvasEncodeImageLayers(
    NSArray<KKBezierPath *> *layers, id<MTLRenderCommandEncoder> encoder,
    id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *cache, float imageWidth,
    float imageHeight, float tileShiftX, float tileShiftY, double frac,
    NSString *overrideLayerID, KKTimeline *overrideTimeline) {
  if (!encoder || !device)
    return;
  simd_float2 tileShift = simd_make_float2(tileShiftX, tileShiftY);
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
    float aspect = (imageHeight > 0.0f) ? (imageWidth / imageHeight) : 1.0f;
    simd_float2 br =
        CanvasTransformCorner(rect.max.x, rect.min.y, t, cx, cy, aspect);
    simd_float2 bl =
        CanvasTransformCorner(rect.min.x, rect.min.y, t, cx, cy, aspect);
    simd_float2 tr =
        CanvasTransformCorner(rect.max.x, rect.max.y, t, cx, cy, aspect);
    simd_float2 tl =
        CanvasTransformCorner(rect.min.x, rect.max.y, t, cx, cy, aspect);
    // Object space (0..1, centred at 0.5) -> full-IMAGE centered-pixel space.
    // The tile shift (into the render tile) is applied in the tilt matrix.
    simd_float2 scale = simd_make_float2(imageWidth, imageHeight);
    simd_float2 half = simd_make_float2(0.5f, 0.5f);
    br = (br - half) * scale;
    bl = (bl - half) * scale;
    tr = (tr - half) * scale;
    tl = (tl - half) * scale;
    // X/Y tilt + perspective + tile shift applied in the vertex shader about
    // the layer centre (the 2D scale/Z/position are already baked into the
    // verts).
    simd_float2 centerPx =
        (CanvasTransformCorner(cx, cy, t, cx, cy, aspect) - half) * scale;
    matrix_float4x4 tilt =
        CanvasLayerTiltMatrix(t, centerPx, imageWidth, imageHeight, tileShift);

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

// A layer's on-screen quad corner in object space [0,1] (Y-up), through the
// SAME pipeline the render uses: the 2D affine baked by CanvasTransformCorner,
// then the X/Y tilt + perspective matrix, then the perspective divide. The
// pipeline is scale-invariant in object space (scaling W,H scales the verts and
// camD together, cancelling in the final divide-and-renormalise), so we feed a
// nominal pixel scale of (aspect, 1) and only the canvas aspect matters - no
// need for the render's true pixel dimensions. tileShift is 0 (the viewer OSC
// isn't tiled like the render).
static simd_float2 CanvasProjectedCornerObj(float nx, float ny,
                                            CanvasLayerTransform t, float cx,
                                            float cy, float aspect) {
  simd_float2 scl = simd_make_float2(aspect > 0.0f ? aspect : 1.0f, 1.0f);
  simd_float2 half = simd_make_float2(0.5f, 0.5f);
  simd_float2 corner2D = CanvasTransformCorner(nx, ny, t, cx, cy, aspect);
  if (t.rotX == 0.0f && t.rotY == 0.0f)
    return corner2D; // no tilt: the tilt matrix is identity at z=0
  simd_float2 pPix = (corner2D - half) * scl;
  simd_float2 centerPx =
      (CanvasTransformCorner(cx, cy, t, cx, cy, aspect) - half) * scl;
  matrix_float4x4 m =
      CanvasLayerTiltMatrix(t, centerPx, scl.x, scl.y, simd_make_float2(0, 0));
  simd_float4 clip = simd_mul(m, simd_make_float4(pPix.x, pPix.y, 0.0f, 1.0f));
  if (clip.w == 0.0f)
    return corner2D;
  simd_float2 screen = simd_make_float2(clip.x / clip.w, clip.y / clip.w);
  return screen / scl + half;
}

static float CanvasCross2(simd_float2 a, simd_float2 b) {
  return a.x * b.y - a.y * b.x;
}

// Inverse bilinear: where is p inside the quad whose corners map to UV
// a=(0,0) b=(1,0) c=(1,1) d=(0,1)? Returns NO when p is outside (u or v beyond
// [0,1]). Standard Inigo-Quilez solution; handles the parallelogram (k2~0)
// degenerate case linearly. Under perspective this is the bilinear
// approximation of the projective UV - precise enough for alpha hit-testing.
static BOOL CanvasInvBilinear(simd_float2 p, simd_float2 a, simd_float2 b,
                              simd_float2 c, simd_float2 d,
                              simd_float2 *outUV) {
  simd_float2 e = b - a;
  simd_float2 f = d - a;
  simd_float2 g = (a - b) + (c - d);
  simd_float2 h = p - a;
  float k2 = CanvasCross2(g, f);
  float k1 = CanvasCross2(e, f) + CanvasCross2(h, g);
  float k0 = CanvasCross2(h, e);
  float u, v;
  // Solve e.x+g.x*v (or the y row if that's degenerate) for u given v.
  float (^uForV)(float) = ^float(float vv) {
    float dux = e.x + g.x * vv;
    if (fabsf(dux) > 1e-9f)
      return (h.x - f.x * vv) / dux;
    float duy = e.y + g.y * vv;
    if (fabsf(duy) > 1e-9f)
      return (h.y - f.y * vv) / duy;
    return -1.0f;
  };
  if (fabsf(k2) < 1e-9f) {
    if (fabsf(k1) < 1e-12f)
      return NO;
    v = -k0 / k1;
    u = uForV(v);
  } else {
    float w = k1 * k1 - 4.0f * k0 * k2;
    if (w < 0.0f)
      return NO;
    w = sqrtf(w);
    float vA = (-k1 - w) / (2.0f * k2);
    float uA = uForV(vA);
    if (vA < 0.0f || vA > 1.0f || uA < 0.0f || uA > 1.0f) {
      float vB = (-k1 + w) / (2.0f * k2);
      v = vB;
      u = uForV(vB);
    } else {
      v = vA;
      u = uA;
    }
  }
  if (u < 0.0f || u > 1.0f || v < 0.0f || v > 1.0f)
    return NO;
  *outUV = simd_make_float2(u, v);
  return YES;
}

// CPU alpha mask for an image path: an upright (row 0 = image TOP) 8-bit
// alpha-only buffer, capped to keep memory + decode cheap. Cached per path
// (this runs in the OSC process; a plain static is fine). u in [0,1] = left to
// right, v in [0,1] = top to bottom (matching the render's UVs). Returns 1.0
// (opaque) when the image has no decodable alpha, so opaque formats (JPEG) hit
// across their whole quad.
@interface _CanvasAlphaMask : NSObject
@property(nonatomic) NSInteger w;
@property(nonatomic) NSInteger h;
@property(nonatomic, strong) NSData *bytes;
@end
@implementation _CanvasAlphaMask
@end

static float CanvasSampleImageAlpha(NSString *imagePath, float u, float v) {
  static NSMutableDictionary<NSString *, _CanvasAlphaMask *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
  });
  _CanvasAlphaMask *mask = cache[imagePath];
  if (!mask) {
    mask =
        [_CanvasAlphaMask new]; // cache misses too (w=0) so we don't re-decode
    cache[imagePath] = mask;
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:imagePath];
    CGImageRef cg =
        img ? [img CGImageForProposedRect:NULL context:nil hints:nil] : NULL;
    if (cg) {
      NSInteger iw = (NSInteger)CGImageGetWidth(cg);
      NSInteger ih = (NSInteger)CGImageGetHeight(cg);
      const NSInteger cap = 512;
      double s = fmin(1.0, (double)cap / (double)MAX(MAX(iw, ih), 1));
      NSInteger w = MAX(1, (NSInteger)(iw * s));
      NSInteger h = MAX(1, (NSInteger)(ih * s));
      NSMutableData *buf = [NSMutableData dataWithLength:(NSUInteger)(w * h)];
      CGContextRef ctx = CGBitmapContextCreate(
          buf.mutableBytes, w, h, 8, w, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
      if (ctx) {
        // Flip so byte row 0 = image TOP (v=0), matching the render's UV.
        CGContextTranslateCTM(ctx, 0, h);
        CGContextScaleCTM(ctx, 1, -1);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        CGContextRelease(ctx);
        mask.w = w;
        mask.h = h;
        mask.bytes = buf;
      }
    }
  }
  if (mask.w == 0 || !mask.bytes)
    return 1.0f;
  float uu = fminf(fmaxf(u, 0.0f), 1.0f);
  float vv = fminf(fmaxf(v, 0.0f), 1.0f);
  NSInteger x = (NSInteger)(uu * (mask.w - 1));
  NSInteger y = (NSInteger)(vv * (mask.h - 1));
  const uint8_t *p = (const uint8_t *)mask.bytes.bytes;
  return p[y * mask.w + x] / 255.0f;
}

// YES if `path` is editable at clip fraction `frac`: it has at least one
// constant param (per `templates`) OR an animated lane visible at `frac` (at a
// keypose or its lead-in/out hold). Used to gate the viewer auto-select so a
// fully-animated layer with no keypose at the playhead isn't pickable.
static BOOL CanvasLayerEditableAtFraction(KKBezierPath *path, double frac,
                                          NSArray<KKLane *> *templates) {
  if (CanvasLayerHasConstant(path, templates))
    return YES;
  if (path.animationJSON.length == 0)
    return YES;
  KKTimeline *tl = [KKTimeline timelineFromJSON:path.animationJSON];
  double frameDur = KKProcessFrameDurationSeconds();
  for (KKLane *l in tl.lanes)
    if (l.enabled && KKLaneVisibleAtFraction(l, frac, frameDur))
      return YES;
  return NO;
}

NSString *CanvasHitTestLayerID(NSArray<KKBezierPath *> *layers, double frac,
                               float aspect, float objX, float objY,
                               BOOL alphaAware,
                               NSSet<NSString *> *excludedLayerIDs,
                               BOOL requireEditableAtFrac,
                               NSArray<KKLane *> *templates) {
  simd_float2 q = simd_make_float2(objX, objY);
  for (NSInteger i = 0; i < (NSInteger)layers.count; i++) { // 0 = topmost
    KKBezierPath *path = layers[i];
    if (!path.isImage || path.hidden || path.isGroup || path.locked ||
        !path.imagePath.length)
      continue;
    if (![path.shape isKindOfClass:[KKRectShape class]])
      continue;
    if (path.layerID && [excludedLayerIDs containsObject:path.layerID])
      continue; // non-selectable (mirrors the layer list's gating)
    if (requireEditableAtFrac && frac >= 0.0 &&
        !CanvasLayerEditableAtFraction(path, frac, templates))
      continue; // viewer: nothing to edit here (animated, off-keypose)
    KKRectShape *rect = (KKRectShape *)path.shape;
    CanvasLayerTransform t = (frac < 0.0)
                                 ? CanvasLayerTransformIdentity()
                                 : CanvasLayerTransformAtFraction(path, frac);
    float cx = (rect.min.x + rect.max.x) * 0.5f;
    float cy = (rect.min.y + rect.max.y) * 0.5f;
    // Corner -> UV: tl=(0,0) tr=(1,0) br=(1,1) bl=(0,1). Object Y-up, so the
    // image TOP is at max.y (v=0) and the bottom at min.y (v=1).
    simd_float2 tl =
        CanvasProjectedCornerObj(rect.min.x, rect.max.y, t, cx, cy, aspect);
    simd_float2 tr =
        CanvasProjectedCornerObj(rect.max.x, rect.max.y, t, cx, cy, aspect);
    simd_float2 br =
        CanvasProjectedCornerObj(rect.max.x, rect.min.y, t, cx, cy, aspect);
    simd_float2 bl =
        CanvasProjectedCornerObj(rect.min.x, rect.min.y, t, cx, cy, aspect);
    simd_float2 uv;
    if (!CanvasInvBilinear(q, tl, tr, br, bl, &uv))
      continue; // outside the transformed quad
    if (alphaAware &&
        CanvasSampleImageAlpha(path.imagePath, uv.x, uv.y) <= 0.04f)
      continue; // transparent here -> fall through to the layer beneath
    return path.layerID;
  }
  return nil;
}
