/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC.h"
#import "CanvasLayerRender.h"
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
static const NSInteger kCanvasOSCRotationPart = 4;
// Auto-select: claim a click over an (unselected) image layer to select it.
static const NSInteger kCanvasOSCLayerPickPart = 5;

@interface CanvasOSC ()
@property(nonatomic, strong) KKPositionOSC *position;
@property(nonatomic, strong) KKScaleOSC *scale;
@property(nonatomic, strong) KKRotationOSC *rotation;
@property(nonatomic) BOOL pointCursorSet;
// Layer the hover hit-test resolved for an auto-select pick; consumed by the
// matching mouseDown.
@property(nonatomic, copy, nullable) NSString *pendingPickLayerID;
// Override of the kit's (private) opt-click element-hide writer, so Canvas's
// per-layer + full-state write is used instead of the kit's partial one.
- (void)kkToggleOSCElementHidden:(NSString *)key;
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
    // Rotation gizmo (3-axis rings), concentric with the Position handle. Same
    // per-layer persist. Drawn under the scale box + Position handle.
    _rotation = [[KKRotationOSC alloc] initWithAPIManager:apiManager
                                                laneLabel:@"Rotation"];
    _rotation.rotationActivePart = kCanvasOSCRotationPart;
    for (KKLane *l in [CanvasPlugin availableLanes])
      if ([l.label isEqualToString:@"Rotation"])
        _rotation.templateLane = l;
    _rotation.onTimelinePersist = ^(KKTimeline *tl) {
      [weak _persistSelectedLayerTimeline:tl];
    };
  }
  return self;
}

// The canvas-pixel lengths of the object-space unit axes: maps OBJECT (0,0),
// (1,0), (0,1) to CANVAS and returns the X-axis and Y-axis spans. Object space
// is normalised [0,1] but the canvas is W:H pixels, so these give both the
// gizmo's reference size and the pixel aspect. NO when the OSC API is absent.
- (BOOL)_objectBasisWidth:(double *)outW height:(double *)outH {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;
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
  *outW = hypot(cx.x - c0.x, cx.y - c0.y);
  *outH = hypot(cy.x - c0.x, cy.y - c0.y);
  return YES;
}

// Min dimension of the canvas frame - the reference length the scale gizmo sizes
// against, so the box tracks the clip with viewer zoom rather than being a fixed
// screen size.
- (double)_onScreenFrameMin {
  double w = 0, h = 0;
  if (![self _objectBasisWidth:&w height:&h])
    return 1000.0;
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

// Feed the rotation control this tick's centre (= the layer's Position handle)
// + reveal/drag state. Shared by draw / hit-test / mouse.
- (void)_syncRotationControlAtTime:(CMTime)time {
  self.rotation.center = [self.position positionCanvasAtTime:time];
  self.rotation.optRevealActive = self.optRevealActive;
  self.rotation.dragging = self.isDragging;
}

// Whether the selected layer (the one the OSC reads via the process timeline
// snapshot) is locked. A locked layer is visible-but-non-interactive: its OSC
// is neither drawn nor hit-testable, and Opt-hold can't peek it back - matching
// the mini-viewer's `handlesLocked`. Derived the same way as the persist path:
// the snapshot lanes carry the owning `layerKey`; resolve it in the published
// layer blob.
// The current layer stack, decoded from the inspector-published blob snapshot
// (the OSC can't read kParamLayerData directly). Cached by the blob string so a
// hover (which hit-tests every mouse-move) doesn't re-decode the blob each tick;
// re-decodes only when the blob actually changes. Read-only callers - the
// persist path decodes its own fresh copy before mutating.
- (NSArray<KKBezierPath *> *)_snapshotPaths {
  NSString *b64 = CanvasLayerBlobSnapshot();
  if (!b64.length)
    return @[];
  static NSString *sLastB64 = nil;
  static NSArray<KKBezierPath *> *sLastPaths = nil;
  if (sLastPaths && [b64 isEqualToString:sLastB64])
    return sLastPaths;
  NSArray<KKBezierPath *> *paths = [KKBezierPath
      pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64 options:0]];
  sLastB64 = [b64 copy];
  sLastPaths = paths;
  return paths;
}

// The layer the OSC acts on, resolved against the stack (nil/topmost handled):
// the process timeline snapshot's lanes carry the owning layerKey (set by the
// inspector when it publishes the selected layer's timeline).
- (KKBezierPath *)_selectedLayer {
  NSString *layerID = nil;
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if (l.layerKey.length) {
      layerID = l.layerKey;
      break;
    }
  return CanvasSelectedLayerForPaths([self _snapshotPaths], layerID);
}

- (NSString *)_resolvedSelectedLayerID {
  return [self _selectedLayer].layerID;
}

- (BOOL)_selectedLayerLocked {
  return [self _selectedLayer].locked;
}

// The current kParamUIState as a dictionary, parsed from the inspector-published
// snapshot (the OSC can't read the custom param itself). Empty dict when absent.
- (NSDictionary *)_uiStateDict {
  NSString *json = CanvasUIStateSnapshot();
  NSDictionary *st =
      json.length
          ? [NSJSONSerialization
                JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                           options:0
                             error:nil]
          : nil;
  return [st isKindOfClass:[NSDictionary class]] ? st : @{};
}

// Mutate kParamUIState and write it back inside an action scope. The OSC can't
// READ the custom param to merge, so `mutate` runs on a copy of the published
// snapshot (preserving every key Canvas keeps there - selectedLayerID,
// activeTab, oscElementsByLayer, ...); the write fires the effect's
// parameterChanged, and we republish the snapshot so a follow-up write sees the
// new value before the round-trip. The single home for OSC-side UIState writes.
- (void)_writeUIStateMerging:(void (^)(NSMutableDictionary *state))mutate {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!actionAPI || !setAPI)
    return;
  NSMutableDictionary *state = [[self _uiStateDict] mutableCopy];
  mutate(state);
  NSString *newJSON = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  [actionAPI startAction:self];
  KKWriteCustomParamString(setAPI, newJSON, kParamUIState);
  [actionAPI endAction:self];
  CanvasSetUIStateSnapshot(newJSON);
}

// "Auto-select layers" toggle, read from the UIState snapshot (the OSC can't
// read the custom param). Default OFF when absent.
- (BOOL)_autoSelectEnabled {
  return [[self _uiStateDict][@"autoSelect"] boolValue];
}

// Canvas pixel aspect (outputWidth/outputHeight), from the object-space basis.
- (double)_canvasAspect {
  double w = 0, h = 0;
  if (![self _objectBasisWidth:&w height:&h] || h <= 0.0)
    return 1.0;
  return w / h;
}

// Topmost image layer under the cursor (alpha-aware), or nil. Converts the
// canvas mouse point to object space and evaluates each layer's transform at the
// playhead fraction.
- (NSString *)_pickLayerIDAtX:(double)x y:(double)y atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return nil;
  double ox = 0, oy = 0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:x
                          fromY:y
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&ox
                            toY:&oy];
  // FCP's OBJECT space here is Y-DOWN (oy=0 at the top) while the render's object
  // space (CanvasTransformCorner, the quads) is Y-UP (Y=0 at the bottom), so the
  // mouse Y must be flipped to land in the same space. This is what made
  // off-centre layers unselectable (centred/full-frame ones are flip-invariant,
  // so they appeared to work) and X-rotation look mirrored.
  oy = 1.0 - oy;
  NSArray<KKBezierPath *> *paths = [self _snapshotPaths];
  if (!paths.count)
    return nil;
  return CanvasHitTestLayerID(paths, [self fractionAtTime:time],
                              (float)[self _canvasAspect], (float)ox, (float)oy,
                              /*alphaAware=*/YES, /*excluded=*/nil,
                              /*requireEditableAtFrac=*/YES,
                              [CanvasPlugin availableLanes]);
}

// Merge the picked layer id into the current UIState (snapshot base, since the
// OSC can't read the custom param) and write it back inside an action scope. The
// write fires the effect's parameterChanged, which re-selects the layer in the
// inspector + drives the per-layer OSC/mini state. Mirrors the kit's OSC opt-hide
// write (kkToggleOSCElementHidden).
- (void)_commitPickSelection {
  NSString *layerID = self.pendingPickLayerID;
  if (!layerID.length)
    return;
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[@"selectedLayerID"] = layerID;
  }];
}

// Master-on opt-click over a handle toggles that element's visibility. The kit
// base rebuilds kParamUIState from `st.lastUIState` and writes the GLOBAL
// "oscElements" key - but Canvas keeps visibility PER LAYER
// ("oscElementsByLayer") and overwrites lastUIState with a partial 2-key dict on
// every layer switch (canvasApplyOSCForLayer), so the kit write (a) doesn't
// persist for Canvas's per-layer read and (b) DROPS selectedLayerID/activeTab,
// resetting selection to topmost + the tab to Basic. Override to flip the
// SELECTED layer's set and write the FULL state, merged into the snapshot base
// (the OSC can't read the custom param to merge itself).
- (void)kkToggleOSCElementHidden:(NSString *)key {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  NSMutableSet<NSString *> *hidden =
      [(st.hiddenOSCElements ?: [NSSet set]) mutableCopy];
  if ([hidden containsObject:key])
    [hidden removeObject:key];
  else
    [hidden addObject:key];
  st.hiddenOSCElements = hidden;

  NSString *layerID = [self _resolvedSelectedLayerID] ?: @"";
  NSMutableDictionary<NSString *, NSNumber *> *els =
      [NSMutableDictionary dictionary];
  for (NSString *k in [self oscElementKeys])
    els[k] = @(![hidden containsObject:k]);

  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    NSMutableDictionary *byLayer =
        [(state[@"oscElementsByLayer"] ?: @{}) mutableCopy];
    byLayer[layerID] = els;
    state[@"oscElementsByLayer"] = byLayer;
    st.oscElementsByOwner = byLayer; // keep the in-process map in step
    st.lastUIState = state;
  }];
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
  // Rotation rings, drawn under the scale box + Position handle. The control
  // owns its own per-axis visibility + opt-reveal-ghost gating.
  [self _syncRotationControlAtTime:time];
  [self.rotation drawInDestination:destinationImage
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
  return @[
    @"Position", @"Path", @"Scale", @"Rotation", @"Rotation.X", @"Rotation.Y",
    @"Rotation.Z"
  ];
}

- (NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart == kCanvasOSCPathPart)
    return @"Path";
  if (activePart == kCanvasOSCScalePart)
    return @"Scale";
  if (activePart == kCanvasOSCPositionPart)
    return self.position.hoverTargetIsAnchor ? @"Path" : @"Position";
  if (activePart == kCanvasOSCRotationPart) {
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
  // Locked SELECTED layer: its own handles aren't grabbable (and Opt can't peek
  // them back). Auto-select still runs below, so you can click a different layer
  // to switch away from a locked one.
  if (![self _selectedLayerLocked]) {
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
          kkVisibilityCursorForLabel:[self oscElementKeyForActivePart:
                                               *activePart]];
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
    if ([self.scale hitTestHandleAtX:positionX y:positionY atTime:time] >= 0) {
      *activePart = kCanvasOSCScalePart;
      return;
    }
    // Rotation rings, checked last (they sit inside the scale box). The control
    // owns reachability + the per-axis opt-hover eye + the rotate cursor.
    [self _syncRotationControlAtTime:time];
    if ([self.rotation hitTestRingAtX:positionX y:positionY atTime:time] >= 0) {
      *activePart = kCanvasOSCRotationPart;
      return;
    }
  }

  // Auto-select: no handle was grabbed, so if the toggle is on, claim a click
  // over the topmost (unselected) image layer to select it. Clicking the
  // already-selected layer is a no-op (don't claim - leave the click to FCP).
  self.pendingPickLayerID = nil;
  if ([self _autoSelectEnabled]) {
    NSString *hit = [self _pickLayerIDAtX:positionX y:positionY atTime:time];
    if (hit.length && ![hit isEqualToString:[self _resolvedSelectedLayerID]]) {
      self.pendingPickLayerID = hit;
      *activePart = kCanvasOSCLayerPickPart;
      id<FxOnScreenControlAPI_v4> oscAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      [oscAPI setCursor:[NSCursor pointingHandCursor]];
      self.pointCursorSet = YES;
    }
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Auto-select pick: the hover hit-test claimed a click over an unselected
  // image layer - commit the selection and consume the click (no drag).
  if (activePart == kCanvasOSCLayerPickPart) {
    [self _commitPickSelection];
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
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
  if (activePart == kCanvasOSCRotationPart) {
    [self _syncRotationControlAtTime:time];
    [self.rotation mouseDownAtX:positionX
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
  if (activePart == kCanvasOSCRotationPart) {
    [self _syncRotationControlAtTime:time];
    [self.rotation mouseDraggedAtX:positionX
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
  [self.rotation mouseUp];
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
