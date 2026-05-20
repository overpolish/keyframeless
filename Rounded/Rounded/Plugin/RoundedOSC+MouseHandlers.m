/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "OSC_Internal.h"
#import "RoundedOSCRadiusMath.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

// Returns the KKCropOSC part for a Rounded activePart, or KKCropPartNone if
// it's not crop-related. Keeps the Rounded-side enum constants out of the KK
// header.
static NSInteger _kkCropPartForRoundedActive(NSInteger activePart) {
  if (activePart == kOSCCropRectPart)
    return KKCropPartRect;
  if (activePart >= kOSCCropPointBase &&
      activePart < kOSCCropPointBase + KKCropPointCount)
    return KKCropPartPointBase + (activePart - kOSCCropPointBase);
  return KKCropPartNone;
}

@implementation RoundedOSC (MouseHandlers)

- (void)keyDownAtPositionX:(double)mousePositionX
                 positionY:(double)mousePositionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time {
  *didHandle = NO;
  *forceUpdate = NO;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Route crop-handle / crop-rect presses to the embedded KKCropOSC, which
  // owns its own drag state. The radius super-handler ignores parts it
  // doesn't recognise.
  NSInteger cropPart = _kkCropPartForRoundedActive(activePart);
  if (cropPart != KKCropPartNone) {
    [_cropOSC mouseDownForPart:cropPart
                     positionX:positionX
                     positionY:positionY
                        atTime:time];
    return;
  }

  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];

  if (activePart == 0)
    return;

  _dragStartPosition = CGPointMake(positionX, positionY);
  _dragStartRadius =
      RoundedSnapshotRadiusAtFraction([self fractionAtTime:time]);
  _dragCurrentRadius = _dragStartRadius;

  if (RoundedSharedOSCGuideBridge().guideStep == 1) {
    RoundedSharedOSCGuideBridge().guideStep = 2;
    *forceUpdate = YES;
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  // Crop-part drag → delegate to the embedded KKCropOSC.
  NSInteger cropPart = _kkCropPartForRoundedActive(activePart);
  if (cropPart != KKCropPartNone) {
    [_cropOSC mouseDraggedForPart:cropPart
                        positionX:positionX
                        positionY:positionY
                      forceUpdate:forceUpdate
                           atTime:time];
    return;
  }

  if (activePart == 0)
    return;

  // Mirror oscPositionAtTime: drag math projects from the crop TR with the
  // crop's minDim (not the full-canvas anchor), so the cursor tracks the
  // handle 1:1 even with a non-default crop.
  double frac = [self fractionAtTime:time];
  CGPoint cropTR = CGPointZero;
  BOOL isFlippedX = NO, isFlippedY = NO;
  float minDim = 0.0f;
  // Use the cached crop-anchor helper on the OSC (declared in OSC.m's @impl).
  if (![self _cropAnchorCornerForFraction:frac
                                outCorner:&cropTR
                              outFlippedX:&isFlippedX
                              outFlippedY:&isFlippedY
                                outMinDim:&minDim] ||
      minDim <= 0)
    return;

  double dx = positionX - cropTR.x;
  double dy = positionY - cropTR.y;
  double signX = isFlippedX ? -1.0 : 1.0;
  double signY = isFlippedY ? -1.0 : 1.0;

  double mouseDist = (-dx * signX + -dy * signY) * 0.5 - self.oscSize;

  float lo = 0.0f, hi = 100.0f;
  for (int i = 0; i < 32; i++) {
    float mid = (lo + hi) * 0.5f;
    float padding = paddingForRadius(mid, minDim);
    if (padding < mouseDist)
      lo = mid;
    else
      hi = mid;
  }

  double newRadius = CLAMP((lo + hi) * 0.5, 0.0, 100.0);
  if (RoundedSharedOSCGuideBridge().guideStep == 2 &&
      fabs(newRadius - kOSCGuideTargetRadius) < 8.0)
    newRadius = kOSCGuideTargetRadius;
  _dragCurrentRadius = newRadius;

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

  // KKReadCustomParamString returns empty for kKKParamTimelineData in the OSC
  // mouse-drag action scope (verified via logs: jsonLen=0 even with getAPI
  // resolved). The parameterChanged-driven snapshot is canonical anyway —
  // start from it so the radius edit doesn't wipe In/Hold/Out structure.
  KKTimeline *snap = RoundedTimelineSnapshot();
  KKTimeline *tl = snap ? [[snap copy] autorelease] : [KKTimeline timeline];

  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Radius"]) {
      laneIdx = i;
      break;
    }
  }

  KKLane *radiusLane;
  if (laneIdx == NSNotFound) {
    // No lane: this is a fresh constant. Seed with one keypose at t=0.
    // (Visibility rule means the OSC was reachable because !lane → constant.)
    radiusLane = [KKLane laneWithLabel:@"Radius"];
    radiusLane.enabled = NO;
    radiusLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                               values:@[ @(newRadius) ]] ];
    [lanes addObject:radiusLane];
  } else {
    // Existing lane: replace the keypose value nearest the current playhead
    // fraction, preserving every other keypose's time/interval (so the In/
    // Hold/Out structure isn't wiped). Mirrors KKMiniCanvasRenderer's
    // `_timelineBySettingValues:forLabel:` boundary-edit path.
    radiusLane = [[lanes[laneIdx] copy] autorelease];
    NSArray<KKKeyPose *> *kps = radiusLane.keyposes;
    if (kps.count == 0) {
      radiusLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                                 values:@[ @(newRadius) ]] ];
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
      // MRR: cache old's fields BEFORE `out[best] = nk`. The replacement
      // releases the array's hold on `old`; if no other retainer exists it
      // dangles and subsequent property reads (incl. KKLog) crash. See
      // project_mrr_array_dangling.md — exact same pattern.
      double oldTime = out[best].time;
      KKInterval *oldOutgoing = out[best].outgoing;
      KKKeyPose *nk = [KKKeyPose keyposeAtTime:oldTime
                                        values:@[ @(newRadius) ]];
      nk.outgoing = oldOutgoing; // preserve easing/modulation
      out[best] = nk;
      radiusLane.keyposes = out;
    }
    lanes[laneIdx] = radiusLane;
  }
  tl.lanes = lanes;

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  *forceUpdate = YES;
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  // Always reset crop drag state on mouseUp (cheap; no-op when not dragging).
  [_cropOSC mouseUp];

  if (RoundedSharedOSCGuideBridge().guideStep == 2 && self.isDragging) {
    RoundedSharedOSCGuideBridge().guideStep = 3;
    *forceUpdate = YES;
  }
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
