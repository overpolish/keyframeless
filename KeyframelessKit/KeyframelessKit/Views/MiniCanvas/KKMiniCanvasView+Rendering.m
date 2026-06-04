/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasRenderer.h"
#import "KKMiniCanvasView_Private.h"
#import "KKOSCShaderTypes.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <simd/simd.h>

// KKPointOSCFragment's bevel is lighter where texcoord.y is negative. Our
// drawable's NDC handedness vs. the viewer OSC can't be derived analytically
// (the image's UV flip masks it), so this is an explicit knob: YES = lighter
// at the top of the dot (the requested look). Flip if it ever inverts.
static const BOOL kPointShadingLighterTop = YES;

@implementation KKMiniCanvasView (Rendering)

- (void)_buildPipeline {
  id<MTLDevice> device = self.device;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib) {
    KKLogError(@"KKMiniCanvasView: no default metal library: %@", err);
    return;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  pd.fragmentFunction =
      [lib newFunctionWithName:@"KKTexturePassthroughFragment"];
  pd.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  _pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!_pipeline)
    KKLogError(@"KKMiniCanvasView: pipeline build failed: %@", err);

  // Onion-skin: tint+alpha texture pass, premultiplied alpha blending so
  // overlaid ghost frames composite over the active opaque base.
  MTLRenderPipelineDescriptor *op = [[MTLRenderPipelineDescriptor alloc] init];
  op.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  op.fragmentFunction = [lib newFunctionWithName:@"KKTextureTintFragment"];
  op.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  op.colorAttachments[0].blendingEnabled = YES;
  op.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  op.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  op.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
  op.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
  op.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  op.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _onionPipeline = [device newRenderPipelineStateWithDescriptor:op error:&err];
  if (!_onionPipeline)
    KKLogError(@"KKMiniCanvasView: onion pipeline failed: %@", err);

  // Shared KKPointOSC glyph, alpha-blended over the composited image.
  MTLRenderPipelineDescriptor *pp = [[MTLRenderPipelineDescriptor alloc] init];
  pp.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  pp.fragmentFunction = [lib newFunctionWithName:@"KKPointOSCFragment"];
  pp.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  pp.colorAttachments[0].blendingEnabled = YES;
  pp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  pp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  pp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  pp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  pp.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  pp.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _pointPipeline = [device newRenderPipelineStateWithDescriptor:pp error:&err];
  if (!_pointPipeline)
    KKLogError(@"KKMiniCanvasView: point pipeline failed: %@", err);

  // Shared KKSquarePointOSC glyph (Magic Move anchor pivot). Same blend mode
  // as the point pipeline, different fragment.
  MTLRenderPipelineDescriptor *sq = [[MTLRenderPipelineDescriptor alloc] init];
  sq.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  sq.fragmentFunction = [lib newFunctionWithName:@"KKSquarePointOSCFragment"];
  sq.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  sq.colorAttachments[0].blendingEnabled = YES;
  sq.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  sq.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  sq.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  sq.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  sq.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  sq.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _squarePipeline = [device newRenderPipelineStateWithDescriptor:sq error:&err];
  if (!_squarePipeline)
    KKLogError(@"KKMiniCanvasView: square pipeline failed: %@", err);

  // Arc glyph pipeline - opt-in via the renderer's pointHandleStyle. Same
  // blend mode as the point pipeline, different fragment.
  MTLRenderPipelineDescriptor *ap = [[MTLRenderPipelineDescriptor alloc] init];
  ap.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  ap.fragmentFunction = [lib newFunctionWithName:@"KKArcOSCFragment"];
  ap.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  ap.colorAttachments[0].blendingEnabled = YES;
  ap.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  ap.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  ap.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  ap.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  ap.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  ap.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _arcPipeline = [device newRenderPipelineStateWithDescriptor:ap error:&err];
  if (!_arcPipeline)
    KKLogError(@"KKMiniCanvasView: arc pipeline failed: %@", err);

  // Rotation gizmo: shared `KKRotationOSCFragment` shader. Same blend mode
  // as the other glyph pipelines so the rings composite straight over the
  // image.
  MTLRenderPipelineDescriptor *rp = [[MTLRenderPipelineDescriptor alloc] init];
  rp.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  rp.fragmentFunction = [lib newFunctionWithName:@"KKRotationOSCFragment"];
  rp.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  rp.colorAttachments[0].blendingEnabled = YES;
  rp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  rp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  rp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  rp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  rp.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  rp.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _rotationPipeline = [device newRenderPipelineStateWithDescriptor:rp
                                                             error:&err];
  if (!_rotationPipeline)
    KKLogError(@"KKMiniCanvasView: rotation pipeline failed: %@", err);

  // Flat-color pipeline for the crop border, drawn before the glyphs so the
  // handles sit on top of the line.
  MTLRenderPipelineDescriptor *lp = [[MTLRenderPipelineDescriptor alloc] init];
  lp.vertexFunction = [lib newFunctionWithName:@"KKVertexShader"];
  lp.fragmentFunction = [lib newFunctionWithName:@"KKSolidColorFragment"];
  lp.colorAttachments[0].pixelFormat = self.colorPixelFormat;
  lp.colorAttachments[0].blendingEnabled = YES;
  lp.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
  lp.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
  lp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  lp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
  lp.colorAttachments[0].destinationRGBBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  lp.colorAttachments[0].destinationAlphaBlendFactor =
      MTLBlendFactorOneMinusSourceAlpha;
  _linePipeline = [device newRenderPipelineStateWithDescriptor:lp error:&err];
  if (!_linePipeline)
    KKLogError(@"KKMiniCanvasView: line pipeline failed: %@", err);

  // Antialiased line pipeline (KKLineFragment uses textureCoordinate.y as the
  // signed cross-line distance) - same blend, used for the motion path so its
  // diagonals aren't jagged like the solid-colour crop border.
  lp.fragmentFunction = [lib newFunctionWithName:@"KKLineFragment"];
  _aaLinePipeline = [device newRenderPipelineStateWithDescriptor:lp error:&err];
  if (!_aaLinePipeline)
    KKLogError(@"KKMiniCanvasView: aa line pipeline failed: %@", err);
}

// Encodes one shared KKArcOSC glyph centered at `centerPts`. Used by
// renderers that opt into `KKMiniHandleStyleArc` so the mini-canvas handle
// matches the viewer-side ring. Matches KKArcOSC's defaults at a smaller
// mini-canvas scale: 0xC1 gray fill, ring ratio 13/23 (inner = 0.43),
// outline width derived from KKBorderWidthXS. When `isActive` is YES the
// outer radius grows (mirroring KKArcOSC's 23→31 expansion) and a small
// "plus" indicator is drawn in the centre.
- (void)_encodeArcHandleGlyphAt:(CGPoint)centerPts
                       isActive:(BOOL)isActive
                     ghostAlpha:(CGFloat)ghostAlpha
                        encoder:(id<MTLRenderCommandEncoder>)enc {
  if (!_arcPipeline)
    return;
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  CGPoint centered = CGPointMake(centerPts.x * s - d.width / 2.0,
                                 centerPts.y * s - d.height / 2.0);
  // Base outer radius in canvas points; active state expands it (matches the
  // viewer KKArcOSC 23→31 hit-grow). Stroke is held constant across states
  // (viewer KKArcOSC keeps strokeWidth=10 fixed while radius grows); the
  // inner ratio is derived so the visible ring stays the same thickness.
  // Arc + ring sizes track the canvas frame height (NOT contentRect, which
  // grows on zoom) so they scale uniformly when the popover gets bigger.
  // Baseline 230pt = the kKKMini constants-popover canvas height at the
  // original 420pt popover width (16:9).
  const CGFloat kBaselineCanvasH = 230.0;
  CGFloat canvasScale = self.bounds.size.height / kBaselineCanvasH;
  if (canvasScale <= 0)
    canvasScale = 1.0;
  CGFloat outerPt = (isActive ? 12.0 : 9.0) * canvasScale;
  CGFloat strokePt = 4.5 * canvasScale;
  float sizePx = (float)(outerPt * s);
  KKVertex2D quad[6];
  [KKRenderPrimitives generateQuadVertices:quad center:centered size:sizePx];
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  float innerRatio = (float)((outerPt - strokePt) / outerPt);
  float outline = (float)(KKBorderWidthXS / outerPt);
  // Crosshair (+ inside the ring on active). Match the viewer KKArcOSC's
  // outer-relative ratios verbatim so the mini gizmo reads the same:
  // arm length 7/outer, fill 1/outer, outline 2/outer. The previous values
  // normalized arm length to the viewer's canvas height instead of its
  // outer radius, producing a crosshair ~3x too short and ~7x too thin
  // that was effectively invisible at mini-canvas scale.
  float plusHalf = isActive ? (7.0f / 31.75f) : 0.0f;
  float plusFill = isActive ? (1.0f / 31.75f) : 0.0f;
  float plusOutl = isActive ? (2.0f / 31.75f) : 0.0f;
  KKArcOSCParams params = {
      .innerRadius = innerRatio,
      .outlineWidth = outline,
      .plusHalfLen = plusHalf,
      .plusFillHalfWidth = plusFill,
      .plusOutlineWidth = plusOutl,
      // 0xC1 gray fill, matching KKArcOSC's `arcFillColor`. ghostAlpha dims the
      // whole glyph when it's a revealed (opt-hold) ghost.
      .fillColor = {193.0f / 255.0f, 193.0f / 255.0f, 193.0f / 255.0f,
                    (float)ghostAlpha},
      .strokeColor = {0.0f, 0.0f, 0.0f, 0.8f * (float)ghostAlpha},
  };
  [enc setRenderPipelineState:_arcPipeline];
  [enc setVertexBytes:quad
               length:sizeof(quad)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setFragmentBytes:&params
                 length:sizeof(params)
                atIndex:KKOSCFragmentIndex_DrawColor];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

// Encodes the shared KKRotationOSC 3-ring gizmo centered at `centerPts`
// (overlay points, y-up) at the given pixel radius. The fragment shader is
// Y-DOWN-convention (matches the viewer OSC + hit-test); the mini-canvas
// drawable is Y-UP, so we negate textureCoordinate.y on each vertex to keep
// the rings visually consistent with the viewer.
- (void)_encodeRotationOSCAt:(CGPoint)centerPts
                    radiusPx:(CGFloat)radiusPx
                      params:(KKRotationOSCParams)params
                     encoder:(id<MTLRenderCommandEncoder>)enc {
  if (!_rotationPipeline)
    return;
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  CGPoint centered = CGPointMake(centerPts.x * s - d.width / 2.0,
                                 centerPts.y * s - d.height / 2.0);
  // The quad must extend a bit past the outer ring so the antialiased edge
  // has room to fade. Mirrors KKRotationOSC's `quadHalf` derivation.
  CGFloat quadHalfPt = radiusPx + 4.0;
  float sizePx = (float)(quadHalfPt * s);
  KKVertex2D quad[6];
  [KKRenderPrimitives generateQuadVertices:quad center:centered size:sizePx];
  for (int i = 0; i < 6; i++)
    quad[i].textureCoordinate.y = -quad[i].textureCoordinate.y;
  // Rescale shader-side normalized radii so the caller's pixel sizes map
  // through the (possibly enlarged) quad correctly.
  float qh = (float)quadHalfPt;
  params.radius = (float)(radiusPx / qh);
  params.ringHalfWidth = (float)((radiusPx * params.ringHalfWidth) / qh);
  params.outlineWidth = (float)((radiusPx * params.outlineWidth) / qh);
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  [enc setRenderPipelineState:_rotationPipeline];
  [enc setVertexBytes:quad
               length:sizeof(quad)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setFragmentBytes:&params
                 length:sizeof(params)
                atIndex:KKOSCFragmentIndex_DrawColor];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

// Overlay controls scale with the canvas frame height so they stay
// proportional as the popover grows/shrinks (baseline 230pt; matches the arc /
// rotation gizmo). Point glyphs and the motion path use this too.
- (CGFloat)_canvasScale {
  CGFloat cs = self.bounds.size.height / 230.0;
  return cs > 0 ? cs : 1.0;
}

// Thin rectangle outline (view-point rect) drawn as four filled edge quads via
// the flat-colour line pipeline. Shared by the crop border + the scale box.
- (void)_encodeRectBorder:(CGRect)br
                lineColor:(simd_float4)lineColor
                  encoder:(id<MTLRenderCommandEncoder>)enc {
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  float L = (float)(CGRectGetMinX(br) * s - d.width / 2.0);
  float R = (float)(CGRectGetMaxX(br) * s - d.width / 2.0);
  float B = (float)(CGRectGetMinY(br) * s - d.height / 2.0);
  float T = (float)(CGRectGetMaxY(br) * s - d.height / 2.0);
  float lw = (float)(1.0 * s);
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  [enc setRenderPipelineState:_linePipeline];
  [enc setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setFragmentBytes:&lineColor length:sizeof(lineColor) atIndex:0];
  float edges[4][4] = {
      {L, B, R, B + lw},
      {L, T - lw, R, T},
      {L, B, L + lw, T},
      {R - lw, B, R, T},
  };
  for (int e = 0; e < 4; e++) {
    float x0 = edges[e][0], y0 = edges[e][1], x1 = edges[e][2],
          y1 = edges[e][3];
    KKVertex2D q[4] = {
        {{x0, y1}, {0, 0}},
        {{x0, y0}, {0, 0}},
        {{x1, y1}, {0, 0}},
        {{x1, y0}, {0, 0}},
    };
    [enc setVertexBytes:q length:sizeof(q) atIndex:KKVertexInputIndex_Vertices];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
            vertexStart:0
            vertexCount:4];
  }
}

// Encodes one shared KKPointOSC glyph centered at `centerPts` (overlay
// points, y-up). `enc` must already be a valid render encoder for this pass.
- (void)_encodeHandleGlyphAt:(CGPoint)centerPts
                   fillColor:(simd_float4)fillColor
                     encoder:(id<MTLRenderCommandEncoder>)enc {
  [self _encodeHandleGlyphAt:centerPts
                   fillColor:fillColor
                   sizeScale:1.0
                     encoder:enc];
}

// `sizeScale` shrinks the glyph relative to the standard handle (1.0); used for
// the smaller motion-path anchor / tangent-handle dots.
- (void)_encodeHandleGlyphAt:(CGPoint)centerPts
                   fillColor:(simd_float4)fillColor
                   sizeScale:(CGFloat)sizeScale
                     encoder:(id<MTLRenderCommandEncoder>)enc {
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  CGPoint centered = CGPointMake(centerPts.x * s - d.width / 2.0,
                                 centerPts.y * s - d.height / 2.0);
  float sizePx =
      (float)(kKKMiniHandleOuterPt * sizeScale * [self _canvasScale] * s);
  KKVertex2D quad[6];
  [KKRenderPrimitives generateQuadVertices:quad center:centered size:sizePx];
  // generateQuadVertices puts tc.y=+1 on the higher-position (screen-top)
  // vertices; KKPointOSCFragment is lighter at tc.y<0. Negating tc.y →
  // lighter at the top of the dot. Gated by the explicit knob.
  if (kPointShadingLighterTop)
    for (int i = 0; i < 6; i++)
      quad[i].textureCoordinate.y = -quad[i].textureCoordinate.y;
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  KKPointOSCParams params = {
      .outlineWidth = (float)(KKBorderWidthXS / kKKMiniHandleOuterPt),
      .fillColor = fillColor,
      .strokeColor = {0.0f, 0.0f, 0.0f, 0.75f},
  };
  [enc setRenderPipelineState:_pointPipeline];
  [enc setVertexBytes:quad
               length:sizeof(quad)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setFragmentBytes:&params
                 length:sizeof(params)
                atIndex:KKOSCFragmentIndex_DrawColor];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

// Encodes one shared KKSquarePointOSC glyph centered at `centerPts` (overlay
// points, y-up). `ghostAlpha` multiplies every (fill / stroke / shadow) alpha
// so a hidden, opt-revealed anchor draws dimmed. Sized to match the point
// handle glyph so the controls read as a family.
- (void)_encodeSquareGlyphAt:(CGPoint)centerPts
                  ghostAlpha:(CGFloat)ghostAlpha
                   sizeScale:(CGFloat)sizeScale
                     encoder:(id<MTLRenderCommandEncoder>)enc {
  if (!_squarePipeline)
    return;
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  CGPoint centered = CGPointMake(centerPts.x * s - d.width / 2.0,
                                 centerPts.y * s - d.height / 2.0);
  // Match the handle dots' visible size. A point dot fills its whole quad, but
  // the square only fills halfSize = 1 - outline/outer ~= 0.857 of its quad, so
  // scale the quad up by 1/0.857 to land on the same visible extent.
  // `sizeScale` is the same handle multiplier applied to the dots (e.g.
  // MagicMove's 0.6), so the square tracks them at every popover size
  // (canvasScale = H/230).
  static const float kSquareFillFrac = 0.857f;
  float sizePx = (float)(kKKMiniHandleOuterPt * sizeScale / kSquareFillFrac *
                         [self _canvasScale] * s);
  KKVertex2D quad[6];
  [KKRenderPrimitives generateQuadVertices:quad center:centered size:sizePx];
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  float g = (float)ghostAlpha;
  // Match KKSquarePointOSC's proportions exactly: its params are normalized by
  // outerRadiusPixels = oscSize(6) + outline(1.5) + 3 = 10.5, NOT by the quad's
  // pixel size. Reusing the viewer fractions keeps the outline thin and the
  // square filling ~86% of the quad (normalizing by the small handle radius
  // gave a 33%-thick outline on a 67% shape).
  float vOutline = (float)(KKBorderWidthXS + 0.5);
  float outer = 6.0f + vOutline + 3.0f;
  KKSquarePointOSCParams params = {
      .cornerRadius = (float)(KKRadiusSM / outer),
      .outlineWidth = vOutline / outer,
      .shadowOffset = 1.5f / outer,
      .shadowRadius = 2.5f / outer,
      .fillColor = {1.0f, 1.0f, 1.0f, 1.0f * g},
      .strokeColor = {0.0f, 0.0f, 0.0f, 0.75f * g},
      .shadowColor = {0.0f, 0.0f, 0.0f, 0.5f * g},
  };
  [enc setRenderPipelineState:_squarePipeline];
  [enc setVertexBytes:quad
               length:sizeof(quad)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
  [enc setFragmentBytes:&params
                 length:sizeof(params)
                atIndex:KKOSCFragmentIndex_DrawColor];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
}

// Encodes a connected polyline (overlay points, y-up) as oriented thin quads
// via the shared solid-colour line pipeline. `enc` must be a valid encoder.
- (void)_encodeMotionLineStrip:(NSArray<NSValue *> *)pointsPts
                         color:(simd_float4)color
                   halfWidthPt:(CGFloat)halfWidthPt
                       encoder:(id<MTLRenderCommandEncoder>)enc {
  if (pointsPts.count < 2 || !_aaLinePipeline)
    return;
  CGSize d = self.drawableSize;
  CGFloat s = self.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  // Proportional to the canvas, then a 1px AA pad. tc.y carries the signed
  // cross-line distance for KKLineFragment (edge value > 1 so the fade lands
  // inside the geometric edge). Mirrors the viewer's drawLineStripWithPoints.
  float hw = (float)(halfWidthPt * [self _canvasScale] * s);
  if (hw < 0.5f)
    hw = 0.5f;
  float pad = hw + 1.0f;
  float edge = pad / hw;
  simd_uint2 vp = {(unsigned)d.width, (unsigned)d.height};
  NSUInteger segCount = pointsPts.count - 1;
  KKVertex2D *verts = malloc(sizeof(KKVertex2D) * segCount * 6);
  NSUInteger vi = 0;
  for (NSUInteger i = 0; i < segCount; i++) {
    CGPoint pa = pointsPts[i].pointValue, pb = pointsPts[i + 1].pointValue;
    simd_float2 mA = {(float)(pa.x * s - d.width / 2.0),
                      (float)(pa.y * s - d.height / 2.0)};
    simd_float2 mB = {(float)(pb.x * s - d.width / 2.0),
                      (float)(pb.y * s - d.height / 2.0)};
    simd_float2 dd = mB - mA;
    float len = simd_length(dd);
    if (len < 0.001f)
      continue;
    simd_float2 dir = dd / len;
    simd_float2 perp = {-dir.y, dir.x};
    simd_float2 v0 = mA + perp * pad, v1 = mA - perp * pad;
    simd_float2 v2 = mB + perp * pad, v3 = mB - perp * pad;
    verts[vi++] = (KKVertex2D){v0, {0, edge}};
    verts[vi++] = (KKVertex2D){v1, {0, -edge}};
    verts[vi++] = (KKVertex2D){v2, {0, edge}};
    verts[vi++] = (KKVertex2D){v1, {0, -edge}};
    verts[vi++] = (KKVertex2D){v3, {0, -edge}};
    verts[vi++] = (KKVertex2D){v2, {0, edge}};
  }
  if (vi > 0) {
    NSUInteger byteLen = sizeof(KKVertex2D) * vi;
    [enc setRenderPipelineState:_aaLinePipeline];
    if (byteLen <= 4096) {
      [enc setVertexBytes:verts
                   length:byteLen
                  atIndex:KKVertexInputIndex_Vertices];
    } else {
      id<MTLBuffer> buf =
          [enc.device newBufferWithBytes:verts
                                  length:byteLen
                                 options:MTLResourceStorageModeShared];
      [enc setVertexBuffer:buf offset:0 atIndex:KKVertexInputIndex_Vertices];
    }
    [enc setVertexBytes:&vp
                 length:sizeof(vp)
                atIndex:KKVertexInputIndex_ViewportSize];
    [enc setFragmentBytes:&color length:sizeof(color) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vi];
  }
  free(verts);
}

@end
