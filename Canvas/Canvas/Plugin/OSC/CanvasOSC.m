/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC.h"
#import "CanvasLayerTimeline.h"
#import "Constants.h"
#import "Plugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// This control's own activePart numbers (Position handle / anchor dot, the
// motion-path tangent handle, and the scale box). Match the controllers'
// activePart wiring below.
static const NSInteger kCanvasOSCPositionPart = 1;
static const NSInteger kCanvasOSCScalePart = 2;
static const NSInteger kCanvasOSCPathPart = 3;

@interface CanvasOSC ()
@property(nonatomic, strong) KKPositionOSC *position;
@property(nonatomic, strong) KKScaleOSC *scale;
@property(nonatomic) BOOL pointCursorSet;
@end

@implementation CanvasOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _position = [[KKPositionOSC alloc] initWithAPIManager:apiManager
                                                laneLabel:@"Position"
                                                pathLabel:@"Path"];
    _position.positionActivePart = kCanvasOSCPositionPart;
    _position.tangentActivePart = kCanvasOSCPathPart;
    for (KKLane *l in [CanvasPlugin availableLanes])
      if ([l.label isEqualToString:@"Position"])
        _position.templateLane = l;
    // Route the control's write to the selected layer (it would otherwise write
    // the single kKKParamTimelineData param, which Canvas doesn't use).
    __weak typeof(self) weak = self;
    _position.onTimelinePersist = ^(KKTimeline *tl) {
      [weak _persistSelectedLayerTimeline:tl];
    };
    // Scale box, concentric with the Position handle. Same per-layer persist.
    _scale = [[KKScaleOSC alloc] initWithAPIManager:apiManager
                                          laneLabel:@"Scale"];
    _scale.scaleActivePart = kCanvasOSCScalePart;
    for (KKLane *l in [CanvasPlugin availableLanes])
      if ([l.label isEqualToString:@"Scale"])
        _scale.templateLane = l;
    _scale.onTimelinePersist = ^(KKTimeline *tl) {
      [weak _persistSelectedLayerTimeline:tl];
    };
  }
  return self;
}

// Min dimension of the canvas frame (object [0,1]^2 corners converted to
// canvas) - the reference length the scale gizmo sizes against, so the box
// tracks the clip with viewer zoom rather than being a fixed screen size.
- (double)_onScreenFrameMin {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return 1000.0;
  CGPoint c0 = CGPointZero, cx = CGPointZero, cy = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0
                          fromY:0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c0.x
                            toY:&c0.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1
                          fromY:0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cx.x
                            toY:&cx.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0
                          fromY:1
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cy.x
                            toY:&cy.y];
  double w = hypot(cx.x - c0.x, cx.y - c0.y);
  double h = hypot(cy.x - c0.x, cy.y - c0.y);
  double m = MIN(w, h);
  return (m > 1.0) ? m : 1000.0;
}

// Feed the scale control this tick's box centre (= the layer's Position handle)
// + gizmo size + reveal/drag state. Shared by draw / hit-test / mouse.
- (void)_syncScaleControlAtTime:(CMTime)time {
  self.scale.center = [self.position positionCanvasAtTime:time];
  self.scale.frameMin = [self _onScreenFrameMin];
  self.scale.optRevealActive = self.optRevealActive;
  self.scale.dragging = self.isDragging;
}

// Whether the selected layer (the one the OSC reads via the process timeline
// snapshot) is locked. A locked layer is visible-but-non-interactive: its OSC
// is neither drawn nor hit-testable, and Opt-hold can't peek it back - matching
// the mini-viewer's `handlesLocked`. Derived the same way as the persist path:
// the snapshot lanes carry the owning `layerKey`; resolve it in the published
// layer blob.
- (BOOL)_selectedLayerLocked {
  NSString *layerID = nil;
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if (l.layerKey.length) {
      layerID = l.layerKey;
      break;
    }
  NSString *b64 = CanvasLayerBlobSnapshot();
  if (!b64.length)
    return NO;
  NSMutableArray<KKBezierPath *> *paths = [KKBezierPath
      pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64 options:0]];
  return CanvasSelectedLayerForPaths(paths, layerID).locked;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  // Reset the draw surface (no-op encode) so only the handle/path are visible.
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];
  // Locked layer: cleared surface only, no handles (and no Opt-reveal).
  if ([self _selectedLayerLocked])
    return;
  // The controller (KKPositionOSC) owns ALL the visibility + opt-reveal-ghost
  // gating internally (it reads kkOSCElementVisible / kkOSCRevealEligible +
  // ITS OWN optRevealActive). So just forward our reveal + drag state to it and
  // draw unconditionally - it draws nothing when hidden, the dim ghost when
  // Opt-revealed, full when shown. (Forwarding optRevealActive is the bit
  // Canvas needs that MagicMove/Glow don't: their primary handle is always
  // shown, so they never relied on the controller ghosting a hidden Position.)
  self.position.optRevealActive = self.optRevealActive;
  self.position.dragging = self.isDragging;
  [self.position drawPathInDestination:destinationImage
                                atTime:time
                            activePart:activePart];
  // Scale box, drawn over the motion path and under the Position handle (so the
  // handle stays on top + grabbable). The control owns its own visibility +
  // opt-reveal-ghost gating.
  [self _syncScaleControlAtTime:time];
  [self.scale drawInDestination:destinationImage
                         atTime:time
                     activePart:activePart];
  [self.position drawHandleInDestination:destinationImage
                                  atTime:time
                              activePart:activePart];
}

// Track Option-hold (reveal) - local, modifier-only (no param read, which the
// OSC context can't do anyway). On change it requests a redraw so the handle
// appears/disappears as Option is pressed/released.
- (void)mouseMovedAtPositionX:(double)positionX
                    positionY:(double)positionY
                   activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers
                  forceUpdate:(BOOL *)forceUpdate
                       atTime:(CMTime)time {
  // FCP doesn't surface the held Option flag in mouseMoved for a hidden OSC
  // (it draws nothing), so the passed `modifiers` come through as 0. Read the
  // LIVE modifier state directly and OR it in (the bit constants differ:
  // NSEventModifierFlagOption vs kFxModifierKey_OPTION) so opt-reveal works
  // with the cursor anywhere, like the other plugins.
  FxModifierKeys eff = modifiers;
  if ([NSEvent modifierFlags] & NSEventModifierFlagOption)
    eff |= kFxModifierKey_OPTION;
  [self kkUpdateOptRevealWithModifiers:eff forceUpdate:forceUpdate];
}

- (NSArray<NSString *> *)oscElementKeys {
  return @[ @"Position", @"Path", @"Scale" ];
}

- (NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart == kCanvasOSCPathPart)
    return @"Path";
  if (activePart == kCanvasOSCScalePart)
    return @"Scale";
  if (activePart == kCanvasOSCPositionPart)
    return self.position.hoverTargetIsAnchor ? @"Path" : @"Position";
  return nil;
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  // Clear a move cursor forced on the previous hover; the hit branch re-sets
  // it.
  if (self.pointCursorSet) {
    id<FxOnScreenControlAPI_v4> resetAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [resetAPI setCursor:[NSCursor arrowCursor]];
    self.pointCursorSet = NO;
  }
  // Locked layer: nothing is grabbable (and Opt can't peek it back).
  if ([self _selectedLayerLocked])
    return;
  // The controller gates hit-testing on visibility + ITS optRevealActive, so a
  // hidden handle isn't grabbable unless Opt-revealed - forward the reveal flag
  // so a revealed ghost becomes hittable (opt-click re-shows it).
  self.position.optRevealActive = self.optRevealActive;
  KKPositionHit ph = [self.position hitTestAtX:positionX
                                             y:positionY
                                        atTime:time];
  if (ph != KKPositionHitNone) {
    *activePart = (ph == KKPositionHitTangentHandle) ? kCanvasOSCPathPart
                                                     : kCanvasOSCPositionPart;
    self.pointCursorSet = YES; // the controller set the move/eye cursor
    // When an opt-click would toggle this element's visibility (master on),
    // show the eye / eye.slash affordance over its handle instead.
    NSCursor *eye = [self
        kkVisibilityCursorForLabel:[self
                                       oscElementKeyForActivePart:*activePart]];
    if (eye) {
      id<FxOnScreenControlAPI_v4> oscAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      [oscAPI setCursor:eye];
    }
    return;
  }
  // Scale box handles, checked after the Position handle/path miss (the control
  // owns reachability + the opt-hover eye affordance + the resize cursor).
  [self _syncScaleControlAtTime:time];
  if ([self.scale hitTestHandleAtX:positionX y:positionY atTime:time] >= 0)
    *activePart = kCanvasOSCScalePart;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Opt-click over the handle (master on) toggles this element's visibility
  // instead of dragging; master off leaves it a normal drag (peek-and-use).
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers]) {
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
  if (activePart == kCanvasOSCScalePart) {
    [self _syncScaleControlAtTime:time];
    [self.scale mouseDownAtX:positionX
                           y:positionY
                   modifiers:modifiers
                 forceUpdate:forceUpdate
                      atTime:time];
    return;
  }
  if (activePart != kCanvasOSCPositionPart && activePart != kCanvasOSCPathPart)
    return;
  KKPositionHit hit =
      (activePart == kCanvasOSCPathPart)
          ? KKPositionHitTangentHandle
          : (self.position.hoverTargetIsAnchor ? KKPositionHitAnchorDot
                                               : KKPositionHitHandle);
  [self.position mouseDownAtX:positionX
                            y:positionY
                          hit:hit
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  // Opt-hide latched on the first event sticks for the rest of the interaction
  // (so an opt-click doesn't half-drag).
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers])
    return;
  if (activePart == kCanvasOSCScalePart) {
    [self _syncScaleControlAtTime:time];
    [self.scale mouseDraggedAtX:positionX
                              y:positionY
                      modifiers:modifiers
                    forceUpdate:forceUpdate
                         atTime:time];
    return;
  }
  if (activePart != kCanvasOSCPositionPart && activePart != kCanvasOSCPathPart)
    return;
  KKPositionHit hit =
      (activePart == kCanvasOSCPathPart)
          ? KKPositionHitTangentHandle
          : (self.position.hoverTargetIsAnchor ? KKPositionHitAnchorDot
                                               : KKPositionHitHandle);
  [self.position mouseDraggedAtX:positionX
                               y:positionY
                             hit:hit
                       modifiers:modifiers
                     forceUpdate:forceUpdate
                          atTime:time];
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self kkResetOptHideArming];
  [self.position mouseUp];
  [self.scale mouseUp];
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

// Called inside the KKPositionOSC control's open action scope (same
// apiManager), so the get/set API resolves here. `tl` is the selected layer's
// full timeline with the Position edit applied; its lanes carry `layerKey`,
// which tells us the owning layer. Write the edit back into that layer's
// animationJSON in the shared layer blob, then refresh the snapshot for
// immediate redraw.
- (void)_persistSelectedLayerTimeline:(KKTimeline *)tl {
  if (!tl)
    return;
  NSString *layerID = nil;
  for (KKLane *l in tl.lanes)
    if (l.layerKey.length) {
      layerID = l.layerKey;
      break;
    }
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI)
    return;
  // The OSC can't READ kParamLayerData (its retrieval API comes back empty), so
  // load the stack from the inspector-published blob snapshot, splice the edit
  // in, and WRITE it back (the setting API does resolve here).
  NSString *b64 = CanvasLayerBlobSnapshot();
  NSMutableArray<KKBezierPath *> *paths =
      b64.length
          ? [KKBezierPath
                pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64
                                                                  options:0]]
          : [NSMutableArray array];
  KKBezierPath *layer = CanvasSelectedLayerForPaths(paths, layerID);
  if (!layer)
    return;
  CanvasApplyTimelineToPath(tl, layer);
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  NSString *newB64 = [blob base64EncodedStringWithOptions:0];
  KKWriteCustomParamString(setAPI, newB64, kParamLayerData);
  // Keep both snapshots in step so the control's next draw + the next drag tick
  // read the new value before the param round-trip republishes them.
  KKSetProcessTimelineSnapshot(tl);
  CanvasSetLayerBlobSnapshot(newB64);
}

@end
