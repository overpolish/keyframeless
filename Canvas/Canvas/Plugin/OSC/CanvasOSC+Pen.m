/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasAnchorSelectionSync.h" // cross-process selection sync
#import "CanvasLayerRender.h"         // CanvasProjectLayerPointsObj
#import "CanvasLayerTimeline.h"       // blob + UIState snapshots
#import "CanvasOSC_Private.h"
#import "CanvasPathMorph.h" // CanvasPathMorphedAtFraction
#import "CanvasPathOSC.h"   // CanvasDrawPathEditOSC
#import <KeyframelessKit/KKShape.h> // KKRectShape (image extent)
#import "CanvasPenController.h"
#import "CanvasPenCursors.h" // shared pen cursor set
#import "CanvasPenMarquee.h" // shared dashed-marquee perimeter walk
#import "Constants.h"        // kParamLayerData / kParamUIState
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/NSColor+KKColors.h>

// Preview colours: the Position OSC red core under the grid's dark halo, so the
// guide is consistent with the other OSCs AND legible over any footage.
static const simd_float4 kPenHalo = {0.0f, 0.0f, 0.0f, 0.55f};
static const simd_float4 kPenCore = {1.0f, 0.25f, 0.25f, 1.0f};
static const simd_float4 kPenHandleLine = {1.0f, 1.0f, 1.0f, 0.85f};
static const float kPenLineHaloHalfPx = 2.3f;
static const float kPenLineCoreHalfPx = 1.2f;

CanvasPenModifiers CanvasPenModsFromFxModifiers(NSUInteger m) {
  CanvasPenModifiers out = CanvasPenModNone;
  if (m & kFxModifierKey_SHIFT)
    out |= CanvasPenModShift;
  if (m & kFxModifierKey_COMMAND)
    out |= CanvasPenModCmd;
  if (m & kFxModifierKey_CONTROL)
    out |= CanvasPenModCtrl;
  if (m & kFxModifierKey_OPTION)
    out |= CanvasPenModOpt;
  return out;
}

#define PenModsFromFx CanvasPenModsFromFxModifiers

@implementation CanvasOSC (Pen)

- (BOOL)_penToolActive {
  return [self _activeTool] == CanvasToolbarToolPen;
}

#pragma mark - Input forwarding (called by CanvasOSC+Input)

- (BOOL)_penMouseDownAtX:(double)x
                       y:(double)y
               modifiers:(NSUInteger)modifiers
                  atTime:(CMTime)time {
  // Opt-click an existing anchor removes it (with the auto-delete cascade);
  // only consumes the press if an anchor was actually under it, so Opt
  // elsewhere falls through to normal pen behaviour. Read the LIVE Option flag
  // too: FCP doesn't always surface it in the passed `modifiers`, and the hover
  // cursor (PenX) already uses [NSEvent modifierFlags], so they must agree or
  // the cursor shows delete but the click places a point.
  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) ||
                 ([NSEvent modifierFlags] & NSEventModifierFlagOption);
  if (!self.penController.active && optHeld &&
      [self.pathEditController removeAnchorAtX:x y:y])
    return YES;
  // Context-sensitive: when NOT mid-drawing a new path, a click on the selected
  // path's segment inserts an anchor there (and begins dragging it). Empty
  // space / endpoints fall through to the pen's new-path machinery.
  if (!self.penController.active && [self.pathEditController penInsertAtX:x
                                                                        y:y])
    return YES;
  return [self.penController mouseDownAtX:x
                                        y:y
                                modifiers:PenModsFromFx(modifiers)];
}

- (void)_penMouseMovedAtX:(double)x y:(double)y {
  [self.penController mouseMovedAtX:x y:y];
}

- (void)_penMouseDraggedAtX:(double)x
                          y:(double)y
                  modifiers:(NSUInteger)modifiers {
  [self.penController mouseDraggedAtX:x y:y modifiers:PenModsFromFx(modifiers)];
}

- (void)_penMouseUp {
  [self.penController mouseUp];
}

- (BOOL)_penKeyDown:(unsigned short)asciiKey
          modifiers:(NSUInteger)modifiers
             atTime:(CMTime)time {
  return [self.penController keyDown:asciiKey];
}

- (void)_penConfirmIfContextLost {
  [self.penController confirmIfContextLost];
}

#pragma mark - Path-edit input forwarding (called by CanvasOSC+Input)

- (CanvasPathEditHit)_pathEditHitAtX:(double)x y:(double)y {
  return [self.pathEditController hitTestAtX:x y:y];
}

- (BOOL)_pathEditMouseDownAtX:(double)x y:(double)y modifiers:(NSUInteger)mods {
  return [self.pathEditController mouseDownAtX:x
                                             y:y
                                     modifiers:PenModsFromFx(mods)];
}

- (void)_pathEditMouseDraggedAtX:(double)x
                               y:(double)y
                       modifiers:(NSUInteger)mods {
  [self.pathEditController mouseDraggedAtX:x y:y modifiers:PenModsFromFx(mods)];
}

- (void)_pathEditMouseUp {
  [self.pathEditController mouseUp];
}

- (BOOL)_pathEditDragging {
  return self.pathEditController.dragging;
}

- (NSCursor *)_penCursorForCanvasX:(double)x y:(double)y {
  if (!self.penController.active) {
    // Opt over an existing anchor -> "remove point" (matches the Opt-click).
    if (([NSEvent modifierFlags] & NSEventModifierFlagOption) &&
        [self.pathEditController hitTestAtX:x y:y] == CanvasPathEditHitAnchor)
      return CanvasPenCursorForRole(CanvasPenCursorRoleDelete);
    // Hovering the selected path's curve -> "add point".
    if ([self.pathEditController segmentHitAtX:x y:y])
      return CanvasPenCursorForRole(CanvasPenCursorRoleAdd);
  }
  return [self.penController cursorKindAtX:x y:y] == CanvasPenCursorClose
             ? CanvasPenCursorForRole(CanvasPenCursorRoleClose)
             : CanvasPenCursorForRole(CanvasPenCursorRolePen);
}

- (void)_drawPenInProgressWithWidth:(NSInteger)width
                             height:(NSInteger)height
                   destinationImage:(FxImageTile *)destinationImage
                             atTime:(CMTime)time {
  self.penDrawDest = destinationImage;
  self.penDrawTime = time;
  [self.penController draw];
  self.penDrawDest = nil;
}

// Multi-selection display: the point OSC (anchors + curve) of EVERY selected
// vector layer, drawn dimmed (ghost) so it reads as "selected, not editable" -
// shown regardless of the Points OSC visibility toggle. Point editing is gated
// off while more than one layer is selected (it's a layer-level selection). The
// per-anchor display still follows the keypose rule (anchors only where the
// geometry is editable at this fraction). No-op for a single selection.
- (void)_drawMultiSelectHighlightInDestination:(FxImageTile *)destinationImage
                                        atTime:(CMTime)time {
  NSArray<NSString *> *sel = [self _selectedLayerIDs];
  if (sel.count < 2)
    return;
  NSArray<KKBezierPath *> *paths = [self _snapshotPaths];
  double frac = [self fractionAtTime:time];
  float aspect = (float)[self _canvasAspect];
  self.penDrawDest = destinationImage;
  self.penDrawTime = time;
  for (KKBezierPath *p in paths) {
    if (![sel containsObject:(p.layerID ?: @"")])
      continue;
    // Images have no points to outline - draw a dimmed box as their indicator.
    if (p.isImage) {
      CanvasDrawLayerBoxOSC(self, paths, p, frac, aspect);
      continue;
    }
    if (p.isGroup || p.count < 1)
      continue;
    if (!CanvasPathGeometryEditableAtFraction(p, frac))
      continue;
    CanvasDrawPathEditOSC(self, paths, CanvasPathMorphedAtFraction(p, frac),
                          frac, aspect, /*selected=*/nil, /*marqueeActive=*/NO,
                          CGRectZero, /*ghost=*/YES, /*showCornerWidgets=*/NO);
  }
  self.penDrawDest = nil;
}

// The marquee rubber-band, drawn independently of the selection (the marquee can
// run with 0, 1, or 2+ layers selected, so it can't ride on the single-path
// point OSC's draw - that's why it vanished while multi-selected).
- (void)_drawMarqueeInDestination:(FxImageTile *)destinationImage {
  if (!self.pathEditController.marqueeActive)
    return;
  self.penDrawDest = destinationImage;
  [self penDrawMarqueeRect:self.pathEditController.marqueeSurfaceRect];
  self.penDrawDest = nil;
}

- (void)_drawSelectedPathEditOSCInDestination:(FxImageTile *)destinationImage
                                       atTime:(CMTime)time {
  BOOL visible = [self kkOSCElementVisible:@"Points"];
  // Hidden but an Opt-peek wants to reveal it, like the transform handles:
  //  - master ON  + individually hidden -> dimmed re-show ghost (Opt-click
  //  re-shows)
  //  - master OFF (all off) -> "peek and use": revealed at FULL alpha +
  //  draggable
  BOOL reveal =
      !visible && self.optRevealActive && [self kkOSCRevealEligible:@"Points"];
  if (!visible && !reveal)
    return; // toggled off in the OSC-visibility popover and not being revealed
  BOOL ghost = reveal && ![self kkOSCMasterOff];
  NSString *sel = [self _resolvedSelectedLayerID];
  if (!sel.length)
    return;
  // Pick up an anchor selection published by the mini (cross-process sync).
  NSIndexSet *synced = CanvasConsumeAnchorSelection(@"osc", sel);
  if (synced)
    [self.pathEditController setSelectedAnchorIndexes:synced];
  KKBezierPath *path = nil;
  NSArray<KKBezierPath *> *paths = [self _snapshotPaths];
  for (KKBezierPath *p in paths)
    if ([p.layerID isEqualToString:sel]) {
      path = p;
      break;
    }
  if (!path || path.isImage || path.isGroup ||
      (!path.strokeEnabled && !path.fillEnabled) || path.count < 1)
    return;
  double frac = [self fractionAtTime:time];
  // OSC rule: anchors show only when the path is constant or the playhead is on
  // a Points keypose - hidden between keyposes (the stroke still morphs).
  if (!CanvasPathGeometryEditableAtFraction(path, frac))
    return;
  self.penDrawDest = destinationImage;
  self.penDrawTime = time;
  CanvasDrawPathEditOSC(self, paths, CanvasPathMorphedAtFraction(path, frac),
                        frac, (float)[self _canvasAspect],
                        self.pathEditController.selectedAnchors,
                        /*marqueeActive=*/NO, CGRectZero, ghost,
                        [self _activeTool] == CanvasToolbarToolCursor);
  self.penDrawDest = nil;
}

#pragma mark - CanvasPenSurface (coordinate + snap)

// render-object (Y-up) <-> CANVAS px. The coordinate helpers use FCP's OBJECT
// space (Y-down), so flip Y crossing the boundary (as in CanvasOSC+AutoSelect).
- (CGPoint)_penCanvasFromObj:(CGPoint)objYUp {
  return [self
      canvasPointFromObjectPoint:simd_make_float2((float)objYUp.x,
                                                  1.0f - (float)objYUp.y)];
}

- (CGPoint)penSurfacePointFromObj:(CGPoint)objYUp {
  return [self _penCanvasFromObj:objYUp];
}

- (CGPoint)penObjFromSurfaceX:(double)x y:(double)y {
  simd_float2 fcp = [self objectPointFromCanvasPoint:CGPointMake(x, y)];
  return CGPointMake(fcp.x, 1.0f - fcp.y);
}

- (CGPoint)penSnappedObjFromSurfaceX:(double)x y:(double)y {
  CGPoint cp = [self _snapCanvasPointToGrid:CGPointMake(x, y)];
  return [self penObjFromSurfaceX:cp.x y:cp.y];
}

- (BOOL)penGridSnapping {
  return [self _gridEnabled] && [self _gridSnap];
}

- (double)penCanvasAspect {
  return [self _canvasAspect];
}

- (BOOL)penToolActive {
  return [self _penToolActive];
}

#pragma mark - CanvasPenSurface (blob)

- (KKBezierPath *)penLayerWithID:(NSString *)layerID {
  for (KKBezierPath *p in [self _snapshotPaths])
    if ([p.layerID isEqualToString:layerID])
      return p;
  return nil;
}

- (NSString *)penSelectedLayerID {
  return [self _resolvedSelectedLayerID];
}

- (NSArray<NSString *> *)penSelectedLayerIDs {
  return [self _selectedLayerIDs];
}

- (NSString *)penSurfaceTag {
  return @"osc";
}

// The viewer has no popover scope, so every layer is selectable.
- (NSSet<NSString *> *)penNonSelectableLayerIDs {
  return nil;
}

- (NSArray<KKBezierPath *> *)penAllLayers {
  return [self _snapshotPaths];
}

- (double)penEditFraction {
  return [self fractionAtTime:self.penDrawTime];
}

// CanvasPenSurface: clear the whole selection (a plain click on empty canvas).
- (void)penDeselectAll {
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[@"selectedLayerID"] = @"";
    state[@"selectedLayerIDs"] = @[];
  }];
}

// CanvasPenSurface: commit a marquee layer selection. Plain replaces the set
// with the enclosed layers (primary = topmost), Shift unions them into the
// current selection. Routes through the same UIState write as a pick click.
- (void)penSelectLayerIDs:(NSArray<NSString *> *)layerIDs
                 additive:(BOOL)additive {
  if (!layerIDs.count)
    return;
  NSMutableArray<NSString *> *sel;
  NSString *primary;
  if (additive) {
    sel = [[self _selectedLayerIDs] mutableCopy] ?: [NSMutableArray array];
    for (NSString *lid in layerIDs)
      if (![sel containsObject:lid])
        [sel addObject:lid];
    primary = sel.firstObject ?: @"";
  } else {
    sel = [layerIDs mutableCopy];
    primary = layerIDs.firstObject;
  }
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[@"selectedLayerID"] = primary ?: @"";
    state[@"selectedLayerIDs"] = sel;
  }];
}

// Action-scoped read-modify-write of the layer blob (the OSC can't READ the
// custom param, so it round-trips the inspector snapshot). When `selectID` is
// set, the selection is written in the SAME action so it undoes together.
- (void)penMutateBlob:(void (^)(NSMutableArray<KKBezierPath *> *paths))mutate
        selectLayerID:(NSString *)selectID {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!actionAPI || !setAPI)
    return;
  [actionAPI startAction:self];
  NSString *b64 = CanvasLayerBlobSnapshot();
  NSMutableArray<KKBezierPath *> *paths =
      b64.length
          ? [KKBezierPath
                pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64
                                                                  options:0]]
          : [NSMutableArray array];
  mutate(paths);
  NSString *newBlob =
      [[KKBezierPath blobFromPaths:paths] base64EncodedStringWithOptions:0];
  KKWriteCustomParamString(setAPI, newBlob, kParamLayerData);
  NSString *newState = nil;
  if (selectID.length) {
    NSMutableDictionary *state = [[self _uiStateDict] mutableCopy];
    state[@"selectedLayerID"] = selectID;
    // Collapse the multi-set to the single result too, else a prior multi-
    // selection's now-stale IDs linger (e.g. after deleting a multi-selection
    // the deleted IDs would stay in selectedLayerIDs).
    state[@"selectedLayerIDs"] = @[ selectID ];
    newState = [[NSString alloc]
        initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                     options:0
                                                       error:nil]
            encoding:NSUTF8StringEncoding];
    KKWriteCustomParamString(setAPI, newState, kParamUIState);
  }
  [actionAPI endAction:self];
  CanvasSetLayerBlobSnapshot(newBlob);
  if (newState)
    CanvasSetUIStateSnapshot(newState);
}

- (void)penSetLiveLayers:(NSArray<KKBezierPath *> *)paths {
  // Write the blob param INSIDE an action scope on every drag tick, exactly
  // like the Scale / Position OSCs (KKScaleOSC -_writeScaleValues:): FCP
  // coalesces a gesture's per-tick writes into ONE undo step, and because the
  // param itself changes the FCP viewer RE-RENDERS the actual shape live, not
  // just the OSC overlay. The process snapshot is kept in step so the OSC's
  // next draw + the next tick read the new geometry before the param round-trip
  // republishes it.
  NSString *blob =
      [[KKBezierPath blobFromPaths:paths] base64EncodedStringWithOptions:0];
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (actionAPI && setAPI) {
    [actionAPI startAction:self];
    KKWriteCustomParamString(setAPI, blob, kParamLayerData);
    [actionAPI endAction:self];
  }
  CanvasSetLayerBlobSnapshot(blob);
  self.penLiveParamWritten =
      YES; // this gesture has committed via per-tick writes
}

- (void)penPreviewLayers:(NSArray<KKBezierPath *> *)paths {
  // Snapshot only - update what the OSC reads WITHOUT writing the param, so a
  // curve-preserving insert doesn't spawn its own undo step. The mouseUp commit
  // writes the one undo (penLiveParamWritten stays NO until a real drag
  // writes).
  NSString *blob =
      [[KKBezierPath blobFromPaths:paths] base64EncodedStringWithOptions:0];
  CanvasSetLayerBlobSnapshot(blob);
  self.penLiveParamWritten = NO;
}

- (void)penCommitLiveLayers {
  // If per-tick drag writes already committed this gesture (penSetLiveLayers),
  // there's nothing to do - a write here would be a SECOND undo step. But if
  // the gesture only previewed (a click insert with no drag), write the
  // snapshot once now so it persists as the single undo.
  if (!self.penLiveParamWritten) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *blob = CanvasLayerBlobSnapshot();
    if (actionAPI && setAPI && blob.length) {
      [actionAPI startAction:self];
      KKWriteCustomParamString(setAPI, blob, kParamLayerData);
      [actionAPI endAction:self];
    }
  }
  self.penLiveParamWritten = NO;
}

#pragma mark - CanvasPenSurface (draw primitives)

- (void)_penHaloStroke:(const CGPoint *)pts
                 count:(NSUInteger)n
      destinationImage:(FxImageTile *)dest {
  [self drawLineStripWithPoints:pts
                          count:n
                          color:kPenHalo
                      halfWidth:kPenLineHaloHalfPx
               destinationImage:dest];
  [self drawLineStripWithPoints:pts
                          count:n
                          color:kPenCore
                      halfWidth:kPenLineCoreHalfPx
               destinationImage:dest];
}

- (void)penDrawDotAtObj:(CGPoint)objYUp
                  ghost:(BOOL)ghost
                hovered:(BOOL)hovered
                 active:(BOOL)active {
  if (!self.penDrawDest)
    return;
  self.penAnchorOSC.ghostAlpha = ghost ? 0.4f : 1.0f;
  // Selected anchors fill in the host accent (KKPointOSC ignores isActive; the
  // fill override is the knob).
  self.penAnchorOSC.fillColorOverride =
      active ? [NSColor accentMatchingHost] : nil;
  [self.penAnchorOSC drawAtCanvasPosition:[self _penCanvasFromObj:objYUp]
                                isHovered:hovered
                                 isActive:active
                         destinationImage:self.penDrawDest
                                   atTime:self.penDrawTime];
  self.penAnchorOSC.fillColorOverride = nil;
  self.penAnchorOSC.ghostAlpha = 1.0f;
}

- (void)penDrawWarnDotAtObj:(CGPoint)objYUp {
  if (!self.penDrawDest)
    return;
  // Same glyph + outline/shadow as an anchor, filled in the warning colour -
  // the override is the only difference from a normal/accent dot.
  self.penAnchorOSC.fillColorOverride = [NSColor warning];
  [self.penAnchorOSC drawAtCanvasPosition:[self _penCanvasFromObj:objYUp]
                                isHovered:YES
                                 isActive:NO
                         destinationImage:self.penDrawDest
                                   atTime:self.penDrawTime];
  self.penAnchorOSC.fillColorOverride = nil;
}

- (void)penDrawRingAtObj:(CGPoint)objYUp maxed:(BOOL)maxed {
  if (!self.penDrawDest)
    return;
  // The shared KKRingOSC glyph (same control as the Glow radius ring), tinted
  // accent - or error at the clamp. The ring shader is crisp by construction
  // (no line-strip anti-alias washout), so no manual pixel-snap is needed.
  self.penCornerRingOSC.tintColor =
      maxed ? [NSColor error] : [NSColor accentMatchingHost];
  [self.penCornerRingOSC drawAtCanvasPosition:[self _penCanvasFromObj:objYUp]
                                    isHovered:NO
                                     isActive:NO
                             destinationImage:self.penDrawDest
                                       atTime:self.penDrawTime];
}

- (void)penDrawMarqueeRect:(CGRect)r {
  if (!self.penDrawDest)
    return;
  // Surface points == canvas px for the viewer. A two-tone dashed rectangle
  // (light dash over dark gap) so it reads on any background; the pixel-snapped
  // perimeter walk is shared with the mini (CanvasPenMarqueeWalk). Accumulate
  // the on / off segments, then batch each colour into one draw.
  simd_float4 lightColor = {1.0f, 1.0f, 1.0f, 0.9f};
  simd_float4 darkColor = {0.0f, 0.0f, 0.0f, 0.6f};
  NSUInteger cap = kCanvasPenMarqueeMaxSegments * 2;
  CGPoint *lightPts = malloc(sizeof(CGPoint) * cap);
  CGPoint *darkPts = malloc(sizeof(CGPoint) * cap);
  __block NSUInteger lightCount = 0, darkCount = 0;
  CanvasPenMarqueeWalk(r, 8.0, 5.0, ^(CGPoint from, CGPoint to, BOOL light) {
    if (light) {
      lightPts[lightCount++] = from;
      lightPts[lightCount++] = to;
    } else {
      darkPts[darkCount++] = from;
      darkPts[darkCount++] = to;
    }
  });
  [self drawLineSegmentsWithPoints:lightPts
                             count:lightCount
                             color:lightColor
                         halfWidth:1.5f
                  destinationImage:self.penDrawDest];
  [self drawLineSegmentsWithPoints:darkPts
                             count:darkCount
                             color:darkColor
                         halfWidth:1.5f
                  destinationImage:self.penDrawDest];
  free(lightPts);
  free(darkPts);
}

- (void)penDrawCurveObjPoints:(const CGPoint *)objPts count:(NSUInteger)count {
  if (!self.penDrawDest || count < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++)
    pts[i] = [self _penCanvasFromObj:objPts[i]];
  [self _penHaloStroke:pts count:count destinationImage:self.penDrawDest];
  free(pts);
}

- (void)penDrawColoredCurveObjPoints:(const CGPoint *)objPts
                               count:(NSUInteger)count
                               color:(simd_float4)color {
  if (!self.penDrawDest || count < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++)
    pts[i] = [self _penCanvasFromObj:objPts[i]];
  [self drawLineStripWithPoints:pts
                          count:count
                          color:color
                      halfWidth:1.5f
               destinationImage:self.penDrawDest];
  free(pts);
}

- (void)penDrawSnappedLoopObjPoints:(const CGPoint *)objPts
                              count:(NSUInteger)count
                              color:(simd_float4)color {
  if (!self.penDrawDest || count < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++) {
    CGPoint c = [self _penCanvasFromObj:objPts[i]];
    // Snap to a pixel centre (floor + 0.5), exactly like the grid lines, so the
    // 1px box edges land crisp on the destination raster instead of soft.
    pts[i] = CGPointMake(floor(c.x) + 0.5, floor(c.y) + 0.5);
  }
  [self drawLineStripWithPoints:pts
                          count:count
                          color:color
                      halfWidth:1.5f
               destinationImage:self.penDrawDest];
  free(pts);
}

- (void)penDrawHandleFromObj:(CGPoint)aObj toObj:(CGPoint)bObj {
  if (!self.penDrawDest)
    return;
  CGPoint line[2] = {[self _penCanvasFromObj:aObj],
                     [self _penCanvasFromObj:bObj]};
  [self drawLineStripWithPoints:line
                          count:2
                          color:kPenHandleLine
                      halfWidth:1.5f
               destinationImage:self.penDrawDest];
  [self.penHandleOSC drawAtCanvasPosition:line[1]
                                isHovered:NO
                                 isActive:NO
                         destinationImage:self.penDrawDest
                                   atTime:self.penDrawTime];
}

@end
