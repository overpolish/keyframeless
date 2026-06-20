/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasMiniViewerRenderer.h"
#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h"
#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasToolbar.h"
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKToolbar.h>
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
    // Grid snap (when the shared Snap toggle is on); no-op otherwise. Position
    // snaps its value; the anchor snaps its PIVOT - both are normalized object
    // points, so they share one helper, matching the viewer.
    _positionMini.gridSnapValue = ^simd_float2(simd_float2 v, CGRect cr) {
      return [weakSelf _snapNormalizedPointToGrid:v contentRect:cr];
    };
    _anchorMini.gridSnapPivot = ^simd_float2(simd_float2 pivot, CGRect cr) {
      return [weakSelf _snapNormalizedPointToGrid:pivot contentRect:cr];
    };
    // Drag follows the cursor through the group transform (invert the draw
    // homography), so a grouped member's handle doesn't drift - matching the
    // viewer. Identity for an ungrouped layer.
    _positionMini.viewToValue = ^simd_float2(CGPoint vp, CGRect cr) {
      return [weakSelf _memberValueForViewPoint:vp contentRect:cr];
    };
    _anchorMini.viewToValue = ^simd_float2(CGPoint vp, CGRect cr) {
      return [weakSelf _memberValueForViewPoint:vp contentRect:cr];
    };
    // The same toolbar as the viewer (shared builder), scaled down for the small
    // mini surface. apiManager nil is fine (KKToolbar only stores it).
    _toolbar = CanvasMakeToolbar(nil); // uiScale + flip set per-draw in the hook
    _toolbarNormPos = CGPointMake(-1, -1); // default anchor until dragged
  }
  return self;
}

// Toolbar chrome: drive the per-draw state from the shared kParamUIState the
// inspector mirrors onto us, then render the SAME bar as the viewer into the
// mini's Metal pass via KKToolbar's shared encoder path.
- (void)miniViewer:(KKMiniViewerView *)canvas
    drawToolbarInEncoder:(id<MTLRenderCommandEncoder>)encoder
                  device:(id<MTLDevice>)device
                pipeline:(id<MTLRenderPipelineState>)pipeline
           viewportWidth:(float)width
                  height:(float)height {
  if (!self.toolbar)
    return;
  // The mini's MTKView pass is Y-flipped vs the viewer's FxPlug surface.
  self.toolbar.flipVertical = YES;
  // Scale the bar with the popover like the OSC glyphs (baseline 230pt). The
  // 0.75 factor matches the bar's on-screen weight to the viewer's (the mini
  // surface is small, so native size is proportionally too big).
  CGFloat ratio = canvas.oscSizingHeight / 230.0;
  self.toolbar.uiScale = (ratio > 0.1 ? ratio : 1.0) * 0.75;
  NSInteger tool = self.toolbarTool ?: CanvasToolbarToolCursor;
  CanvasToolbarApplyState(self.toolbar, tool, self.gridEnabled,
                          self.gridAdaptive, self.gridSnap, self.gridSpacing);

  if (self.toolbarNormPos.x >= 0 && self.toolbarNormPos.y >= 0) {
    self.toolbar.usesAnchorCenter = YES;
    self.toolbar.anchorCenter = CGPointMake(self.toolbarNormPos.x * width,
                                            self.toolbarNormPos.y * height);
  } else {
    self.toolbar.usesAnchorCenter = NO;
  }
  [self.toolbar drawInEncoder:encoder
                       device:device
                     pipeline:pipeline
                viewportWidth:width
                       height:height];
}

// View point (y-up) -> the toolbar's hit/layout space (drawable px). The render
// is Y-mirrored AND the view is y-up, so the two flips cancel: (vx*s, vy*s)
// lands directly in the bar's y-down layout rects.
- (CGPoint)_toolbarPointForViewPoint:(CGPoint)vp canvas:(KKMiniViewerView *)c {
  CGFloat s = c.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  return CGPointMake(vp.x * s, vp.y * s);
}

- (NSInteger)miniViewer:(KKMiniViewerView *)canvas
       toolbarTagAtPoint:(CGPoint)viewPoint {
  if (!self.toolbar)
    return 0;
  CGPoint p = [self _toolbarPointForViewPoint:viewPoint canvas:canvas];
  return [self.toolbar hitTestAtX:p.x y:p.y];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    toolbarMouseDownAtPoint:(CGPoint)viewPoint {
  if (!self.toolbar)
    return NO;
  CGPoint p = [self _toolbarPointForViewPoint:viewPoint canvas:canvas];
  NSInteger tag = [self.toolbar hitTestAtX:p.x y:p.y];
  void (^patch)(NSString *, id) = self.onPatchUIState;
  switch (tag) {
  case CanvasToolbarDragHandle: {
    self.toolbarDragging = YES;
    self.toolbarPressMouse = p;
    NSRect f = self.toolbar.toolbarFrame;
    self.toolbarPressAnchor = CGPointMake(NSMidX(f), NSMidY(f));
    return YES;
  }
  case CanvasToolbarToolCursor:
  case CanvasToolbarToolPen:
  case CanvasToolbarToolRect:
  case CanvasToolbarToolEllipse:
    self.toolbarTool = tag;
    if (patch)
      patch(@"tool", @(tag));
    break;
  case CanvasToolbarGrid:
    self.gridEnabled = !self.gridEnabled;
    if (patch)
      patch(@"gridEnabled", @(self.gridEnabled));
    break;
  case CanvasToolbarGridAdaptive:
    self.gridAdaptive = !self.gridAdaptive;
    if (patch)
      patch(@"gridAdaptive", @(self.gridAdaptive));
    break;
  case CanvasToolbarSnap:
    self.gridSnap = !self.gridSnap;
    if (patch)
      patch(@"gridSnap", @(self.gridSnap));
    break;
  case CanvasToolbarGridSpacing: {
    NSInteger next = CanvasToolbarNextGridSpacing(self.gridSpacing);
    self.gridSpacing = next;
    if (patch)
      patch(@"gridSpacing", @(next));
    break;
  }
  default:
    break;
  }
  [canvas setNeedsDisplay:YES];
  return NO;
}

// Control+letter tool shortcuts, mirroring the viewer (V=cursor, X=pen,
// B=rect, G=ellipse). charactersIgnoringModifiers gives the plain letter.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
       toolbarKeyDownChars:(NSString *)chars
                 modifiers:(NSEventModifierFlags)modifiers {
  if (!(modifiers & NSEventModifierFlagControl) || chars.length == 0)
    return NO;
  NSInteger tag = CanvasToolbarToolTagForLetter(
      [chars.lowercaseString characterAtIndex:0]);
  if (tag == 0)
    return NO;
  self.toolbarTool = tag;
  if (self.onPatchUIState)
    self.onPatchUIState(@"tool", @(tag));
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    toolbarDraggedToPoint:(CGPoint)viewPoint {
  if (!self.toolbarDragging)
    return;
  CGSize d = canvas.drawableSize;
  if (d.width <= 0 || d.height <= 0)
    return;
  CGPoint p = [self _toolbarPointForViewPoint:viewPoint canvas:canvas];
  CGFloat ax = self.toolbarPressAnchor.x + (p.x - self.toolbarPressMouse.x);
  CGFloat ay = self.toolbarPressAnchor.y + (p.y - self.toolbarPressMouse.y);
  // Clamp to [0,1]: a normalised component must stay >= 0 (the draw hook reads
  // {-1,-1} as "unset -> default anchor", so a negative value when the mouse
  // leaves the bottom/left edge would snap the bar back to its default). KKToolbar
  // still does the fine on-screen clamp of the centre.
  double nx = fmax(0.0, fmin(1.0, ax / d.width));
  double ny = fmax(0.0, fmin(1.0, ay / d.height));
  self.toolbarNormPos = CGPointMake(nx, ny);
  [canvas setNeedsDisplay:YES];
}

- (void)miniViewerToolbarMouseUp:(KKMiniViewerView *)canvas {
  if (!self.toolbarDragging)
    return;
  self.toolbarDragging = NO;
  if (self.onPatchUIState && self.toolbarNormPos.x >= 0)
    self.onPatchUIState(
        @"miniToolbarPos",
        @[ @(self.toolbarNormPos.x), @(self.toolbarNormPos.y) ]);
}

- (void)miniViewer:(KKMiniViewerView *)canvas toolbarHoverTag:(NSInteger)tag {
  if (!self.toolbar || self.toolbar.hoveredTag == tag)
    return;
  self.toolbar.hoveredTag = tag;
  [canvas setNeedsDisplay:YES];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
     toolbarCursorForTag:(NSInteger)tag {
  return tag == CanvasToolbarDragHandle ? KKPointMoveCursor() : nil;
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

// Group-compose every overlay point. The mini composites the FULL group
// transform (CanvasEncodeImageLayers, same as the main render), so a grouped
// member is drawn at its group-composed spot - run the Position handle, motion
// path, anchor pivot and the scale-box / rotation centre through the same
// ancestor-group composition so the controls land on the member where it's
// actually drawn, matching the viewer. Identity for an ungrouped layer / group
// selection (so those are unchanged). `position` is Position space (Y-down); the
// composition runs in object space (Y-up), hence the flips.
- (CGPoint)handlePointForContentRect:(CGRect)cr
                            position:(NSArray<NSNumber *> *)pos {
  double mx = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double my = pos.count > 1 ? pos[1].doubleValue : 0.5;
  KKBezierPath *sel =
      CanvasSelectedLayerForPaths(self.layers, self.selectedLayerID);
  if (sel && cr.size.height > 0) {
    float aspect = (float)(cr.size.width / cr.size.height);
    float gx = (float)mx, gy = (float)(1.0 - my);
    CanvasComposedGroupPointObj(self.layers, sel, self.editFraction, aspect,
                                (float)mx, (float)(1.0 - my), &gx, &gy);
    return [super handlePointForContentRect:cr
                                   position:@[ @(gx), @(1.0 - (double)gy) ]];
  }
  return [super handlePointForContentRect:cr position:pos];
}

// The member-local ANCHOR pivot (where the layer rotates / scales) in Position
// space: Position + Anchor offset. handlePointForContentRect: applies the group
// composition, so this stays member-local and the gizmo cluster (rings + box +
// square) lands on the group-composed pivot, matching the viewer.
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

// The effective grid cell as a fraction of the content rect (spacing is in
// output pixels, matching the viewer, so the fraction is spacing / renderWidth
// (or Height)). Auto doubles it while the on-screen cell gets too small. Does
// NOT gate on gridEnabled - callers (draw vs snap) apply their own gate.
- (BOOL)_effectiveGridNX:(double *)outNX
                     nY:(double *)outNY
          forContentRect:(CGRect)cr {
  if (self.renderWidth <= 0 || self.renderHeight <= 0 || cr.size.width <= 0)
    return NO;
  double spacing = self.gridSpacing > 0 ? (double)self.gridSpacing : 10.0;
  double nx = spacing / self.renderWidth, ny = spacing / self.renderHeight;
  if (self.gridAdaptive) {
    while (nx * cr.size.width < 24.0 && spacing < 100000.0) {
      spacing *= 2.0;
      nx *= 2.0;
      ny *= 2.0;
    }
  }
  if (nx <= 0 || ny <= 0)
    return NO;
  *outNX = nx;
  *outNY = ny;
  return YES;
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
      gridSpacingX:(CGFloat *)outSpacingX
          spacingY:(CGFloat *)outSpacingY
       contentRect:(CGRect)cr {
  double nx = 0, ny = 0;
  if (!self.gridEnabled || ![self _effectiveGridNX:&nx nY:&ny forContentRect:cr])
    return NO;
  // Cache for the snap so it pins to exactly these lines (no recompute drift).
  self.drawnGridNX = nx;
  self.drawnGridNY = ny;
  *outSpacingX = nx;
  *outSpacingY = ny;
  return YES;
}

// Snap a normalized object point to the nearest grid intersection (no-op unless
// Snap is on). Shared by the Position handle and the Anchor pivot via the mini
// controllers' grid-snap blocks. Mirrors the viewer's _snapCanvasPointToGrid.
// The value->view homography for the selected member: maps a member-local
// normalized point to its drawn (group-composed) view point. Built from the 4
// corners via handlePointForContentRect (identity for an ungrouped layer). Its
// inverse maps a view point back to the member value - used by the drag (follow
// the cursor under a group transform) and the snap (snap where it visually sits).
- (simd_float3x3)_homographyForContentRect:(CGRect)cr {
  CGPoint q0 = [self handlePointForContentRect:cr position:@[ @0, @0 ]];
  CGPoint q1 = [self handlePointForContentRect:cr position:@[ @1, @0 ]];
  CGPoint q2 = [self handlePointForContentRect:cr position:@[ @1, @1 ]];
  CGPoint q3 = [self handlePointForContentRect:cr position:@[ @0, @1 ]];
  return CanvasSquareToQuadHomography(q0, q1, q2, q3);
}

- (simd_float2)_memberValueForViewPoint:(CGPoint)vp contentRect:(CGRect)cr {
  simd_float3 v = simd_mul(simd_inverse([self _homographyForContentRect:cr]),
                           simd_make_float3((float)vp.x, (float)vp.y, 1.0f));
  if (fabs(v.z) < 1e-6)
    return (simd_float2){0.5f, 0.5f};
  return (simd_float2){v.x / v.z, v.y / v.z};
}

- (simd_float2)_snapNormalizedPointToGrid:(simd_float2)p
                              contentRect:(CGRect)cr {
  // No snap unless the grid is both shown AND snap is on.
  if (!self.gridEnabled || !self.gridSnap)
    return p;
  double nx = self.drawnGridNX, ny = self.drawnGridNY;
  if (nx <= 0 || ny <= 0 || cr.size.width <= 0 || cr.size.height <= 0)
    return p;
  double cellX = nx * cr.size.width, cellY = ny * cr.size.height;
  if (cellX <= 0 || cellY <= 0)
    return p;
  // Snap where the handle VISUALLY sits (group-composed), then invert back to the
  // member value, so a grouped member lands on the visible grid lines.
  simd_float3x3 A = [self _homographyForContentRect:cr];
  CGPoint cv = [self handlePointForContentRect:cr
                                      position:@[ @(p.x), @(p.y) ]];
  double gx = cr.origin.x + round((cv.x - cr.origin.x) / cellX) * cellX;
  double gy = cr.origin.y + round((cv.y - cr.origin.y) / cellY) * cellY;
  simd_float3 v =
      simd_mul(simd_inverse(A), simd_make_float3((float)gx, (float)gy, 1.0f));
  if (fabs(v.z) < 1e-6)
    return p;
  return (simd_float2){v.x / v.z, v.y / v.z};
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
  self.renderWidth = w;
  self.renderHeight = h;
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
