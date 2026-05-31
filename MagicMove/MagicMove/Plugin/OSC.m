/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

static NSInteger const kOSCPositionPart = 1;
static NSInteger const kOSCRotationPart = 2;

static KKLane *_laneNamed(NSString *label) {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

static KKLane *_positionLane(void) { return _laneNamed(@"Position"); }
static KKLane *_rotationLane(void) { return _laneNamed(@"Rotation"); }

// YES when the lane is a constant (always shown) OR animated with the
// playhead within ~1 frame of a keypose.
// Whether a given OSC element (lane label, e.g. @"Position"/@"Rotation") is
// visible: the master tick is on AND the element isn't individually hidden via
// the settings popover. Read from this instance's KKPluginInstanceState
// (resolved via the shared kKKParamInstanceID UUID, which IS readable from the
// OSC's separate apiManager scope - the UI-state blob is not). No per-instance
// state yet => visible (matches the pre-toggle default).
static BOOL _oscElementVisible(id<PROAPIAccessing> api, NSString *label) {
  KKPluginInstanceState *st = KKInstanceStateForAPI(api);
  if (!st)
    return YES;
  if (!st.oscMasterVisible)
    return NO;
  return !(st.hiddenOSCElements && [st.hiddenOSCElements containsObject:label]);
}

static BOOL _positionVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_positionLane(), frac,
                                 KKProcessFrameDurationSeconds());
}
static BOOL _rotationVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_rotationLane(), frac,
                                 KKProcessFrameDurationSeconds());
}

static NSArray<NSNumber *> *_positionValuesAtFraction(double frac) {
  KKLane *lane = _positionLane();
  if (!lane)
    return @[ @0.5, @0.5 ];
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  return v.count >= 2 ? v : @[ @0.5, @0.5 ];
}

// (rotX, rotY, rotZ) in DEGREES (matches storage).
static NSArray<NSNumber *> *_rotationValuesAtFraction(double frac) {
  KKLane *lane = _rotationLane();
  if (!lane)
    return @[ @0.0, @0.0, @0.0 ];
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  if (v.count >= 3)
    return v;
  NSMutableArray *out = [NSMutableArray arrayWithArray:v];
  while (out.count < 3)
    [out addObject:@0.0];
  return out;
}

@interface MagicMoveOSC ()
@property(nonatomic, retain) KKSnapEngine *snapEngine;
@property(nonatomic, retain) KKRotationOSC *rotationOSC;
/// YES while the user holds Cmd during a position drag - snaps to canvas
/// anchors and other keypose positions. Default is free (no snap) so the
/// user can position pixel-precisely without fighting the engine.
@property(nonatomic) BOOL cmdSnapActive;
/// Object-space position captured at position-drag mouseDown. Used as the
/// anchor for Shift axis-lock: the locked axis stays pinned to this value,
/// the dominant axis tracks the cursor.
@property(nonatomic) simd_float2 posPressObject;
@property(nonatomic)
    CGPoint rotPressCanvas;            // canvas pixel where rot drag began
@property(nonatomic) double rotPressX; // rotation values (rad) at press
@property(nonatomic) double rotPressY;
@property(nonatomic) double rotPressZ;
// Per-drag continuity anchor: last-written Euler values. The Euler
// decomposition has two valid reps and as drag accumulates past ~270° the
// "nearest to press" rule starts picking the wrong one (because press is
// far away). Using the previous tick's output as the anchor keeps the
// per-tick angular step small and unambiguous.
@property(nonatomic) double rotLastWrittenX;
@property(nonatomic) double rotLastWrittenY;
@property(nonatomic) double rotLastWrittenZ;
@end

@implementation MagicMoveOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _snapEngine = [[KKSnapEngine alloc] init];
    _rotationOSC = [[KKRotationOSC alloc] initWithAPIManager:apiManager];
  }
  return self;
}

// Pull X/Y/Z ring colors from the Rotation lane's `componentLabelColors`
// (already red/green/blue in the timeline) so OSC matches the inspector.
- (void)_syncRotationColorsFromLane {
  KKLane *lane = _rotationLane();
  if (lane.componentLabelColors.count >= 3) {
    self.rotationOSC.colorX = lane.componentLabelColors[0];
    self.rotationOSC.colorY = lane.componentLabelColors[1];
    self.rotationOSC.colorZ = lane.componentLabelColors[2];
  }
}

- (double)_fractionAtTime:(CMTime)time {
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return 0.0;
  CMTime effectStart = kCMTimeZero, effectDur = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDur];
  double durSec = CMTimeGetSeconds(effectDur);
  if (durSec <= 0)
    return 0.0;
  return MAX(0.0,
             MIN(1.0, (CMTimeGetSeconds(time) - CMTimeGetSeconds(effectStart)) /
                          durSec));
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  NSArray<NSNumber *> *vals =
      _positionValuesAtFraction([self _fractionAtTime:time]);
  double objX = vals[0].doubleValue;
  double objY = vals[1].doubleValue;
  CGPoint canvas = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:objX
                          fromY:objY
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvas.x
                            toY:&canvas.y];
  return canvas;
}

// Snap the live drag position against canvas edges (0/1), the centre (0.5),
// thirds (0.25/0.75), and every other keypose's stored position. Object
// space; threshold defaults to ~8 canvas pixels via KKSnapEngine.
- (simd_float2)_snapPosition:(simd_float2)p atFraction:(double)frac {
  KKLane *lane = nil;
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:@"Position"]) {
      lane = l;
      break;
    }
  static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  // Skip the keypose being edited (closest to playhead frac - drag overwrites
  // it, so snapping back to it would lock the handle in place).
  NSInteger best = -1;
  if (lane.keyposes.count > 0) {
    double bd = 1e9;
    for (NSInteger k = 0; k < (NSInteger)lane.keyposes.count; k++) {
      double d = fabs(lane.keyposes[k].time - frac);
      if (d < bd) {
        bd = d;
        best = k;
      }
    }
  }
  NSUInteger nObj = 0;
  simd_float2 *objs = lane.keyposes.count
                          ? malloc(lane.keyposes.count * sizeof(simd_float2))
                          : NULL;
  for (NSInteger k = 0; k < (NSInteger)lane.keyposes.count; k++) {
    if (k == best)
      continue;
    NSArray<NSNumber *> *v = lane.keyposes[k].values;
    if (v.count < 2)
      continue;
    objs[nObj++] =
        (simd_float2){(float)v[0].doubleValue, (float)v[1].doubleValue};
  }
  // One object unit spans one image width in canvas pixels.
  CGPoint o0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint o1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
  float pxPerUnit = (float)fabs(o1.x - o0.x);
  float thr = (pxPerUnit > 0) ? self.snapEngine.threshold / pxPerUnit : 0.005f;
  simd_float2 snapped = [self.snapEngine snapPoint:p
                                    canvasAnchorsX:anchors
                                            countX:5
                                    canvasAnchorsY:anchors
                                            countY:5
                                     objectTargets:objs
                                             count:nObj
                                        thresholdX:thr
                                        thresholdY:thr];
  if (objs)
    free(objs);
  return snapped;
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self.snapEngine reset];
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  // Clear the draw surface (the encode call is a no-op draw but resets the
  // attachment) so the handle is the only thing visible.
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  double frac = [self _fractionAtTime:time];
  BOOL posVisible = (self.isDragging && activePart == kOSCPositionPart) ||
                    (_oscElementVisible(self.apiManager, @"Position") &&
                     _positionVisibleAtFraction(frac));

  CGPoint pos = [self oscPositionAtTime:time];
  if (posVisible) {
    [self
        drawAtCanvasPosition:pos
                   isHovered:(activePart == kOSCPositionPart)
                    isActive:self.isDragging && (activePart == kOSCPositionPart)
            destinationImage:destinationImage
                      atTime:time];
  }

  // Rotation sphere is centred on the same canvas point as Position (the
  // image rotates around its centre, which is where Position translates it).
  BOOL rotVisible = (self.isDragging && activePart == kOSCRotationPart) ||
                    (_oscElementVisible(self.apiManager, @"Rotation") &&
                     _rotationVisibleAtFraction(frac));
  if (rotVisible) {
    [self _syncRotationColorsFromLane];
    self.rotationOSC.showX = _oscElementVisible(self.apiManager, @"Rotation.X");
    self.rotationOSC.showY = _oscElementVisible(self.apiManager, @"Rotation.Y");
    self.rotationOSC.showZ = _oscElementVisible(self.apiManager, @"Rotation.Z");
    NSArray<NSNumber *> *r = _rotationValuesAtFraction(frac);
    self.rotationOSC.rotX = (float)(r[0].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotY = (float)(r[1].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotZ = (float)(r[2].doubleValue * M_PI / 180.0);
    self.rotationOSC.center = pos;
    [self.rotationOSC
        drawAtCanvasPosition:pos
                   isHovered:(activePart == kOSCRotationPart)
                    isActive:self.isDragging && (activePart == kOSCRotationPart)
            destinationImage:destinationImage
                      atTime:time];
  }
  if (self.isDragging && activePart == kOSCPositionPart && self.cmdSnapActive) {
    simd_float4 yellow = {1, 1, 0, 1};
    NSColor *accentNS = [[NSColor accentMatchingHost]
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat ar = 1, ag = 1, ab = 1, aa = 1;
    [accentNS getRed:&ar green:&ag blue:&ab alpha:&aa];
    simd_float4 accent = {(float)ar, (float)ag, (float)ab, (float)aa};
    [self.snapEngine drawSnapGuidesWithOSC:self
                             isObjectSpace:YES
                               canvasColor:yellow
                               objectColor:accent
                          destinationImage:destinationImage];
  }
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  double frac = [self _fractionAtTime:time];
  if (_oscElementVisible(self.apiManager, @"Position") &&
      _positionVisibleAtFraction(frac) &&
      [self hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    *activePart = kOSCPositionPart;
    return;
  }
  if (_oscElementVisible(self.apiManager, @"Rotation") &&
      _rotationVisibleAtFraction(frac)) {
    CGPoint c = [self oscPositionAtTime:time];
    self.rotationOSC.showX = _oscElementVisible(self.apiManager, @"Rotation.X");
    self.rotationOSC.showY = _oscElementVisible(self.apiManager, @"Rotation.Y");
    self.rotationOSC.showZ = _oscElementVisible(self.apiManager, @"Rotation.Z");
    NSArray<NSNumber *> *r = _rotationValuesAtFraction(frac);
    self.rotationOSC.rotX = (float)(r[0].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotY = (float)(r[1].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotZ = (float)(r[2].doubleValue * M_PI / 180.0);
    self.rotationOSC.center = c;
    if ([self.rotationOSC hitTestAtMousePositionX:positionX
                                        positionY:positionY
                                           atTime:time]) {
      *activePart = kOSCRotationPart;
    }
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
  if (activePart == kOSCPositionPart) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (oscAPI) {
      double objX = 0.0, objY = 0.0;
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                              fromX:positionX
                              fromY:positionY
                            toSpace:kFxDrawingCoordinates_OBJECT
                                toX:&objX
                                toY:&objY];
      self.posPressObject = (simd_float2){(float)objX, (float)objY};
    }
  }
  if (activePart == kOSCRotationPart) {
    double frac = [self _fractionAtTime:time];
    // Capture press values from the KEYPOSE we'll write to (the one nearest
    // the playhead), not the smoothed interpolation. The smoothed reader
    // uses an easing curve that overshoots near keypose boundaries - if we
    // used it as the press baseline, the non-dragged axes would inherit
    // that overshoot and silently overwrite the keypose's actual values.
    KKLane *rotLane = _rotationLane();
    NSArray<NSNumber *> *r = nil;
    if (rotLane.keyposes.count > 0) {
      NSInteger best = 0;
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)rotLane.keyposes.count; k++) {
        double d = fabs(rotLane.keyposes[k].time - frac);
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      r = rotLane.keyposes[best].values;
    }
    if (r.count < 3)
      r = @[ @0.0, @0.0, @0.0 ];
    self.rotPressX = r[0].doubleValue * M_PI / 180.0;
    self.rotPressY = r[1].doubleValue * M_PI / 180.0;
    self.rotPressZ = r[2].doubleValue * M_PI / 180.0;
    self.rotLastWrittenX = self.rotPressX;
    self.rotLastWrittenY = self.rotPressY;
    self.rotLastWrittenZ = self.rotPressZ;
    self.rotPressCanvas = CGPointMake(positionX, positionY);
    // Sync the inner OSC to the live (smoothed) timeline values - that's
    // what the user actually sees on screen, so the press tangent has to be
    // computed against the same pose. The additive base above uses the
    // raw keypose so non-dragged axes stay untouched at write time.
    NSArray<NSNumber *> *smoothed = _rotationValuesAtFraction(frac);
    self.rotationOSC.rotX = (float)(smoothed[0].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotY = (float)(smoothed[1].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotZ = (float)(smoothed[2].doubleValue * M_PI / 180.0);
    self.rotationOSC.center = [self oscPositionAtTime:time];
    [self.rotationOSC mouseDownAtPositionX:positionX
                                 positionY:positionY
                                activePart:activePart
                                 modifiers:modifiers
                               forceUpdate:forceUpdate
                                    atTime:time];
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (activePart == kOSCRotationPart) {
    [self _dragRotationToPositionX:positionX
                         positionY:positionY
                         modifiers:modifiers
                       forceUpdate:forceUpdate
                            atTime:time];
    return;
  }
  if (activePart != kOSCPositionPart)
    return;

  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  double newX = 0.0, newY = 0.0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:positionX
                          fromY:positionY
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&newX
                            toY:&newY];

  // Shift axis-lock: pin whichever axis has less travel from the press
  // point, so the cursor controls the dominant axis only. Decided per
  // tick so the user can change their mind mid-drag.
  if (modifiers & kFxModifierKey_SHIFT) {
    double dx = newX - (double)self.posPressObject.x;
    double dy = newY - (double)self.posPressObject.y;
    if (fabs(dx) >= fabs(dy))
      newY = self.posPressObject.y;
    else
      newX = self.posPressObject.x;
  }

  // Snap is OFF by default; Cmd engages it. Free-by-default keeps
  // pixel-precise positioning quiet, and matches the rotation OSC where
  // Cmd snaps to 15deg.
  self.cmdSnapActive = (modifiers & kFxModifierKey_COMMAND) != 0;
  double frac = [self _fractionAtTime:time];
  if (self.cmdSnapActive) {
    simd_float2 snapped =
        [self _snapPosition:(simd_float2){(float)newX, (float)newY}
                 atFraction:frac];
    newX = snapped.x;
    newY = snapped.y;
  } else {
    [self.snapEngine reset];
  }

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    [actionAPI endAction:self];
    return;
  }

  // Snapshot is canonical - the param read returns empty inside the OSC
  // action scope. Copy then mutate the Position lane's keypose nearest the
  // current playhead fraction, preserving structure / intervals.
  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? [snap copy] : [KKTimeline timeline];
  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Position"]) {
      laneIdx = i;
      break;
    }
  }

  NSArray<NSNumber *> *newValues = @[ @(newX), @(newY) ];
  KKLane *posLane;
  if (laneIdx == NSNotFound) {
    posLane = [KKLane laneWithLabel:@"Position"];
    posLane.valueType = KKLaneValueTypeGeneric;
    posLane.componentMin = @[];
    posLane.componentMax = @[];
    posLane.componentUnits = @[ @"px", @"px" ];
    posLane.componentLabels = @[ @"X", @"Y" ];
    posLane.enabled = NO;
    posLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:posLane];
  } else {
    posLane = [lanes[laneIdx] copy];
    NSArray<KKKeyPose *> *kps = posLane.keyposes;
    if (kps.count == 0) {
      posLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    } else {
      NSInteger best = 0;
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
        double d = fabs(kps[k].time - frac);
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithArray:kps];
      // MRR dangling-pointer guard: cache old's fields BEFORE the replace.
      double oldTime = out[best].time;
      KKInterval *oldOutgoing = out[best].outgoing;
      KKKeyPose *nk = [KKKeyPose keyposeAtTime:oldTime values:newValues];
      nk.outgoing = oldOutgoing;
      out[best] = nk;
      // Hold-link propagation: a linked endpoint shares its partner's value.
      if (best + 1 < (NSInteger)out.count && nk.outgoing.endpointsLinked) {
        KKKeyPose *partner = out[best + 1];
        KKKeyPose *np = [KKKeyPose keyposeAtTime:partner.time values:newValues];
        np.outgoing = partner.outgoing;
        out[best + 1] = np;
      }
      if (best > 0) {
        KKKeyPose *prev = out[best - 1];
        if (prev.outgoing.endpointsLinked) {
          KKKeyPose *np = [KKKeyPose keyposeAtTime:prev.time values:newValues];
          np.outgoing = prev.outgoing;
          out[best - 1] = np;
        }
      }
      posLane.keyposes = out;
    }
    lanes[laneIdx] = posLane;
  }
  tl.lanes = lanes;

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  *forceUpdate = YES;
}

- (void)_dragRotationToPositionX:(double)positionX
                       positionY:(double)positionY
                       modifiers:(NSUInteger)modifiers
                     forceUpdate:(BOOL *)forceUpdate
                          atTime:(CMTime)time {
  NSInteger axis = self.rotationOSC.activeAxis;
  if (axis < 0)
    return;
  double dAngle = [self.rotationOSC
      angleDeltaFromPressPoint:self.rotPressCanvas
                  currentPoint:CGPointMake(positionX, positionY)];
  // Cmd-snap rounds the OBJECT-axis delta itself to a 15° step, BEFORE
  // composing into Euler. Snapping the decomposed axis values directly
  // jiggles the other two axes (their decomposed values change tick-to-
  // tick as the object rotates, and rounding only one axis leaves a
  // matrix that doesn't correspond to a pure ring rotation).
  if (modifiers & kFxModifierKey_COMMAND) {
    const double kSnapRad = 15.0 * M_PI / 180.0;
    dAngle = round(dAngle / kSnapRad) * kSnapRad;
  }
  // Compose around the OBJECT's current ring axis: R_new = R_press *
  // R_axis(dAngle). This rotates around the visible ring (which is the
  // image's current basis), so dragging the X ring after a Y rotation
  // spins the image around its current X, not global X - matching the
  // physical-knob intuition the user expects.
  //
  // The earlier "additive on dragged axis only" version dodged the asin
  // gimbal-clamp at ±90° but rotated around global axes instead, which
  // felt wrong once any other axis was non-zero. We bring back the compose
  // and handle the asin discontinuity by picking the Euler decomposition
  // closest to the press pose - so a 0→90→180 sweep stays continuous.
  double lastRx = self.rotLastWrittenX;
  double lastRy = self.rotLastWrittenY;
  double lastRz = self.rotLastWrittenZ;
  double rx = 0, ry = 0, rz = 0;
  KKRotationComposeAxisDelta((int)axis, dAngle, self.rotPressX, self.rotPressY,
                             self.rotPressZ, &lastRx, &lastRy, &lastRz, &rx,
                             &ry, &rz);
  self.rotLastWrittenX = lastRx;
  self.rotLastWrittenY = lastRy;
  self.rotLastWrittenZ = lastRz;
  const double kRadToDeg = 180.0 / M_PI;
  double xDeg = rx * kRadToDeg;
  double yDeg = ry * kRadToDeg;
  double zDeg = rz * kRadToDeg;
  NSArray<NSNumber *> *newValues = @[ @(xDeg), @(yDeg), @(zDeg) ];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    [actionAPI endAction:self];
    return;
  }

  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? [snap copy] : [KKTimeline timeline];
  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Rotation"]) {
      laneIdx = i;
      break;
    }
  }
  double frac = [self _fractionAtTime:time];
  KKLane *rotLane;
  if (laneIdx == NSNotFound) {
    rotLane = [KKLane laneWithLabel:@"Rotation"];
    rotLane.valueType = KKLaneValueTypeGeneric;
    rotLane.componentUnits = @[ @"°", @"°", @"°" ];
    rotLane.componentLabels = @[ @"X", @"Y", @"Z" ];
    rotLane.enabled = NO;
    rotLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:rotLane];
  } else {
    rotLane = [lanes[laneIdx] copy];
    NSArray<KKKeyPose *> *kps = rotLane.keyposes;
    if (kps.count == 0) {
      rotLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    } else {
      NSInteger best = 0;
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
        double d = fabs(kps[k].time - frac);
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithArray:kps];
      double oldTime = out[best].time;
      KKInterval *oldOutgoing = out[best].outgoing;
      KKKeyPose *nk = [KKKeyPose keyposeAtTime:oldTime values:newValues];
      nk.outgoing = oldOutgoing;
      out[best] = nk;
      if (best + 1 < (NSInteger)out.count && nk.outgoing.endpointsLinked) {
        KKKeyPose *partner = out[best + 1];
        KKKeyPose *np = [KKKeyPose keyposeAtTime:partner.time values:newValues];
        np.outgoing = partner.outgoing;
        out[best + 1] = np;
      }
      if (best > 0) {
        KKKeyPose *prev = out[best - 1];
        if (prev.outgoing.endpointsLinked) {
          KKKeyPose *np = [KKKeyPose keyposeAtTime:prev.time values:newValues];
          np.outgoing = prev.outgoing;
          out[best - 1] = np;
        }
      }
      rotLane.keyposes = out;
    }
    lanes[laneIdx] = rotLane;
  }
  tl.lanes = lanes;

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  *forceUpdate = YES;
}

@end
