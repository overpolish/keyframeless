/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import "Plugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// CanvasOSC = the SELECTED layer's Position handle + motion path + scale box +
// rotation rings, composed from the reusable kit controls, plus click-to-select
// of any image layer. The control's responsibilities are split across category
// files: +Geometry (canvas-space math + sub-control feeding), +State (snapshot
// reads / UIState writes / per-layer persist), +AutoSelect (click-to-select),
// +Input (hit-test + mouse handling). This file owns the lifecycle, drawing,
// and the OSC-element key mapping.
@implementation CanvasOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _position = [[KKPositionOSC alloc] initWithAPIManager:apiManager
                                                laneLabel:@"Position"
                                                pathLabel:@"Path"];
    _position.positionActivePart = CanvasOSCPartPosition;
    _position.tangentActivePart = CanvasOSCPartPath;
    // Drive the shared guide bridge: during an OSC guide the handle follows the
    // guide-pushed value (the drawOSC tick can't read the layer blob).
    _position.guideProvider = self;
    for (KKLane *l in [CanvasPlugin availableLanes])
      if ([l.label isEqualToString:@"Position"])
        _position.templateLane = l;
    // Route the control's write to the selected layer (it would otherwise write
    // the single kKKParamTimelineData param, which Canvas doesn't use).
    __weak typeof(self) weak = self;
    _position.onTimelinePersist = ^(KKTimeline *tl) {
      [weak _persistSelectedLayerTimeline:tl];
    };
    // Grid snap (when the toolbar Snap toggle is on); no-op otherwise.
    _position.canvasSnapProvider = ^CGPoint(CGPoint cp) {
      return [weak _snapCanvasPointToGrid:cp];
    };
    // Scale box, concentric with the Position handle. Same per-layer persist.
    _scale = [[KKScaleOSC alloc] initWithAPIManager:apiManager
                                          laneLabel:@"Scale"];
    _scale.scaleActivePart = CanvasOSCPartScale;
    for (KKLane *l in [CanvasPlugin availableLanes])
      if ([l.label isEqualToString:@"Scale"])
        _scale.templateLane = l;
    _scale.onTimelinePersist = ^(KKTimeline *tl) {
      [weak _persistSelectedLayerTimeline:tl];
    };
    // Rotation gizmo (3-axis rings), concentric with the Position handle. Same
    // per-layer persist. Drawn under the scale box + Position handle.
    _rotation = [[KKRotationOSC alloc] initWithAPIManager:apiManager
                                                laneLabel:@"Rotation"];
    _rotation.rotationActivePart = CanvasOSCPartRotation;
    for (KKLane *l in [CanvasPlugin availableLanes])
      if ([l.label isEqualToString:@"Rotation"])
        _rotation.templateLane = l;
    _rotation.onTimelinePersist = ^(KKTimeline *tl) {
      [weak _persistSelectedLayerTimeline:tl];
    };
    // Anchor pivot square (topmost), concentric with the Position handle. The
    // kit control's default clip-space geometry (sibling Position lane + Anchor
    // offset) is exactly Canvas's per-layer pivot, so no geometry blocks are
    // needed for an image layer. Same per-layer persist.
    _anchor = [[KKAnchorOSC alloc] initWithAPIManager:apiManager
                                            laneLabel:@"Anchor"];
    _anchor.anchorActivePart = CanvasOSCPartAnchor;
    for (KKLane *l in [CanvasPlugin availableLanes])
      if ([l.label isEqualToString:@"Anchor"])
        _anchor.templateLane = l;
    _anchor.onTimelinePersist = ^(KKTimeline *tl) {
      [weak _persistSelectedLayerTimeline:tl];
    };
    _anchor.canvasSnapProvider = ^CGPoint(CGPoint cp) {
      return [weak _snapCanvasPointToGrid:cp];
    };
    // Pen-tool anchor + tangent dots, matching the Position path OSC's look.
    _penAnchorOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _penAnchorOSC.oscRadius = 7.0f;
    _penAnchorOSC.outlineWidth = 2.0f;
    _penAnchorOSC.clearsOnDraw = NO;
    _penHandleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _penHandleOSC.oscRadius = 5.0f;
    _penHandleOSC.outlineWidth = 1.5f;
    _penHandleOSC.clearsOnDraw = NO;
    // Live-corner radius widget: the shared ring control, small + tinted accent.
    _penCornerRingOSC = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    [_penCornerRingOSC applyRadiusWidgetStyle];
    _penController = [[CanvasPenController alloc] initWithSurface:self];
    _pathEditController =
        [[CanvasPathEditController alloc] initWithSurface:self];
    _shapeController = [[CanvasShapeController alloc] initWithSurface:self];
    [self _setupToolbar];
  }
  return self;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  self.penDrawTime = time; // current playhead, read by penEditFraction in input
  // Feed the shared guide bridge this tick's canvas geometry: keeps the viewer
  // screen rect fresh and marks the canvas reference alive, so the inspector's
  // timing guides enable (and spotlight the viewer) only while the effect is
  // focused. Unconditional - independent of selection / tool / gizmo state.
  [self _ingestGuideDrawTickWithPosition:[self.position positionCanvasAtTime:time]];
  // Reset the draw surface (no-op encode) so only the handle/path are visible.
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];
  // A tool / layer switch while drawing confirms the in-progress path as-is.
  [self _penConfirmIfContextLost];
  // Switching INTO the pen tool drops any lingering cursor-mode point selection
  // (a multi-point selection means nothing to the pen; the accent just
  // confuses).
  NSInteger curTool = [self _activeTool];
  if (curTool == CanvasToolbarToolPen &&
      self.lastDrawnTool != CanvasToolbarToolPen)
    [self.pathEditController clearSelection];
  self.lastDrawnTool = curTool;
  // Grid overlay (under the gizmo + toolbar), independent of selection / lock.
  [self _drawGridWithWidth:width
                    height:height
          destinationImage:destinationImage];
  // Locked layer: cleared surface only, no handles (and no Opt-reveal) - the
  // toolbar (global chrome) still draws on top.
  if ([self _selectedLayerLocked]) {
    [self _drawToolbarWithWidth:width
                         height:height
               destinationImage:destinationImage];
    return;
  }
  // Pen tool: no transform gizmo (matches photo-editor pen UX) - only the grid,
  // the in-progress path preview, and the toolbar draw.
  if ([self _penToolActive]) {
    // While NOT mid-drawing a new path, show the selected path's anchors +
    // curve FIRST (so the pen can target a segment to insert on) - then the pen
    // overlay on top, so its endpoint-continue highlight sits over the normal
    // anchors.
    if (!self.penController.active)
      [self _drawSelectedPathEditOSCInDestination:destinationImage atTime:time];
    [self _drawPenInProgressWithWidth:width
                               height:height
                     destinationImage:destinationImage
                               atTime:time];
    [self _drawToolbarWithWidth:width
                         height:height
               destinationImage:destinationImage];
    return;
  }
  // Rect / ellipse tool: like the pen, no transform gizmo - just the grid, the
  // drag-out box preview, and the toolbar.
  if ([self _shapeToolActive]) {
    [self _drawShapeInProgressInDestination:destinationImage atTime:time];
    [self _drawToolbarWithWidth:width
                         height:height
               destinationImage:destinationImage];
    return;
  }
  // The transform gizmo (Position/Scale/Rotation/Anchor) is drawn ONLY for a
  // lone image / group - a lone path shows its points + path-ops instead, and 0
  // or 2+ selected show no gizmo. (Each control still gates itself on the
  // OSC-visibility system; this is the outer selection-type gate.)
  if ([self _showsTransformGizmo]) {
    // Re-centre the point controls on where a grouped member is actually drawn
    // (no-op otherwise); the scale box + rotation rings follow via the Position
    // handle they centre on.
    [self _applyGroupComposeOffsetAtTime:time];
    // The controller (KKPositionOSC) owns ALL the visibility + opt-reveal-ghost
    // gating internally (it reads kkOSCElementVisible / kkOSCRevealEligible +
    // ITS OWN optRevealActive). So just forward our reveal + drag state to it
    // and draw unconditionally - it draws nothing when hidden, the dim ghost
    // when Opt-revealed, full when shown. (Forwarding optRevealActive matters
    // here because Canvas's primary Position handle can itself be hidden, so the
    // controller must ghost it rather than always show it.)
    self.position.optRevealActive = self.optRevealActive;
    self.position.dragging = self.isDragging;
    [self.position drawPathInDestination:destinationImage
                                  atTime:time
                              activePart:activePart];
    // Rotation rings, drawn under the scale box + Position handle. The control
    // owns its own per-axis visibility + opt-reveal-ghost gating.
    [self _syncRotationControlAtTime:time];
    [self.rotation drawInDestination:destinationImage
                              atTime:time
                          activePart:activePart];
    // Scale box, drawn over the motion path and under the Position handle (so
    // the handle stays on top + grabbable). The control owns its own visibility
    // + opt-reveal-ghost gating.
    [self _syncScaleControlAtTime:time];
    [self.scale drawInDestination:destinationImage
                           atTime:time
                       activePart:activePart];
    [self.position drawHandleInDestination:destinationImage
                                    atTime:time
                                activePart:activePart];
    // Anchor pivot square, drawn last so it sits on top of every other control.
    // The control owns its own visibility + opt-reveal-ghost gating + snap
    // guides.
    self.anchor.optRevealActive = self.optRevealActive;
    self.anchor.dragging = self.isDragging;
    [self.anchor drawInDestination:destinationImage
                            atTime:time
                        activePart:activePart];
  }
  // Exactly one layer selected: its editable point OSC (anchors + curve), gated
  // by the Points visibility toggle. Two or more: the dimmed, non-editable point
  // OSC of every selected layer (shown regardless of the toggle) so the
  // multi-selection reads at a glance. NONE selected: draw nothing (the gizmo
  // above is already gated off). The transform gizmo is hidden by default via the
  // OSC visibility system, so the two don't clutter each other.
  NSUInteger nsel = [self _selectedLayerIDs].count;
  if (nsel >= 2)
    [self _drawMultiSelectHighlightInDestination:destinationImage atTime:time];
  else if (nsel == 1)
    [self _drawSelectedPathEditOSCInDestination:destinationImage atTime:time];
  // The marquee rubber-band draws over any selection state (it can run with 0,
  // 1, or 2+ selected), so draw it separately from the selection OSC above.
  [self _drawMarqueeInDestination:destinationImage];
  // Path-op hover preview (red operands / green result) under the toolbar.
  [self _drawPathOpHoverPreviewInDestination:destinationImage atTime:time];
  // Toolbar (grid + drag handle), global screen chrome, drawn last so it sits
  // on top of the gizmo.
  [self _drawToolbarWithWidth:width
                       height:height
             destinationImage:destinationImage];
}

- (NSArray<NSString *> *)oscElementKeys {
  return @[
    @"Points", @"Corners", @"Position", @"Path", @"Scale", @"Rotation",
    @"Rotation.X", @"Rotation.Y", @"Rotation.Z", @"Anchor"
  ];
}

- (NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart == CanvasOSCPartPathEdit)
    return @"Points";
  if (activePart == CanvasOSCPartCorner)
    return @"Corners";
  if (activePart == CanvasOSCPartPath)
    return @"Path";
  if (activePart == CanvasOSCPartScale)
    return @"Scale";
  if (activePart == CanvasOSCPartAnchor)
    return @"Anchor";
  if (activePart == CanvasOSCPartPosition)
    return self.position.hoverTargetIsAnchor ? @"Path" : @"Position";
  if (activePart == CanvasOSCPartRotation) {
    switch (self.rotation.activeAxis) {
    case 0:
      return @"Rotation.X";
    case 1:
      return @"Rotation.Y";
    case 2:
      return @"Rotation.Z";
    default:
      return @"Rotation";
    }
  }
  return nil;
}

@end
