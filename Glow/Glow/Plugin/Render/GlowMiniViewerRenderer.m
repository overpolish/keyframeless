/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "GlowMiniViewerRenderer.h"

#import "Constants.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <simd/simd.h>

NSString *const GlowMiniViewerDescriptorPath = @"/tmp/glow-miniviewer.json";
NSString *const GlowMiniViewerRequestPath =
    @"/tmp/glow-miniviewer-request.json";

// Prep + blur run in float, matching the main render (FCP tiles are
// RGBA16Float). The mini dest is 8-bit BGRA, which would quantize the soft
// glow tail toward zero in an 8-bit blur - making the preview read as a
// tighter/dimmer glow than the viewer. Compositing still targets the 8-bit
// dest; only the blur intermediates need the extra precision.
static const MTLPixelFormat kGlowMiniBlurFormat = MTLPixelFormatRGBA16Float;

// Ring radius (overlay points) = contentRectMinDim * kGlowMiniRingK *
// sqrt(val). Same proportion the viewer ring uses, so the mini ring is a
// faithful preview.
static const double kGlowMiniRingK = 0.012;

// The sRGB sibling of an 8-bit format, so a view of it gamma-encodes on write /
// decodes on read (a linear-light working pass). Returns the input unchanged if
// there's no sRGB sibling (then no gamma conversion happens).
static MTLPixelFormat GlowSRGBVariant(MTLPixelFormat f) {
  switch (f) {
  case MTLPixelFormatBGRA8Unorm:
    return MTLPixelFormatBGRA8Unorm_sRGB;
  case MTLPixelFormatRGBA8Unorm:
    return MTLPixelFormatRGBA8Unorm_sRGB;
  default:
    return f;
  }
}

@implementation GlowMiniViewerRenderer {
  id<MTLRenderPipelineState> _prepPipeline;
  id<MTLRenderPipelineState> _compPipeline;
  MTLPixelFormat _pipelineFormat;
  BOOL _ringGrabbed;
  BOOL _ringHovered;
  // Press-anchored drag state (mirrors the viewer GlowOSC): the grab offset
  // from the ring centre + the radius values at press. The drag scales each
  // axis by its component ratio relative to these, so grabbing a side holds
  // the perpendicular axis (a box-edge-handle feel) instead of collapsing it.
  double _ringStartDx, _ringStartDy, _ringStartDist;
  double _ringStartValX, _ringStartValY;
}

// Glow has no Crop lane (M1) - return nil so the base renderer doesn't try to
// draw / hit-test the default crop box against a missing lane (crashes).
- (NSString *)cropLabel {
  return nil;
}

- (NSInteger)valueTypeForLabel:(NSString *)label {
  return KKLaneValueTypeFloat;
}

// Glow is a soft, bounds-expanding effect: render the mini preview at display
// resolution so the glow's soft falloff stays faithful (see KKMiniViewerView
// -_ensureProcessedTextureForSlot:). The glow shader samples by normalized
// texcoord, so the smaller dest doesn't distort it.
- (BOOL)prefersDisplayResolutionProcessing {
  return YES;
}

- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  if ([label isEqualToString:@"Radius"])
    return @[ @(kGlowM1Radius), @(kGlowM1Radius) ];
  return [super defaultValuesForLabel:label];
}

// The radius ring shows for a constant, visible (or opt-revealed) Radius lane -
// same gate the base uses for its point handle.
- (BOOL)_ringActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) &&
         ![self.suppressedHandleLabels containsObject:@"Radius"] &&
         [self isConstantLabel:@"Radius"] &&
         [self labelVisibleOrRevealing:@"Radius"];
}

// The ring is a dimmed ghost when it's only shown because of an Opt-hold reveal
// of a hidden ring (ghostAlphaForLabel: returns < 1). In that state it's a
// re-enable target, not an interactive control: don't dim only the draw, also
// suppress the hover/active emphasis + the resize cursor.
- (CGFloat)_radiusGhostAlpha {
  // The base ghost dim (0.3) is barely visible for a thin ring; use 0.6. Peek
  // mode (master off + Opt) returns 1.0 - keep it full/interactive.
  return [self ghostAlphaForLabel:@"Radius"] < 1.0 ? 0.6 : 1.0;
}
- (BOOL)_ringIsGhost {
  return [self _radiusGhostAlpha] < 0.999;
}

// Ring geometry for the current Radius value: centred in the content rect, with
// per-axis pixel radii from the same sqrt mapping as the viewer ring.
- (BOOL)_ringCenter:(out CGPoint *)outCenter
            radiusX:(out CGFloat *)outRx
            radiusY:(out CGFloat *)outRy
     forContentRect:(CGRect)cr {
  if (![self _ringActiveForContentRect:cr])
    return NO;
  NSArray<NSNumber *> *v = [self valuesForLabel:@"Radius"];
  double rxVal = v.count >= 1 ? v[0].doubleValue : kGlowM1Radius;
  double ryVal = v.count >= 2 ? v[1].doubleValue : rxVal;
  double k = MIN(cr.size.width, cr.size.height) * kGlowMiniRingK;
  if (outCenter)
    *outCenter = CGPointMake(CGRectGetMidX(cr), CGRectGetMidY(cr));
  if (outRx)
    *outRx = (CGFloat)(k * sqrt(MAX(0.0, rxVal)));
  if (outRy)
    *outRy = (CGFloat)(k * sqrt(MAX(0.0, ryVal)));
  return YES;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
        ringCenter:(out CGPoint *)outCenter
           radiusX:(out CGFloat *)outRx
           radiusY:(out CGFloat *)outRy
       contentRect:(CGRect)cr {
  return [self _ringCenter:outCenter
                   radiusX:outRx
                   radiusY:outRy
            forContentRect:cr];
}

// The shared timing guide drives its drag-to-target steps through the
// mini-viewer's generic "point handle" hooks (spot rect, target rect, driven
// drag). Glow has a ring, not a point, so expose a point-handle anchor sitting
// on the ellipse at 45 degrees (top-right of the ring): pressing it lands on
// the ring stroke, and dragging it outward grows the radius - exactly the
// gesture a user makes. pointHandleStyle is None so the kit paints no dot here;
// the ring is the glyph. The base wrappers gate on `pointLabel` (which Glow
// doesn't set), so override them to gate on the ring's own active state.
static const double kGlowRingHandleCos = M_SQRT1_2; // cos / sin of 45 degrees

- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStyleNone;
}

- (CGPoint)_ringHandlePointForCenter:(CGPoint)c
                             radiusX:(CGFloat)rx
                             radiusY:(CGFloat)ry {
  return CGPointMake(c.x + rx * kGlowRingHandleCos,
                     c.y + ry * kGlowRingHandleCos);
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
          contentRect:(CGRect)cr {
  CGPoint c = CGPointZero;
  CGFloat rx = 0, ry = 0;
  if (![self _ringCenter:&c radiusX:&rx radiusY:&ry forContentRect:cr])
    return NO;
  if (outCenter)
    *outCenter = [self _ringHandlePointForCenter:c radiusX:rx radiusY:ry];
  return YES;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
            forValues:(NSArray<NSNumber *> *)values
          contentRect:(CGRect)cr {
  if (![self _ringActiveForContentRect:cr])
    return NO;
  double valX = values.count >= 1 ? values[0].doubleValue : kGlowM1Radius;
  double valY = values.count >= 2 ? values[1].doubleValue : valX;
  double k = MIN(cr.size.width, cr.size.height) * kGlowMiniRingK;
  CGPoint c = CGPointMake(CGRectGetMidX(cr), CGRectGetMidY(cr));
  CGFloat rx = (CGFloat)(k * sqrt(MAX(0.0, valX)));
  CGFloat ry = (CGFloat)(k * sqrt(MAX(0.0, valY)));
  if (outCenter)
    *outCenter = [self _ringHandlePointForCenter:c radiusX:rx radiusY:ry];
  return YES;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
             forValue:(double)value
          contentRect:(CGRect)cr {
  return [self miniViewer:canvas
        pointHandleCenter:outCenter
                forValues:@[ @(value), @(value) ]
              contentRect:cr];
}

// Hit the ring stroke (within a few points of the ellipse edge).
- (BOOL)_ringHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  CGPoint c = CGPointZero;
  CGFloat rx = 0, ry = 0;
  if (![self _ringCenter:&c radiusX:&rx radiusY:&ry forContentRect:cr] ||
      (rx < 1.0 && ry < 1.0))
    return NO;
  double nx = rx > 0 ? (p.x - c.x) / rx : 0;
  double ny = ry > 0 ? (p.y - c.y) / ry : 0;
  double ringDist = fabs(sqrt(nx * nx + ny * ny) - 1.0) * ((rx + ry) * 0.5);
  return ringDist < 6.0;
}

// Whether the Radius lane is currently aspect-linked (uniform circle). The
// lane defaults linked; the value popover's link glyph toggles it.
- (BOOL)_radiusAspectLinked {
  for (KKLane *lane in self.timeline.lanes)
    if ([lane.label isEqualToString:@"Radius"])
      return lane.aspectLinked;
  return YES;
}

// Resize identical to the viewer ring (GlowOSC mouseDragged). Shift inverts the
// lane's aspect-link for this drag (same as the scale box). The cursor maps
// directly through the inverse of the ring's radius mapping
// (R = minDim * 0.012 * sqrt(val)) so the ring edge sticks to the mouse 1:1:
//   - effectively linked  -> uniform: ring edge follows the cursor's distance.
//   - effectively unlinked -> per-axis: each radius follows its own cursor
//     component. An axis grabbed near its cardinal (a side: start component
//     small vs the grab radius) is HELD (box-edge feel), not collapsed.
- (void)_applyRingDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                    modifiers:(NSEventModifierFlags)modifiers
                       canvas:(KKMiniViewerView *)canvas {
  double c = MIN(cr.size.width, cr.size.height) * kGlowMiniRingK;
  if (c <= 0.0 || _ringStartDist <= 0)
    return;
  double dx = p.x - CGRectGetMidX(cr);
  double dy = p.y - CGRectGetMidY(cr);
  BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
  BOOL effLinked = [self _radiusAspectLinked] ^ shift;
  double newX, newY;
  if (effLinked) {
    double r = hypot(dx, dy) / c;
    newX = newY = MAX(0.0, MIN(500.0, r * r));
  } else {
    static const double kCardinalFrac = 0.25;
    double minComp = kCardinalFrac * _ringStartDist;
    double rx = fabs(dx) / c, ry = fabs(dy) / c;
    newX = (fabs(_ringStartDx) > minComp) ? MAX(0.0, MIN(500.0, rx * rx))
                                          : _ringStartValX;
    newY = (fabs(_ringStartDy) > minComp) ? MAX(0.0, MIN(500.0, ry * ry))
                                          : _ringStartValY;
  }
  [self commitValues:@[ @(newX), @(newY) ] forLabel:@"Radius" canvas:canvas];
  [canvas setNeedsDisplay:YES];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  if ([self _ringHitAtPoint:p contentRect:cr])
    return YES;
  return [super miniViewer:canvas handleHitAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  _ringGrabbed = NO;
  if ([self _ringHitAtPoint:p contentRect:cr]) {
    self.canvas = canvas;
    _ringGrabbed = YES;
    // Capture the grab offset + current radii; the drag scales relative to
    // these (press-anchored), matching the viewer. No write on press.
    _ringStartDx = p.x - CGRectGetMidX(cr);
    _ringStartDy = p.y - CGRectGetMidY(cr);
    _ringStartDist = hypot(_ringStartDx, _ringStartDy);
    NSArray<NSNumber *> *v = [self valuesForLabel:@"Radius"];
    _ringStartValX = v.count >= 1 ? v[0].doubleValue : kGlowM1Radius;
    _ringStartValY = v.count >= 2 ? v[1].doubleValue : _ringStartValX;
    [canvas setNeedsDisplay:YES];
    return;
  }
  [super miniViewer:canvas beginHandleDragAtPoint:p contentRect:cr];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr
            modifiers:(NSEventModifierFlags)modifiers {
  if (_ringGrabbed) {
    [self _applyRingDragToPoint:p
                    contentRect:cr
                      modifiers:modifiers
                         canvas:canvas];
    return;
  }
  [super miniViewer:canvas
      dragHandleToPoint:p
            contentRect:cr
              modifiers:modifiers];
}

- (void)miniViewerEndHandleDrag:(KKMiniViewerView *)canvas {
  if (_ringGrabbed) {
    _ringGrabbed = NO;
    // Repaint the Metal pass so the ring drops from active back to hover/idle
    // (mouseUp only invalidates the CG overlay).
    [canvas setNeedsDisplay:YES];
  }
  [super miniViewerEndHandleDrag:canvas];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
           cursorAtPoint:(CGPoint)p
             contentRect:(CGRect)cr {
  BOOL hit = [self _ringHitAtPoint:p contentRect:cr];
  BOOL ghost = [self _ringIsGhost];
  // Opt-hover hide/show affordance: only when an Opt-click would actually
  // toggle (Opt held + master on - not the peek-and-use mode). eye.slash over a
  // visible ring, eye over a revealed ghost.
  BOOL optToggle = self.revealHidden && !self.handlesHidden &&
                   self.onHandleVisibilityToggled != nil;
  // Normal resize-hover only when NOT a ghost and NOT showing the eye cursor.
  BOOL onRingHover = hit && !ghost && !optToggle;
  if (onRingHover != _ringHovered) {
    _ringHovered = onRingHover;
    [canvas setNeedsDisplay:YES];
  }
  if (hit && optToggle)
    return ghost ? KKVisibilityShowCursor() : KKVisibilityHideCursor();
  if (onRingHover)
    return KKResizeCursorForAngle(
        atan2(p.y - CGRectGetMidY(cr), p.x - CGRectGetMidX(cr)));
  return [super miniViewer:canvas cursorAtPoint:p contentRect:cr];
}

// Idle / hover / active emphasis for the kit's ring stroke (mirrors the viewer
// ring). Active (dragging) wins over hover. A dimmed ghost stays idle.
- (NSInteger)miniViewerRingEmphasis:(KKMiniViewerView *)canvas {
  if ([self _ringIsGhost])
    return 0;
  if (_ringGrabbed)
    return 2;
  return _ringHovered ? 1 : 0;
}

- (CGFloat)miniViewerRingGhostAlpha:(KKMiniViewerView *)canvas {
  return [self _radiusGhostAlpha];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    optClickHandleAtPoint:(CGPoint)p
              contentRect:(CGRect)cr {
  if (self.onHandleVisibilityToggled && [self _ringHitAtPoint:p
                                                  contentRect:cr]) {
    self.onHandleVisibilityToggled(@"Radius");
    [canvas setNeedsDisplay:YES];
    return YES;
  }
  return [super miniViewer:canvas optClickHandleAtPoint:p contentRect:cr];
}

- (BOOL)_ensurePipelinesForDevice:(id<MTLDevice>)device
                      pixelFormat:(MTLPixelFormat)format {
  if (_prepPipeline && _compPipeline && _pipelineFormat == format)
    return YES;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib) {
    KKLogError(@"GlowMiniViewerRenderer: no metal library: %@", err);
    return NO;
  }
  MTLRenderPipelineDescriptor *prep =
      [[MTLRenderPipelineDescriptor alloc] init];
  prep.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  prep.fragmentFunction = [lib newFunctionWithName:@"glowPrep"];
  prep.colorAttachments[0].pixelFormat = kGlowMiniBlurFormat; // float prep tex
  id<MTLRenderPipelineState> prepPS =
      [device newRenderPipelineStateWithDescriptor:prep error:&err];
  if (!prepPS) {
    KKLogError(@"GlowMiniViewerRenderer: prep pipeline failed: %@", err);
    return NO;
  }
  MTLRenderPipelineDescriptor *comp =
      [[MTLRenderPipelineDescriptor alloc] init];
  comp.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  comp.fragmentFunction = [lib newFunctionWithName:@"glowComposite"];
  // Render into the sRGB VIEW of the (8-bit) dest, so the shader's linear-light
  // output is gamma-encoded on write - matching the main viewer, which works in
  // FCP's float/linear space. Without this the glow is composited and shown in
  // gamma space and reads far too dim.
  comp.colorAttachments[0].pixelFormat = GlowSRGBVariant(format);
  id<MTLRenderPipelineState> compPS =
      [device newRenderPipelineStateWithDescriptor:comp error:&err];
  if (!compPS) {
    KKLogError(@"GlowMiniViewerRenderer: composite pipeline failed: %@", err);
    return NO;
  }
  _prepPipeline = prepPS;
  _compPipeline = compPS;
  _pipelineFormat = format;
  return YES;
}

- (id<MTLTexture>)_scratchForDevice:(id<MTLDevice>)device
                             format:(MTLPixelFormat)format
                              width:(NSUInteger)w
                             height:(NSUInteger)h {
  MTLTextureDescriptor *d =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                         width:MAX(1, w)
                                                        height:MAX(1, h)
                                                     mipmapped:NO];
  d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
            MTLTextureUsageShaderWrite;
  d.storageMode = MTLStorageModePrivate;
  return [device newTextureWithDescriptor:d];
}

// Self-contained glow preview. Unlike the render path (Plugin+Render.m) this
// runs in the inspector process on raw source/dest MTLTextures, so it cannot
// touch the render-side texture pool. M1 skips the bloom lane (threshold 0)
// and uses the kGlowM1* fallbacks for every field except the animated radius.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  if (![self _ensurePipelinesForDevice:dest.device
                           pixelFormat:dest.pixelFormat])
    return NO;

  // Work in linear light: read the (gamma-encoded) source through an sRGB view
  // (decodes sRGB->linear on sample) and write the composite through an sRGB
  // view of the dest (encodes linear->sRGB on store). Falls back to the plain
  // textures if a view can't be made.
  id<MTLTexture> srcLin =
      [source newTextureViewWithPixelFormat:GlowSRGBVariant(source.pixelFormat)]
          ?: source;
  id<MTLTexture> dstSRGB =
      [dest newTextureViewWithPixelFormat:GlowSRGBVariant(dest.pixelFormat)]
          ?: dest;
  source = srcLin;

  NSArray<NSNumber *> *rv = [self valuesForLabel:@"Radius"];
  double rx = rv.count >= 1 ? rv[0].doubleValue : kGlowM1Radius;
  double ry = rv.count >= 2 ? rv[1].doubleValue : rx;

  // Map the full source frame to the dest (same as the main viewer: the glow
  // forms wherever the source is transparent - around a logo's edges, etc. -
  // which for normal centred content is INSIDE the frame). Radius is canonical
  // source pixels; scale it into the (smaller) preview's pixel space so the
  // glow keeps its visual proportion (glow:content ratio matches the viewer).
  float W = (float)dest.width, H = (float)dest.height;
  float scale = source.width > 0 ? W / (float)source.width : 1.0f;
  float effRx = (float)rx * scale, effRy = (float)ry * scale;
  float sigma = fmaxf(fmaxf(effRx, effRy) * 0.5f, 0.5f);

  id<MTLTexture> prepTex = [self _scratchForDevice:dest.device
                                            format:kGlowMiniBlurFormat
                                             width:dest.width
                                            height:dest.height];
  id<MTLTexture> blurTex = [self _scratchForDevice:dest.device
                                            format:kGlowMiniBlurFormat
                                             width:dest.width
                                            height:dest.height];
  if (!prepTex || !blurTex)
    return NO;

  simd_uint2 vp = {(uint)W, (uint)H};
  MTLViewport viewport = {0, 0, (double)W, (double)H, -1, 1};

  // 1) Prep: draw source into prepTex (full frame; dynamic mode keeps RGBA).
  KKVertex2D srcV[] = {
      {{W / 2, -H / 2}, {1, 1}},
      {{-W / 2, -H / 2}, {0, 1}},
      {{W / 2, H / 2}, {1, 0}},
      {{-W / 2, H / 2}, {0, 0}},
  };
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = prepTex;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [e setViewport:viewport];
    [e setVertexBytes:srcV
               length:sizeof(srcV)
              atIndex:KKVertexInputIndex_Vertices];
    [e setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
    [e setRenderPipelineState:_prepPipeline];
    [e setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
    int cm = kGlowM1ColorMode;
    [e setFragmentBytes:&cm length:sizeof(cm) atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
    [e endEncoding];
  }

  // 2) MPS Gaussian blur: prepTex -> blurTex.
  {
    MPSImageGaussianBlur *mps =
        [[MPSImageGaussianBlur alloc] initWithDevice:dest.device sigma:sigma];
    mps.edgeMode = MPSImageEdgeModeClamp;
    [mps encodeToCommandBuffer:commandBuffer
                 sourceTexture:prepTex
            destinationTexture:blurTex];
  }

  // 3) Composite into dest. Geometry mirrors the render path's full-image
  // case; sampling is derived from the fragment window position + uniforms.
  KKVertex2D dstV[] = {
      {{W / 2, -H / 2}, {1, 1}},
      {{-W / 2, -H / 2}, {0, 1}},
      {{W / 2, H / 2}, {1, 0}},
      {{-W / 2, H / 2}, {0, 0}},
  };
  {
    MTLRenderPassDescriptor *rpd =
        [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = dstSRGB; // gamma-encode on store
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e =
        [commandBuffer renderCommandEncoderWithDescriptor:rpd];
    [e setViewport:viewport];
    [e setVertexBytes:dstV
               length:sizeof(dstV)
              atIndex:KKVertexInputIndex_Vertices];
    [e setVertexBytes:&vp
               length:sizeof(vp)
              atIndex:KKVertexInputIndex_ViewportSize];
    [e setRenderPipelineState:_compPipeline];
    [e setFragmentTexture:source atIndex:KKTextureIndex_InputImage];
    [e setFragmentTexture:blurTex atIndex:1];
    [e setFragmentTexture:blurTex atIndex:2];

    float rxF = effRx, ryF = effRy;
    float intensity = kGlowM1Intensity, falloff = kGlowM1Falloff,
          noise = kGlowM1Noise, noiseOffset = kGlowM1NoiseOffset,
          noiseSeed = kGlowM1NoiseSeed, gradAngle = kGlowM1GradientAngle,
          threshold = kGlowM1Threshold;
    int colorMode = kGlowM1ColorMode, gradType = kGlowM1GradientType;
    simd_float2 offset = {0.0f, 0.0f};
    simd_float3 glowColor = {1.0f, 1.0f, 1.0f};
    simd_float3 lut[KK_GRADIENT_LUT_SIZE];
    for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++)
      lut[i] = glowColor;
    simd_float2 blurUVScale = {1.0f, 1.0f};
    simd_float2 tileOffsetPx = {0.0f, 0.0f};
    simd_float2 destImgSizePx = {W, H};
    simd_float2 srcOriginInDestPx = {0.0f, 0.0f};
    simd_float2 srcImgSizePx = {W, H};

    [e setFragmentBytes:&rxF length:sizeof(rxF) atIndex:FragmentIndex_RadiusX];
    [e setFragmentBytes:&ryF length:sizeof(ryF) atIndex:FragmentIndex_RadiusY];
    [e setFragmentBytes:&intensity
                 length:sizeof(intensity)
                atIndex:FragmentIndex_Intensity];
    [e setFragmentBytes:&falloff
                 length:sizeof(falloff)
                atIndex:FragmentIndex_Falloff];
    [e setFragmentBytes:&offset
                 length:sizeof(offset)
                atIndex:FragmentIndex_Offset];
    [e setFragmentBytes:&glowColor
                 length:sizeof(glowColor)
                atIndex:FragmentIndex_GlowColor];
    [e setFragmentBytes:&colorMode
                 length:sizeof(colorMode)
                atIndex:FragmentIndex_ColorMode];
    [e setFragmentBytes:lut
                 length:sizeof(lut)
                atIndex:FragmentIndex_GradientLUT];
    [e setFragmentBytes:&gradType
                 length:sizeof(gradType)
                atIndex:FragmentIndex_GradientType];
    [e setFragmentBytes:&gradAngle
                 length:sizeof(gradAngle)
                atIndex:FragmentIndex_GradientAngle];
    [e setFragmentBytes:&noise
                 length:sizeof(noise)
                atIndex:FragmentIndex_Noise];
    [e setFragmentBytes:&noiseOffset
                 length:sizeof(noiseOffset)
                atIndex:FragmentIndex_NoiseOffset];
    [e setFragmentBytes:&noiseSeed
                 length:sizeof(noiseSeed)
                atIndex:FragmentIndex_NoiseSeed];
    [e setFragmentBytes:&blurUVScale
                 length:sizeof(blurUVScale)
                atIndex:FragmentIndex_BlurUVScale];
    [e setFragmentBytes:&threshold
                 length:sizeof(threshold)
                atIndex:FragmentIndex_Threshold];
    [e setFragmentBytes:&tileOffsetPx
                 length:sizeof(tileOffsetPx)
                atIndex:FragmentIndex_TileOffsetPx];
    [e setFragmentBytes:&destImgSizePx
                 length:sizeof(destImgSizePx)
                atIndex:FragmentIndex_DestImgSizePx];
    [e setFragmentBytes:&srcOriginInDestPx
                 length:sizeof(srcOriginInDestPx)
                atIndex:FragmentIndex_SrcOriginInDestPx];
    [e setFragmentBytes:&srcImgSizePx
                 length:sizeof(srcImgSizePx)
                atIndex:FragmentIndex_SrcImgSizePx];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];
    [e endEncoding];
  }
  return YES;
}

@end
