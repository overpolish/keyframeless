/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasMiniViewerRenderer.h"
#import "CanvasFillRender.h" // TEMP solid fill for closed paths
#import "CanvasLayerRender.h"
#import "CanvasLayerTimeline.h"
#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasPathOps.h" // shared boolean / outline op cores
#import "CanvasToolbar.h"
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <KeyframelessKit/KKToolbar.h>
#import <Metal/Metal.h>

NSString *const CanvasMiniViewerDescriptorPath = @"/tmp/canvas-miniviewer.json";
NSString *const CanvasMiniViewerRequestPath =
    @"/tmp/canvas-miniviewer-request.json";

@implementation CanvasMiniViewerRenderer

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
    // The anchor pivot can sit dead-centre on the Position arc (default
    // anchor), so keep its grab zone tight - the larger Position handle around
    // it stays clickable, and the anchor square is still grabbable at its
    // centre.
    _anchorMini.hitRadiusPt = 3.0;
    // Keep the anchor square on the same member-local pivot the rings/box use,
    // so the gizmo cluster stays coincident.
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
    // The same toolbar as the viewer (shared builder), scaled down for the
    // small mini surface. apiManager nil is fine (KKToolbar only stores it).
    _toolbar = CanvasMakeToolbar(
        nil, NO, NO,
        NO); // uiScale + flip set per-draw in the hook (no path ops)
    _toolbarNormPos = CGPointMake(-1, -1); // default anchor until dragged
    _penController = [[CanvasPenController alloc] initWithSurface:self];
    _pathEditController =
        [[CanvasPathEditController alloc] initWithSurface:self];
    _shapeController = [[CanvasShapeController alloc] initWithSurface:self];
  }
  return self;
}

// Opt into the base renderer's 3-axis rotation rings (drawn + hit-tested +
// dragged by KKMiniViewerRenderer), keyed on the "Rotation" lane - but ONLY for
// a lone image/group under the cursor tool. The kit draws + hit-tests rings
// purely on this opt-in (bypassing -_transformHandlesActive), and the
// rotationCenter/baseMatrix overrides fall back to the topmost layer, so
// without this gate a stale ring would draw on the top layer when nothing (or a
// path / multi) is selected.
- (NSString *)rotationLabel {
  return [self _transformHandlesActive] ? @"Rotation" : nil;
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
// selection (so those are unchanged). `position` is Position space (Y-down);
// the composition runs in object space (Y-up), hence the flips.
- (CGPoint)handlePointForContentRect:(CGRect)cr
                            position:(NSArray<NSNumber *> *)pos {
  double mx = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double my = pos.count > 1 ? pos[1].doubleValue : 0.5;
  KKBezierPath *sel =
      CanvasSelectedLayerForPaths(self.layers, self.selectedLayerID);
  if (sel && cr.size.height > 0) {
    float aspect = (float)(cr.size.width / cr.size.height);
    // Centre the gizmo on the layer's GEOMETRY (bbox centre), so Position=0.5
    // lands on a path drawn off-centre - the same (objectCentre-0.5)
    // member-local pre-translation the viewer folds into parentObjectTransform.
    // No-op for a full-frame image / group (centre 0.5). Object centre is
    // render Y-UP. This is the GIZMO mapping; the pen/path-edit OSC use the raw
    // base map (their points are already in - or being defined in - geometry
    // space).
    simd_float2 gc = CanvasLayerObjectCenter(sel);
    float lx = (float)mx + (gc.x - 0.5f); // Y-up member-local
    float lyUp = (float)(1.0 - my) + (gc.y - 0.5f);
    float gx = lx, gy = lyUp;
    CanvasComposedGroupPointObj(self.layers, sel, self.editFraction, aspect, lx,
                                lyUp, &gx, &gy);
    return [super handlePointForContentRect:cr
                                   position:@[ @(gx), @(1.0 - (double)gy) ]];
  }
  return [super handlePointForContentRect:cr position:pos];
}

// The member-local ANCHOR pivot (where the layer rotates / scales) in Position
// space: Position + Anchor offset. handlePointForContentRect: applies the group
// composition, so this stays member-local and the gizmo cluster (rings + box +
// square) lands on the group-composed pivot, matching the viewer.
// The group's frozen content-centre rest (the reference the Anchor offset is
// measured from); clip centre for an image/path or an unseeded/legacy group.
- (simd_float2)_anchorReferenceCenter {
  return CanvasLayerGroupRest(
      CanvasSelectedLayerForPaths(self.layers, self.selectedLayerID));
}

// Scale-from-anchor fraction for the mini scale box: the Anchor lane relative
// to the layer's reference (clip centre, or a group's frozen rest) over its
// content half-extent (0.5 for a clip-filling image, bbox half for a
// group/path), so the box keeps the anchor as the fixed point. Mirrors the
// viewer (CanvasOSC scale).
- (CGPoint)scaleAnchorFrac {
  KKBezierPath *sel =
      CanvasSelectedLayerForPaths(self.layers, self.selectedLayerID);
  NSArray<NSNumber *> *a = [self valuesForLabel:@"Anchor"];
  if (!sel || a.count < 2)
    return CGPointZero;
  simd_float2 ref = [self _anchorReferenceCenter];
  float hx = 0.5f, hy = 0.5f;
  CanvasLayerContentHalfExtentObj(self.layers, sel, &hx, &hy);
  return KKScaleGizmoAnchorFrac(a[0].doubleValue, a[1].doubleValue, ref.x,
                                ref.y, hx, hy);
}

- (CGPoint)_anchorPivotForContentRect:(CGRect)cr {
  NSArray<NSNumber *> *pos = [self valuesForLabel:@"Position"];
  NSArray<NSNumber *> *anc = [self valuesForLabel:@"Anchor"];
  double px = pos.count > 0 ? pos[0].doubleValue : 0.5;
  double py = pos.count > 1 ? pos[1].doubleValue : 0.5;
  double ax = anc.count > 0 ? anc[0].doubleValue : 0.5;
  double ay = anc.count > 1 ? anc[1].doubleValue : 0.5;
  // Pivot = Position + (Anchor - reference). reference is the clip centre for
  // an image/path, or the group's frozen content-centre rest, so the gizmo
  // cluster
  // + anchor square land on the content and pan behind as the Anchor is
  // dragged.
  simd_float2 ref = [self _anchorReferenceCenter];
  self.anchorMini.anchorReferenceCenter = ref; // keep the snap math in sync
  double pivX = px + ax - ref.x,
         pivY = py + ay - ref.y; // Position space (Y-down)
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
      gridSpacingX:(out CGFloat *)outSpacingX
          spacingY:(out CGFloat *)outSpacingY
       contentRect:(CGRect)cr {
  double nx = 0, ny = 0;
  if (!self.gridEnabled || ![self _effectiveGridNX:&nx
                                                nY:&ny
                                    forContentRect:cr])
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
// the cursor under a group transform) and the snap (snap where it visually
// sits).
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
  // Snap where the handle VISUALLY sits (group-composed), then invert back to
  // the member value, so a grouped member lands on the visible grid lines.
  simd_float3x3 A = [self _homographyForContentRect:cr];
  CGPoint cv = [self handlePointForContentRect:cr position:@[ @(p.x), @(p.y) ]];
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

@end
