/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MeshMiniViewerRenderer.h"

#import "MeshColorSpace.h"
#import "MeshOSCRadiusMath.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKShaderTypes.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

NSString *const MeshMiniViewerDescriptorPath = @"/tmp/mesh-miniviewer.json";

NSString *const MeshMiniViewerRequestPath =
    @"/tmp/mesh-miniviewer-request.json";

NSString *MeshMiniViewerDescriptorPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MeshMiniViewerDescriptorPath;
  return [NSString stringWithFormat:@"/tmp/mesh-miniviewer-%@.json", uuid];
}

NSString *MeshMiniViewerRequestPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return MeshMiniViewerRequestPath;
  return
      [NSString stringWithFormat:@"/tmp/mesh-miniviewer-request-%@.json", uuid];
}

// Mini-viewer analog of the viewer OSC's `oscSize` (KKPointOSC oscRadius +
// outline). Kept in sync with KKMiniViewerView's kKKMiniHandleOuterPt so
// placement, hit-test and the drawn glyph all agree.
static inline CGFloat MiniOscSize(void) { return 4.5; }
static const CGFloat kHandleHitTolPt = 12.0;

@implementation MeshMiniViewerRenderer {
  id<MTLRenderPipelineState> _pipeline;
  MTLPixelFormat _pipelineFormat;
}

// No viewer handles yet - colours only. The draggable-vertex OSC lands with the
// warp/OSC increment; until then suppress the inherited radius/crop handles.
- (NSString *)cropLabel {
  return nil;
}
- (NSString *)pointLabel {
  return nil;
}
- (NSInteger)valueTypeForLabel:(NSString *)label {
  if ([label hasPrefix:@"Point "])
    return KKLaneValueTypeColorPoint;
  return KKLaneValueTypeFloat;
}
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  int i = MeshIndexForLabel(label, @"Point ");
  if (i >= 0 && i < KK_MESH_POINT_COUNT) {
    const float *p = kMeshDefaultPositions[i];
    const float *c = kMeshDefaultColorsSRGB[i];
    return @[
      @(p[0]), @(p[1]), @(KK_MESH_DEFAULT_SPREAD * 100.0), @(c[0]), @(c[1]),
      @(c[2]), @(c[3])
    ];
  }
  return [super defaultValuesForLabel:label];
}

- (BOOL)_ensurePipelineForDevice:(id<MTLDevice>)device
                     pixelFormat:(MTLPixelFormat)format {
  if (_pipeline && _pipelineFormat == format)
    return YES;
  NSError *err = nil;
  id<MTLLibrary> lib =
      [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:self.class]
                                    error:&err];
  if (!lib) {
    KKLogError(@"MeshMiniViewerRenderer: no metal library: %@", err);
    return NO;
  }
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [lib newFunctionWithName:@"vertexShader"];
  pd.fragmentFunction = [lib newFunctionWithName:@"fragmentShader"];
  pd.colorAttachments[0].pixelFormat = format;
  id<MTLRenderPipelineState> ps =
      [device newRenderPipelineStateWithDescriptor:pd error:&err];
  if (!ps) {
    KKLogError(@"MeshMiniViewerRenderer: pipeline failed: %@", err);
    return NO;
  }
  _pipeline = ps;
  _pipelineFormat = format;
  return YES;
}

// Generator render: no source. Runs the same Metal pipeline as the FCP render
// (vertexShader + solid-blue fragmentShader) straight into the preview dest.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    generateIntoTexture:(id<MTLTexture>)dest
          commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  if (![self _ensurePipelineForDevice:dest.device pixelFormat:dest.pixelFormat])
    return NO;

  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dest;
  rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
  rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  float W = (float)dest.width, H = (float)dest.height;
  MTLViewport vp = {0, 0, W, H, -1.0, 1.0};
  [e setViewport:vp];
  KKVertex2D verts[4] = {
      {{-W / 2, H / 2}, {0, 0}},
      {{-W / 2, -H / 2}, {0, 1}},
      {{W / 2, H / 2}, {1, 0}},
      {{W / 2, -H / 2}, {1, 1}},
  };
  simd_uint2 vpSize = {(unsigned)W, (unsigned)H};
  // Same point set as the FCP render, from this instance's "Point N" lanes at
  // the current edit fraction (valuesForLabel falls back to defaults).
  float pos[KK_MESH_POINT_COUNT][2];
  float spr[KK_MESH_POINT_COUNT];
  float col[KK_MESH_POINT_COUNT][4];
  for (int i = 0; i < KK_MESH_POINT_COUNT; i++) {
    NSArray<NSNumber *> *v = [self valuesForLabel:MeshPointLabel(i)];
    if (v.count >= 7) {
      pos[i][0] = v[0].floatValue;
      pos[i][1] = v[1].floatValue;
      spr[i] = v[2].floatValue / 100.0f; // stored as percent, shader wants 0..1
      for (int k = 0; k < 4; k++)
        col[i][k] = v[3 + k].floatValue;
    } else {
      pos[i][0] = kMeshDefaultPositions[i][0];
      pos[i][1] = kMeshDefaultPositions[i][1];
      spr[i] = KK_MESH_DEFAULT_SPREAD;
      for (int k = 0; k < 4; k++)
        col[i][k] = kMeshDefaultColorsSRGB[i][k];
    }
  }
  MeshGridUniforms grid = MeshBuildPoints(KK_MESH_POINT_COUNT, pos, spr, col);
  // Grain: same global overlay lane as the FCP render (valuesForLabel falls
  // back to the subclass default).
  NSArray<NSNumber *> *grainV = [self valuesForLabel:@"Grain"];
  grid.grain =
      grainV.count ? grainV[0].floatValue / 100.0f : KK_MESH_DEFAULT_GRAIN;
  // The mini-viewer renders into an 8-bit unorm texture shown directly on
  // screen, so gamma-encode (unlike FCP's linear float working buffer).
  int encodeSRGB = (dest.pixelFormat == MTLPixelFormatRGBA8Unorm ||
                    dest.pixelFormat == MTLPixelFormatBGRA8Unorm)
                       ? 1
                       : 0;
  [e setRenderPipelineState:_pipeline];
  [e setVertexBytes:verts
             length:sizeof(verts)
            atIndex:KKVertexInputIndex_Vertices];
  [e setVertexBytes:&vpSize
             length:sizeof(vpSize)
            atIndex:KKVertexInputIndex_ViewportSize];
  [e setFragmentBytes:&grid length:sizeof(grid) atIndex:MeshFragmentIndex_Grid];
  [e setFragmentBytes:&encodeSRGB
               length:sizeof(encodeSRGB)
              atIndex:MeshFragmentIndex_EncodeSRGB];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];
  return YES;
}

// Dead for the generator: no source is ever published to the mini-viewer feed,
// so the source path never runs (see -miniViewer:generateIntoTexture:). Kept as
// a no-op to satisfy the KKMiniViewerRenderer contract.
- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)commandBuffer {
  return NO;
}

- (double)_currentRadius {
  return [[self valuesForLabel:@"Radius"] firstObject].doubleValue;
}

// The radius handle is linked to the crop box: inset diagonally from the
// crop rect's top-right corner by `MiniOscSize + paddingForRadius(radius,
// minDim)` (minDim = crop's min edge; the shader rounds corners relative to
// crop size). Full-image crop ⇒ crop rect == content rect ⇒ fixed corner.
- (CGRect)_anchorRectForContentRect:(CGRect)cr {
  CGRect crop = [self cropRectForContentRect:cr];
  return CGRectIsEmpty(crop) ? cr : crop;
}

- (CGPoint)_handlePointForContentRect:(CGRect)cr radius:(double)radius {
  CGRect a = [self _anchorRectForContentRect:cr];
  float minDim = (float)MIN(a.size.width, a.size.height);
  float off = (float)MiniOscSize() + paddingForRadius(radius, minDim);
  return CGPointMake(CGRectGetMaxX(a) - off, CGRectGetMaxY(a) - off);
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter forContentRect:(CGRect)cr {
  *outCenter = [self _handlePointForContentRect:cr
                                         radius:[self _currentRadius]];
  return YES;
}

- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)radius
           forContentRect:(CGRect)cr {
  *outCenter = [self _handlePointForContentRect:cr radius:radius];
  return YES;
}

- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  CGPoint hp = [self _handlePointForContentRect:cr
                                         radius:[self _currentRadius]];
  return hypot(p.x - hp.x, p.y - hp.y) <= kHandleHitTolPt;
}

- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)cr
                       canvas:(KKMiniViewerView *)canvas {
  CGRect a = [self _anchorRectForContentRect:cr];
  float minDim = (float)MIN(a.size.width, a.size.height);
  if (minDim <= 0)
    return;
  // Exact inverse of the viewer-OSC drag: project the cursor onto the corner
  // diagonal, then bisect paddingForRadius to recover the radius.
  double trx = CGRectGetMaxX(a), tryy = CGRectGetMaxY(a);
  double mouseDist = ((trx - p.x) + (tryy - p.y)) * 0.5 - MiniOscSize();
  float lo = 0.0f, hi = 100.0f;
  for (int i = 0; i < 32; i++) {
    float mid = (lo + hi) * 0.5f;
    if (paddingForRadius(mid, minDim) < mouseDist)
      lo = mid;
    else
      hi = mid;
  }
  double radius = MAX(0.0, MIN(100.0, (lo + hi) * 0.5));
  [self commitValues:@[ @(radius) ] forLabel:@"Radius" canvas:canvas];
}

@end
