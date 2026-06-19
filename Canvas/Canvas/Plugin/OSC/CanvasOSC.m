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
// +Input (hit-test + mouse handling). This file owns the lifecycle, drawing, and
// the OSC-element key mapping.
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
  }
  return self;
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

- (NSArray<NSString *> *)oscElementKeys {
  return @[
    @"Position", @"Path", @"Scale", @"Rotation", @"Rotation.X", @"Rotation.Y",
    @"Rotation.Z"
  ];
}

- (NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart == CanvasOSCPartPath)
    return @"Path";
  if (activePart == CanvasOSCPartScale)
    return @"Scale";
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
