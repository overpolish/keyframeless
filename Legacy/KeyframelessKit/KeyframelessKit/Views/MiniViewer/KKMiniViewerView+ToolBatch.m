/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerView_Private.h"
#import "KKOSCShaderTypes.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKShaderTypes.h>
#import <simd/simd.h>

// Tool-overlay primitive batch. A plugin that draws a busy path-edit OSC
// (hundreds of anchors + tangent handles) used to issue one drawPrimitives per
// dot and per handle line - each with its own pipeline-state switch + uniform
// upload - so a 50-anchor path fired ~350 draws every pan/zoom tick and the
// mini went sluggish. Instead, while a batch is armed, every dot / line is
// accumulated into a per-colour vertex bucket and the whole bucket flushes as a
// single draw, collapsing those hundreds of calls into one per (primitive,
// colour). Order-sensitive primitives (rings, fill textures) flush the pending
// buckets first so the z-order is preserved.
typedef struct {
  simd_float4 color;
  KKVertex2D *verts;
  NSUInteger count;
  NSUInteger cap;
} KKToolBucket;

typedef struct {
  KKToolBucket *dots; // point-pipeline buckets, one per fill colour
  NSUInteger dotCount, dotCap;
  KKToolBucket *lines; // aa-line-pipeline buckets, one per colour
  NSUInteger lineCount, lineCap;
} KKToolBatch;

static KKToolBucket *KKToolBucketFor(KKToolBucket **arr, NSUInteger *count,
                                     NSUInteger *cap, simd_float4 color) {
  for (NSUInteger i = 0; i < *count; i++)
    if (simd_all((*arr)[i].color == color))
      return &(*arr)[i];
  if (*count == *cap) {
    *cap = *cap ? *cap * 2 : 4;
    *arr = realloc(*arr, sizeof(KKToolBucket) * (*cap));
  }
  KKToolBucket *b = &(*arr)[(*count)++];
  b->color = color;
  b->verts = NULL;
  b->count = 0;
  b->cap = 0;
  return b;
}

static void KKToolBucketAppend(KKToolBucket *b, const KKVertex2D *v,
                               NSUInteger n) {
  if (b->count + n > b->cap) {
    NSUInteger nc = b->cap ? b->cap * 2 : 64;
    while (nc < b->count + n)
      nc *= 2;
    b->verts = realloc(b->verts, sizeof(KKVertex2D) * nc);
    b->cap = nc;
  }
  memcpy(b->verts + b->count, v, sizeof(KKVertex2D) * n);
  b->count += n;
}

// The public tool-draw surface. Implemented in its own (ToolDraw) category so
// it matches the public (ToolDraw) interface (the internal (Draw) category is
// declared in the private header) - otherwise clang rolls these onto the
// primary class and warns about the category implementing the primary's
// methods.
@implementation KKMiniViewerView (ToolDraw)

- (void)encodeToolDotAtPoint:(CGPoint)viewPoint
                        fill:(simd_float4)fill
                   sizeScale:(CGFloat)sizeScale {
  if (!_toolEncoder || !_pointPipeline)
    return;
  if (_toolBatch) {
    KKVertex2D quad[6];
    [self _toolDotQuad:quad atCenter:viewPoint sizeScale:sizeScale];
    KKToolBatch *b = (KKToolBatch *)_toolBatch;
    KKToolBucketAppend(
        KKToolBucketFor(&b->dots, &b->dotCount, &b->dotCap, fill), quad, 6);
    return;
  }
  [self _encodeHandleGlyphAt:viewPoint
                   fillColor:fill
                   sizeScale:sizeScale
                     encoder:_toolEncoder];
}

- (void)encodeToolLineStrip:(NSArray<NSValue *> *)viewPoints
                      color:(simd_float4)color
                halfWidthPt:(CGFloat)halfWidthPt {
  NSUInteger n = viewPoints.count;
  if (n < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * n);
  for (NSUInteger i = 0; i < n; i++)
    pts[i] = viewPoints[i].pointValue;
  [self encodeToolLineStripPoints:pts
                            count:n
                            color:color
                      halfWidthPt:halfWidthPt];
  free(pts);
}

- (void)encodeToolLineStripPoints:(const CGPoint *)points
                            count:(NSUInteger)count
                            color:(simd_float4)color
                      halfWidthPt:(CGFloat)halfWidthPt {
  if (!_toolEncoder || !_linePipeline || count < 2 || !points)
    return;
  if (_toolBatch) {
    KKVertex2D *tmp = malloc(sizeof(KKVertex2D) * (count - 1) * 6);
    NSUInteger vi = [self _toolLineVerts:tmp
                                  points:points
                                   count:count
                             halfWidthPt:halfWidthPt];
    if (vi > 0) {
      KKToolBatch *b = (KKToolBatch *)_toolBatch;
      KKToolBucketAppend(
          KKToolBucketFor(&b->lines, &b->lineCount, &b->lineCap, color), tmp,
          vi);
    }
    free(tmp);
    return;
  }
  // Immediate (unbatched) path: build the verts once and draw them.
  id<MTLRenderCommandEncoder> enc = _toolEncoder;
  if (!_aaLinePipeline)
    return;
  KKVertex2D *verts = malloc(sizeof(KKVertex2D) * (count - 1) * 6);
  NSUInteger vi = [self _toolLineVerts:verts
                                points:points
                                 count:count
                           halfWidthPt:halfWidthPt];
  if (vi > 0) {
    CGSize d = self.drawableSize;
    simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
    [enc setRenderPipelineState:_aaLinePipeline];
    [self _bindToolVerts:verts count:vi];
    [enc setVertexBytes:&vp
                 length:sizeof(vp)
                atIndex:KKVertexInputIndex_ViewportSize];
    [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vi];
  }
  free(verts);
}

- (void)encodeToolRingAtPoint:(CGPoint)viewPoint
                     radiusPt:(CGFloat)radiusPt
                         fill:(simd_float4)fill
                  strokeColor:(simd_float4)strokeColor
                  fillWidthPt:(CGFloat)fillWidthPt
               outlineWidthPt:(CGFloat)outlineWidthPt {
  if (!_toolEncoder || !_ringPipeline)
    return;
  // Rings sit above the dots/lines accumulated so far - flush them first so the
  // z-order matches the immediate path.
  [self _flushToolBatchBuckets];
  [self _encodeRingOSCAt:viewPoint
               radiusXPt:radiusPt
               radiusYPt:radiusPt
               fillColor:fill
             strokeColor:strokeColor
             fillWidthPt:fillWidthPt
          outlineWidthPt:outlineWidthPt
                 encoder:_toolEncoder];
}

- (void)encodeToolFillTexture:(id<MTLTexture>)texture {
  // Reuse the toolbar pipeline (KKVertexShader + KKLabelFragment,
  // premultiplied- alpha blend) - the path-op fill texture is premultiplied
  // RGBA, so it composites over the mini's content the same way the toolbar
  // labels do. Drawn as a full-drawable quad (UV 0-1), so the caller-supplied
  // texture must be drawable-sized.
  if (!_toolEncoder || !_toolbarPipeline || !texture)
    return;
  // The fill quad composites over the overlay drawn so far (e.g. the path-edit
  // OSC the hover preview sits on top of) - flush the pending buckets first.
  [self _flushToolBatchBuckets];
  CGSize d = self.drawableSize;
  [_toolEncoder setRenderPipelineState:_toolbarPipeline];
  simd_uint2 vp = {(unsigned int)d.width, (unsigned int)d.height};
  [_toolEncoder setVertexBytes:&vp
                        length:sizeof(vp)
                       atIndex:KKVertexInputIndex_ViewportSize];
  float hw = (float)d.width / 2.0f, hh = (float)d.height / 2.0f;
  KKVertex2D verts[6] = {
      {{-hw, -hh}, {0, 0}}, {{hw, -hh}, {1, 0}}, {{hw, hh}, {1, 1}},
      {{-hw, -hh}, {0, 0}}, {{hw, hh}, {1, 1}},  {{-hw, hh}, {0, 1}},
  };
  [_toolEncoder setVertexBytes:verts
                        length:sizeof(verts)
                       atIndex:KKVertexInputIndex_Vertices];
  [_toolEncoder setFragmentTexture:texture atIndex:0];
  [_toolEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                   vertexStart:0
                   vertexCount:6];
}

- (void)_beginToolBatch {
  if (_toolBatch)
    [self _endToolBatch]; // safety - never nest
  _toolBatch = calloc(1, sizeof(KKToolBatch));
}

// Binds `count` verts as the encoder's vertex stream. setVertexBytes caps at
// 4KB, so a full bucket (well past that) goes through a transient shared buffer
// instead - the same threshold the immediate line encoder uses.
- (void)_bindToolVerts:(const KKVertex2D *)verts count:(NSUInteger)count {
  NSUInteger byteLen = sizeof(KKVertex2D) * count;
  if (byteLen <= 4096) {
    [_toolEncoder setVertexBytes:verts
                          length:byteLen
                         atIndex:KKVertexInputIndex_Vertices];
  } else {
    id<MTLBuffer> buf =
        [_toolEncoder.device newBufferWithBytes:verts
                                         length:byteLen
                                        options:MTLResourceStorageModeShared];
    [_toolEncoder setVertexBuffer:buf
                           offset:0
                          atIndex:KKVertexInputIndex_Vertices];
  }
}

// Draws everything accumulated so far (lines first, then dots on top - matching
// the immediate draw order), then resets the bucket counts but keeps the
// allocations so the batch stays armed for the rest of the overlay.
- (void)_flushToolBatchBuckets {
  KKToolBatch *b = (KKToolBatch *)_toolBatch;
  if (!b)
    return;
  id<MTLRenderCommandEncoder> enc = _toolEncoder;
  CGSize d = self.drawableSize;
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  if (enc) {
    for (NSUInteger i = 0; i < b->lineCount; i++) {
      KKToolBucket *bk = &b->lines[i];
      if (bk->count == 0 || !_aaLinePipeline)
        continue;
      [enc setRenderPipelineState:_aaLinePipeline];
      [self _bindToolVerts:bk->verts count:bk->count];
      [enc setVertexBytes:&vp
                   length:sizeof(vp)
                  atIndex:KKVertexInputIndex_ViewportSize];
      simd_float4 color = bk->color;
      [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:bk->count];
    }
    for (NSUInteger i = 0; i < b->dotCount; i++) {
      KKToolBucket *bk = &b->dots[i];
      if (bk->count == 0 || !_pointPipeline)
        continue;
      KKPointOSCParams params = {
          .outlineWidth = KKOSCPointOutlineRatio(),
          .fillColor = bk->color,
          .strokeColor = KKOSCPointStroke(),
      };
      [enc setRenderPipelineState:_pointPipeline];
      [self _bindToolVerts:bk->verts count:bk->count];
      [enc setVertexBytes:&vp
                   length:sizeof(vp)
                  atIndex:KKVertexInputIndex_ViewportSize];
      [enc setFragmentBytes:&params
                     length:sizeof(params)
                    atIndex:KKOSCFragmentIndex_DrawColor];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:0
              vertexCount:bk->count];
    }
  }
  for (NSUInteger i = 0; i < b->lineCount; i++)
    b->lines[i].count = 0;
  for (NSUInteger i = 0; i < b->dotCount; i++)
    b->dots[i].count = 0;
}

- (void)_endToolBatch {
  [self _flushToolBatchBuckets];
  KKToolBatch *b = (KKToolBatch *)_toolBatch;
  if (!b)
    return;
  for (NSUInteger i = 0; i < b->lineCount; i++)
    free(b->lines[i].verts);
  for (NSUInteger i = 0; i < b->dotCount; i++)
    free(b->dots[i].verts);
  free(b->lines);
  free(b->dots);
  free(b);
  _toolBatch = NULL;
}

@end
