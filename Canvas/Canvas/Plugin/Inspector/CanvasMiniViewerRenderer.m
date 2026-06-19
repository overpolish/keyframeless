/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasMiniViewerRenderer.h"
#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h"
#import "CanvasMiniViewerRenderer_Internal.h"
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>

NSString *const CanvasMiniViewerDescriptorPath = @"/tmp/canvas-miniviewer.json";
NSString *const CanvasMiniViewerRequestPath =
    @"/tmp/canvas-miniviewer-request.json";

// The sRGB sibling of an 8-bit format, so a texture view of it gamma-decodes on
// read / encodes on write (a linear-light working pass). Mirrors the main
// render, which composites in FCP's float/linear space; without it the 8-bit
// mini dest would composite in gamma space and the image would read too dark.
// Returns the input unchanged when there's no sRGB sibling (float formats).
static MTLPixelFormat CanvasSRGBVariant(MTLPixelFormat f) {
  switch (f) {
  case MTLPixelFormatBGRA8Unorm:
    return MTLPixelFormatBGRA8Unorm_sRGB;
  case MTLPixelFormatRGBA8Unorm:
    return MTLPixelFormatRGBA8Unorm_sRGB;
  default:
    return f;
  }
}

@implementation CanvasMiniViewerRenderer {
  id<MTLRenderPipelineState> _pipeline;      // source passthrough (no blend)
  id<MTLRenderPipelineState> _imagePipeline; // image overlay (premult alpha)
  MTLPixelFormat _pipelineFormat;
  // Image-layer textures, keyed by path. The renderer lives in the inspector
  // process (separate from the render XPC), so it can't share the plugin's
  // cache - it keeps its own.
  NSMutableDictionary<NSString *, id<MTLTexture>> *_imageTextureCache;
}

- (instancetype)init {
  if ((self = [super init])) {
    _positionMini =
        [[KKPositionMiniController alloc] initWithRenderer:self
                                                 laneLabel:@"Position"
                                                 pathLabel:@"Path"];
    _scaleMini = [[KKScaleMiniController alloc] initWithRenderer:self
                                                       laneLabel:@"Scale"];
    _anchorMini = [[KKAnchorMiniController alloc]
        initWithRenderer:self
               laneLabel:@"Anchor"
       positionLaneLabel:@"Position"
              snapEngine:_positionMini.snapEngine];
    // The anchor pivot can sit dead-centre on the Position arc (default anchor),
    // so keep its grab zone tight - the larger Position handle around it stays
    // clickable, and the anchor square is still grabbable at its centre.
    _anchorMini.hitRadiusPt = 3.0;
    // Keep the anchor square on the same member-local pivot the rings/box use, so
    // the gizmo cluster stays coincident.
    __weak CanvasMiniViewerRenderer *weakSelf = self;
    _anchorMini.centerOverride = ^CGPoint(CGRect cr) {
      return [weakSelf _anchorPivotForContentRect:cr];
    };
  }
  return self;
}

// Opt into the base renderer's 3-axis rotation rings (drawn + hit-tested +
// dragged by KKMiniViewerRenderer), keyed on the "Rotation" lane.
- (NSString *)rotationLabel {
  return @"Rotation";
}

// The Position handle draws ON TOP of the rotation rings (matching the main
// viewer's layering), so the mini hit-test / drag / opt-click prefer it where
// they overlap - without this the rings (checked first by default) steal clicks
// meant for the handle.
- (BOOL)pointHandleBeatsRotation {
  return YES;
}

// The member-local ANCHOR pivot (where the layer rotates / scales) in overlay
// points: Position + Anchor offset. 2D / member-local to match the viewer - the
// mini is clip-space (it renders the member ungrouped), so following the group's
// full transform here would put the gizmo where nothing is drawn. The rings still
// TILT with the group rotation (see rotationBaseMatrix).
- (CGPoint)_anchorPivotForContentRect:(CGRect)cr {
  NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
  NSArray<NSNumber *> *anc = [self valuesForLabel:@"Anchor"];
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  double ax = anc.count > 0 ? anc[0].doubleValue : 0.5;
  double ay = anc.count > 1 ? anc[1].doubleValue : 0.5;
  double pivX = px + ax - 0.5, pivY = py + ay - 0.5; // Position space (Y-down)
  return [self _handlePointForContentRect:cr position:@[ @(pivX), @(pivY) ]];
}

// The rotation rings (and scale box) centre on the member-local anchor pivot.
- (CGPoint)rotationCenterForContentRect:(CGRect)cr {
  return [self _anchorPivotForContentRect:cr];
}

// Rings tilt with the ancestor groups' rotation (drag stays member-local).
- (KKRotMatrix3)rotationBaseMatrix {
  KKBezierPath *sel =
      CanvasSelectedLayerForPaths(self.layers, self.selectedLayerID);
  return CanvasComposedGroupRotation(self.layers, sel, self.editFraction);
}

- (KKLane *)templateLaneForLabel:(NSString *)label {
  for (KKLane *l in self.laneTemplates)
    if ([l.label isEqualToString:label])
      return l;
  return [super templateLaneForLabel:label];
}

// Position is the only point handle; draw it as a ring (matches the viewer's
// KKArcOSC + MagicMove's mini), with the motion-path arc through its keyposes.
- (NSString *)pointLabel {
  return @"Position";
}

- (KKMiniHandleStyle)pointHandleStyle {
  return KKMiniHandleStyleArc;
}

// The Position handle is an arc (drawn on its own path), so this only sizes the
// scale-box corner/edge point handles - shrink them so they aren't oversized
// (matches MagicMove / Rounded).
- (CGFloat)pointHandleSizeScale {
  return 0.6;
}

// Canvas has no Crop lane, so suppress the base's default crop handles.
- (NSString *)cropLabel {
  return nil;
}

- (NSInteger)valueTypeForLabel:(NSString *)label {
  if ([label isEqualToString:@"Position"])
    return KKLaneValueTypeGeneric;
  if ([label isEqualToString:@"Rotation"])
    return KKLaneValueTypeAngle;
  return [super valueTypeForLabel:label];
}

// Must match the availableLanes template defaults (and the render reader's
// fallbacks); without an entry the base returns zeros, which would draw an
// untouched Position handle at the bottom-left corner instead of centred.
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  if ([label isEqualToString:@"Position"])
    return @[ @0.5, @0.5 ];
  if ([label isEqualToString:@"Scale"])
    return @[ @100.0, @100.0 ];
  if ([label isEqualToString:@"Rotation"])
    return @[ @0.0, @0.0, @0.0 ];
  return [super defaultValuesForLabel:label];
}

- (CGPoint)_handlePointForContentRect:(CGRect)cr
                             position:(NSArray<NSNumber *> *)pos {
  return [self handlePointForContentRect:cr position:pos];
}

// Selecting another layer must move the handle + recomposite the preview at
// once: the handle reads `timeline` (the host swaps it alongside this) and the
// composite scopes its live-override to this id, so force both to repaint
// instead of waiting for the next published source frame.
- (void)setSelectedLayerID:(NSString *)selectedLayerID {
  if (selectedLayerID == _selectedLayerID ||
      [selectedLayerID isEqualToString:_selectedLayerID])
    return;
  _selectedLayerID = [selectedLayerID copy];
  [self.canvas setNeedsDisplay:YES];
  [self.canvas setHandlesNeedDisplay];
}

- (NSMutableDictionary<NSString *, id<MTLTexture>> *)imageTextureCache {
  if (!_imageTextureCache)
    _imageTextureCache = [NSMutableDictionary dictionary];
  return _imageTextureCache;
}

// Source + image-overlay pipelines, built against `format` (the sRGB variant of
// the dest, so the shaders work in linear light). Both use the kit's shared
// shaders, which live in the KeyframelessKit framework bundle - Canvas ships no
// metallib of its own. Cached per format.
- (BOOL)_ensurePipelinesForDevice:(id<MTLDevice>)device
                      pixelFormat:(MTLPixelFormat)format {
  if (_pipeline && _imagePipeline && _pipelineFormat == format)
    return YES;
  NSError *err = nil;
  id<MTLLibrary> lib = [device
      newDefaultLibraryWithBundle:[NSBundle bundleForClass:[KKMiniViewerRenderer
                                                               class]]
                            error:&err];
  if (!lib) {
    KKLogError(@"CanvasMiniViewerRenderer: no kit metallib: %@", err);
    return NO;
  }
  id<MTLFunction> vfn = [lib newFunctionWithName:@"KKVertexShader"];
  // Image layers use the transform-aware vertex shader (per-layer 4x4 model +
  // perspective for 3D tilt), matching the main render's image pipeline so the
  // preview shows X/Y rotation, not just Z.
  id<MTLFunction> tvfn = [lib newFunctionWithName:@"KKTransformVertexShader"];
  id<MTLFunction> ffn =
      [lib newFunctionWithName:@"KKTexturePassthroughFragment"];
  // Image layers fade by a per-layer Opacity uniform (premultiplied multiply).
  id<MTLFunction> offn = [lib newFunctionWithName:@"KKTextureOpacityFragment"];
  if (!vfn || !tvfn || !ffn || !offn) {
    KKLogError(@"CanvasMiniViewerRenderer: missing passthrough shaders");
    return NO;
  }

  MTLRenderPipelineDescriptor *src = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:vfn
                                fragmentFunction:ffn
                                     pixelFormat:format
                                       blendMode:KKBlendModeNone];
  id<MTLRenderPipelineState> srcPS =
      [device newRenderPipelineStateWithDescriptor:src error:&err];
  if (!srcPS) {
    KKLogError(@"CanvasMiniViewerRenderer: source pipeline failed: %@", err);
    return NO;
  }

  MTLRenderPipelineDescriptor *img = [KKRenderPrimitives
      createPipelineDescriptorWithVertexFunction:tvfn
                                fragmentFunction:offn
                                     pixelFormat:format
                                       blendMode:KKBlendModePremultipliedAlpha];
  id<MTLRenderPipelineState> imgPS =
      [device newRenderPipelineStateWithDescriptor:img error:&err];
  if (!imgPS) {
    KKLogError(@"CanvasMiniViewerRenderer: image pipeline failed: %@", err);
    return NO;
  }

  _pipeline = srcPS;
  _imagePipeline = imgPS;
  _pipelineFormat = format;
  return YES;
}

// Runs the same compositing as the main render (Plugin+Render.m) in the
// inspector process: draw the source frame, then composite every visible image
// layer over it (shared CanvasEncodeImageLayers). Works in linear light through
// sRGB texture views so the preview matches the viewer.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  if (!source || !dest || !cb)
    return NO;
  if (source.width == 0 || source.height == 0 || dest.width == 0 ||
      dest.height == 0)
    return YES;

  MTLPixelFormat fmt = CanvasSRGBVariant(dest.pixelFormat);
  if (![self _ensurePipelinesForDevice:cb.device pixelFormat:fmt]) {
    // Fallback blit (same-format only) so a transient PSO failure doesn't show
    // black.
    if (source.pixelFormat == dest.pixelFormat) {
      id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
      NSUInteger w = MIN(source.width, dest.width);
      NSUInteger h = MIN(source.height, dest.height);
      [blit copyFromTexture:source
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(w, h, 1)
                  toTexture:dest
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
      [blit endEncoding];
    }
    return YES;
  }

  // Read source as linear (sRGB-decode on sample), write dest as linear
  // (sRGB-encode on store); fall back to the plain textures if no view applies.
  id<MTLTexture> srcLin =
      [source
          newTextureViewWithPixelFormat:CanvasSRGBVariant(source.pixelFormat)]
          ?: source;
  id<MTLTexture> dstSRGB = [dest newTextureViewWithPixelFormat:fmt] ?: dest;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dstSRGB;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];

  float w = (float)dest.width, h = (float)dest.height;
  MTLViewport vp = {0, 0, w, h, -1.0, 1.0};
  [enc setViewport:vp];
  simd_uint2 viewportSize = {(unsigned)w, (unsigned)h};
  [enc setVertexBytes:&viewportSize
               length:sizeof(viewportSize)
              atIndex:KKVertexInputIndex_ViewportSize];

  // 1) Source frame, full-screen.
  KKVertex2D srcQuad[4] = {
      {{w / 2.0f, -h / 2.0f}, {1, 1}},
      {{-w / 2.0f, -h / 2.0f}, {0, 1}},
      {{w / 2.0f, h / 2.0f}, {1, 0}},
      {{-w / 2.0f, h / 2.0f}, {0, 0}},
  };
  [enc setVertexBytes:srcQuad
               length:sizeof(srcQuad)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setRenderPipelineState:_pipeline];
  [enc setFragmentTexture:srcLin atIndex:KKTextureIndex_InputImage];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
          vertexStart:0
          vertexCount:4];

  // 2) Image layers over the source (shared with the main render), each
  // transformed at the renderer's current time. editFraction is the keypose /
  // boundary time when a popover is editing one (so the preview matches the
  // edited pose) and 0 otherwise (constants resolve correctly there).
  [enc setRenderPipelineState:_imagePipeline];
  // The mini renders the whole frame into one dest (no tiling), so image dims =
  // dest dims and the tile shift is zero.
  CanvasEncodeImageLayers(
      self.layers ?: @[], enc, cb.device, self.imageTextureCache, w, h, 0.0f,
      0.0f, self.editFraction, self.selectedLayerID, self.timeline);

  [enc endEncoding];
  return YES;
}

@end
