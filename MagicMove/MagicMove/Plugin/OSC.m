/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

static NSInteger const kOSCPositionPart = 1;

static KKLane *_positionLane(void) {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:@"Position"])
      return lane;
  return nil;
}

// YES when Position is a constant (always shown) OR animated with the
// playhead within ~1 frame of a keypose.
static BOOL _positionVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_positionLane(), frac,
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

@implementation MagicMoveOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
  }
  return self;
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
  BOOL visible = self.isDragging || _positionVisibleAtFraction(frac);
  if (!visible)
    return;

  CGPoint pos = [self oscPositionAtTime:time];
  [self drawAtCanvasPosition:pos
                   isHovered:(activePart == kOSCPositionPart)
                    isActive:self.isDragging && (activePart == kOSCPositionPart)
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  if (!_positionVisibleAtFraction([self _fractionAtTime:time]))
    return;
  if ([self hitTestAtMousePositionX:positionX positionY:positionY atTime:time])
    *activePart = kOSCPositionPart;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
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
  double frac = [self _fractionAtTime:time];
  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? [[snap copy] autorelease] : [KKTimeline timeline];
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
    posLane = [[lanes[laneIdx] copy] autorelease];
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

@end
