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
      radiusFromBlobAtFraction(self.apiManager, [self fractionAtTime:time]);
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
  if (activePart == 0)
    return;

  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (![self getCanvasTopRight:&topRight bottomLeft:&bottomLeft])
    return;

  float canvasImageWidth = topRight.x - bottomLeft.x;
  float canvasImageHeight = topRight.y - bottomLeft.y;
  float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));
  BOOL isFlippedX = canvasImageWidth < 0;
  BOOL isFlippedY = canvasImageHeight < 0;

  double dx = positionX - topRight.x;
  double dy = positionY - topRight.y;
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
  KKLogInfo(@"[OSCGuide] mouseDragged canvas=(%.1f,%.1f) topRight=(%.1f,%.1f) "
            @"mouseDist=%.1f newRadius=%.1f",
            positionX, positionY, topRight.x, topRight.y, mouseDist, newRadius);
  _dragCurrentRadius = newRadius;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];

  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    [actionAPI endAction:self];
    return;
  }

  NSString *json = KKReadCustomParamString(getAPI, kKKParamTimelineData);
  KKTimeline *tl =
      json.length ? [KKTimeline timelineFromJSON:json] : [KKTimeline timeline];

  KKLane *radiusLane = nil;
  for (KKLane *lane in tl.lanes) {
    if ([lane.label isEqualToString:@"Radius"]) {
      radiusLane = lane;
      break;
    }
  }
  if (!radiusLane) {
    radiusLane = [KKLane laneWithLabel:@"Radius"];
    // A value edit must not opt the property into the sequencer; animatable
    // is dropdown-only. enabled == animatable.
    radiusLane.enabled = NO;
    NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    [lanes addObject:radiusLane];
    tl.lanes = lanes;
  }

  KKKeyPose *kp = [KKKeyPose keyposeAtTime:0.0 values:@[ @(newRadius) ]];
  radiusLane.keyposes = @[ kp ];

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
