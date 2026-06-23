/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasCornerFillet.h" // CanvasPathByExpandingCorners
#import "CanvasLayerRender.h"  // CanvasProjectLayerPointObj
#import "CanvasLayerTimeline.h" // blob/UIState snapshot get + set
#import "CanvasLayerTree.h"     // CanvasDeleteLayersByID
#import "CanvasOSC_Private.h"
#import "CanvasPathOSC.h" // CanvasDrawPathOpPreview
#import "CanvasPathOps.h" // shared op cores + preview (viewer + mini)
#import "Constants.h"     // kParamLayerData / kParamUIState
#import <FxPlug/FxPlugSDK.h>
#import <Metal/Metal.h>

@implementation CanvasOSC (PathOps)

// Render the path-op fill preview to an RGBA texture at the destination's pixel
// size, via the shared CG renderer (operands red / result green, fill + stroke,
// transparency-layer composited). The viewer's projection maps object -> canvas
// (= destination) px.
- (id<MTLTexture>)_pathOpFillTextureForDest:(FxImageTile *)dest
                                   operands:(NSArray<KKBezierPath *> *)operands
                                    results:(NSArray<KKBezierPath *> *)results
                                       frac:(double)frac
                                     aspect:(float)aspect {
  NSInteger w = (NSInteger)[dest.ioSurface width];
  NSInteger h = (NSInteger)[dest.ioSurface height];
  if (w <= 0 || h <= 0)
    return nil;
  CGFloat refW = 0, refH = 0;
  [self _outlineRefWidth:&refW height:&refH];
  __weak CanvasOSC *weakSelf = self;
  CGContextRef ctx = CanvasRenderPathOpFillBitmap(
      operands, results, [self _snapshotPaths], frac, aspect, w, h, refW,
      ^CGPoint(simd_float2 objYUp) {
        return [weakSelf canvasPointFromObjectPoint:simd_make_float2(
                                                        objYUp.x,
                                                        1.0f - objYUp.y)];
      });
  if (!ctx)
    return nil;
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  id<MTLDevice> dev = [cache deviceWithRegistryID:dest.deviceRegistryID];
  id<MTLTexture> tex = CanvasFillBitmapToTexture(ctx, dev, w, h);
  CGContextRelease(ctx);
  return tex;
}

// Blit the cached fill texture over the destination (preserve existing content).
- (void)_blitPathOpFillTexture:(id<MTLTexture>)tex
                        toDest:(FxImageTile *)dest {
  if (!tex)
    return;
  float ioW = [dest.ioSurface width];
  float ioH = [dest.ioSurface height];
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t reg = dest.deviceRegistryID;
  MTLPixelFormat fmt = [KKMetalDeviceCache pixelFormatForImageTile:dest];
  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:
          @"co.overpolish.keyframeless.Canvas.OpFill"
                                    registryID:reg
                                   pixelFormat:fmt
                                      bundleID:@"co.overpolish.keyframeless."
                                               @"KeyframelessKit"
                                  vertexShader:@"KKVertexShader"
                                fragmentShader:@"KKLabelFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!ps)
    return;
  id<MTLCommandQueue> q = [cache commandQueueWithRegistryID:reg pixelFormat:fmt];
  if (!q)
    return;
  id<MTLTexture> outTex =
      [dest metalTextureForDevice:[cache deviceWithRegistryID:reg]];
  id<MTLCommandBuffer> buf = [q commandBuffer];
  [buf enqueue];
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = outTex;
  rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> enc =
      [buf renderCommandEncoderWithDescriptor:rpd];
  MTLViewport vp = {0, 0, ioW, ioH, -1.0, 1.0};
  [enc setViewport:vp];
  [enc setRenderPipelineState:ps];
  simd_uint2 vpSize = {(unsigned int)ioW, (unsigned int)ioH};
  [enc setVertexBytes:&vpSize
               length:sizeof(vpSize)
              atIndex:KKVertexInputIndex_ViewportSize];
  float hw = ioW / 2.0f, hh = ioH / 2.0f;
  KKVertex2D verts[6] = {
      {{-hw, -hh}, {0, 0}}, {{hw, -hh}, {1, 0}}, {{hw, hh}, {1, 1}},
      {{-hw, -hh}, {0, 0}}, {{hw, hh}, {1, 1}},  {{-hw, hh}, {0, 1}},
  };
  [enc setVertexBytes:verts
               length:sizeof(verts)
              atIndex:KKVertexInputIndex_Vertices];
  [enc setFragmentTexture:tex atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  [enc endEncoding];
  [buf commit];
  [buf waitUntilScheduled];
  [cache returnCommandQueueToCache:q];
}

// Hover preview: while the pointer is over a path-op toolbar button (cursor tool
// only), fill the operands red + the would-be result green (translucent) so the
// outcome is visible before committing. The fill is a CG-rendered texture
// (handles concave / holed boolean results), cached + blitted over the viewer.
- (void)_drawPathOpHoverPreviewInDestination:(FxImageTile *)dest
                                      atTime:(CMTime)time {
  BOOL outline = NO;
  KKBooleanOp op = KKBooleanOpUnion;
  if ([self _activeTool] != CanvasToolbarToolCursor ||
      !CanvasToolbarTagToPathOp(self.toolbar.hoveredTag, &outline, &op)) {
    self.pathOpFillTexture = nil;
    self.pathOpFillSig = nil;
    return;
  }
  CGFloat rw = 0, rh = 0;
  [self _outlineRefWidth:&rw height:&rh];
  NSArray<KKBezierPath *> *paths = [self _snapshotPaths];
  NSArray<KKBezierPath *> *operands = nil, *results = nil;
  if (!CanvasPathOpPreview(paths, [self _selectedLayerIDs], outline, op, rw, rh,
                           &operands, &results)) {
    self.pathOpFillTexture = nil;
    self.pathOpFillSig = nil;
    return;
  }
  double frac = [self fractionAtTime:time];
  float aspect = (float)[self _canvasAspect];
  NSInteger w = (NSInteger)[dest.ioSurface width];
  NSInteger h = (NSInteger)[dest.ioSurface height];
  // Rebuild only when the op / selection / playhead / dest size / VIEW (zoom +
  // pan) changes - a still hover then reuses the cached texture. The projection
  // of two corners captures zoom + pan (which move + scale the fill), so a zoom
  // without a drawable-size change still invalidates.
  CGPoint vp00 = [self canvasPointFromObjectPoint:simd_make_float2(0.0f, 0.0f)];
  CGPoint vp11 = [self canvasPointFromObjectPoint:simd_make_float2(1.0f, 1.0f)];
  NSString *sig = [NSString
      stringWithFormat:@"%ld|%@|%.4f|%ldx%ld|%.1f,%.1f,%.1f,%.1f",
                       (long)self.toolbar.hoveredTag,
                       [[self _selectedLayerIDs] componentsJoinedByString:@","],
                       frac, (long)w, (long)h, vp00.x, vp00.y, vp11.x, vp11.y];
  if (!self.pathOpFillTexture || ![sig isEqualToString:self.pathOpFillSig]) {
    self.pathOpFillTexture = [self _pathOpFillTextureForDest:dest
                                                    operands:operands
                                                     results:results
                                                        frac:frac
                                                      aspect:aspect];
    self.pathOpFillSig = sig;
  }
  [self _blitPathOpFillTexture:self.pathOpFillTexture toDest:dest];
}

// Decode the published blob (the OSC can't read the param), run an op core on
// it, and commit the result if it changed anything. `block` returns the new
// selection IDs (or nil for a no-op). The boolean / outline cores run on the
// STORED path geometry (per-layer transform animation isn't baked in - a known
// limitation matching the pre-v3 behaviour).
- (void)_runPathOp:(NSArray<NSString *> *_Nullable (^)(
                       NSMutableArray<KKBezierPath *> *paths,
                       NSArray<NSString *> *selIDs))block {
  NSString *b64 = CanvasLayerBlobSnapshot();
  NSMutableArray<KKBezierPath *> *paths =
      b64.length
          ? [KKBezierPath
                pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64
                                                                  options:0]]
          : [NSMutableArray array];
  NSArray<NSString *> *newSel = block(paths, [self _selectedLayerIDs]);
  if (!newSel)
    return; // no-op
  [self _commitPathOpPaths:paths selectLayerIDs:newSel];
}

- (void)_handlePathBooleanOp:(KKBooleanOp)op {
  float aspect = (float)[self _canvasAspect];
  [self _runPathOp:^NSArray<NSString *> *(NSMutableArray<KKBezierPath *> *paths,
                                          NSArray<NSString *> *selIDs) {
    return CanvasApplyBooleanOp(paths, selIDs, op, aspect);
  }];
}

// Stroke width is px relative to the render output; the on-screen canvas px the
// OSC knows is zoom-dependent, so resolve the TRUE output px the render published
// (CanvasOutputSize). Falls back to a 1080-tall, aspect-correct reference before
// the first render has published a size.
- (void)_outlineRefWidth:(CGFloat *)outW height:(CGFloat *)outH {
  float ow = 0.0f, oh = 0.0f;
  if (CanvasOutputSize(&ow, &oh)) {
    *outW = (CGFloat)ow;
    *outH = (CGFloat)oh;
  } else {
    *outH = 1080.0;
    *outW = (CGFloat)(1080.0 * [self _canvasAspect]);
  }
}

- (BOOL)_deleteSelectedLayers {
  NSArray<NSString *> *sel = [self _selectedLayerIDs];
  if (sel.count == 0)
    return NO;
  NSString *b64 = CanvasLayerBlobSnapshot();
  NSMutableArray<KKBezierPath *> *paths =
      b64.length
          ? [KKBezierPath
                pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64
                                                                  options:0]]
          : [NSMutableArray array];
  NSUInteger before = paths.count;
  CanvasDeleteLayersByID(paths, sel);
  if (paths.count == before)
    return NO; // selection didn't match any layer - nothing removed
  // Leave the selection EMPTY after a delete (matches the canvas empty-selection
  // model: Figma/Illustrator/AE-style), rather than picking a survivor.
  [self _commitPathOpPaths:paths selectLayerIDs:@[]];
  return YES;
}

- (void)_handleOutlineOp {
  CGFloat refW = 0, refH = 0;
  [self _outlineRefWidth:&refW height:&refH];
  [self _runPathOp:^NSArray<NSString *> *(NSMutableArray<KKBezierPath *> *paths,
                                          NSArray<NSString *> *selIDs) {
    return CanvasApplyOutlineOp(paths, selIDs, refW, refH);
  }];
}

// Write the new layer stack + select the result (single selection) in ONE undo
// action: both the blob and the UIState selection keys go inside the same action
// scope so an undo restores the operands AND the prior selection together. Keep
// the snapshots in step so the next OSC draw + the inspector reload see the new
// values before the param round-trip republishes them.
- (void)_commitPathOpPaths:(NSArray<KKBezierPath *> *)paths
            selectLayerIDs:(NSArray<NSString *> *)ids {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!actionAPI || !setAPI)
    return;

  NSString *newB64 =
      [[KKBezierPath blobFromPaths:paths] base64EncodedStringWithOptions:0];

  NSMutableDictionary *state = [[self _uiStateDict] mutableCopy];
  state[@"selectedLayerID"] = ids.firstObject ?: @"";
  state[@"selectedLayerIDs"] = ids ?: @[];
  NSString *uiJSON = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];

  [actionAPI startAction:self];
  KKWriteCustomParamString(setAPI, newB64, kParamLayerData);
  KKWriteCustomParamString(setAPI, uiJSON, kParamUIState);
  [actionAPI endAction:self];

  CanvasSetLayerBlobSnapshot(newB64);
  CanvasSetUIStateSnapshot(uiJSON);
}

@end
