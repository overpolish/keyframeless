/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "MockHost.h"
@import PoseLanes;

// A representative lane table for the package tests: a percent-of-image vector
// lane, a proportional vector lane, a three-component lane, two scalar lanes
// and a pixel vector lane. The shapes, not the names, are what the model has to
// handle, so a plugin's own table is never needed here.
enum {
  KFTestPosition = 1000, KFTestScale = 1001, KFTestRotation = 1002,
  KFTestOpacity = 1003, KFTestBlur = 1004, KFTestAnchor = 1005,
  KFTestPositionCacheToken = 1010, KFTestScaleCacheToken = 1011,
  KFTestRotationCacheToken = 1012, KFTestOpacityCacheToken = 1013,
  KFTestBlurCacheToken = 1014, KFTestAnchorCacheToken = 1015,
  KFTestPositionMatchEnds = 1020, KFTestScaleMatchEnds = 1021,
  KFTestRotationMatchEnds = 1022, KFTestOpacityMatchEnds = 1023,
  KFTestBlurMatchEnds = 1024, KFTestAnchorMatchEnds = 1025,
  KFTestTimingControls = 1031,
  KFTestExplicitCreation = 1040, KFTestScaleProportional = 1041,
  KFTestShowPositionOSC = 1050, KFTestShowScaleOSC = 1051,
  KFTestShowRotationOSC = 1052, KFTestShowAnchorOSC = 1053,
  KFTestHostRefreshToken = 1060
};

KFPropertyLane *KFTestPositionLane(void);
KFPropertyLane *KFTestScaleLane(void);
KFPropertyLane *KFTestRotationLane(void);
KFPropertyLane *KFTestOpacityLane(void);
KFPropertyLane *KFTestBlurLane(void);
KFPropertyLane *KFTestAnchorLane(void);

// Registers the table and everything the package reads back from its host:
// refresh token, explicit-creation toggle and a preference store under a
// throwaway suite. Idempotent, so every suite can call it from `main`.
void KFTestRegisterLanes(void);
// Stands in for the plugin: registers the lane parameters, builds rows from
// the lane table and carries the inspector state the views read.
@interface KFTestEffect : KFEffect
- (BOOL)addParameters;
- (NSView *)createViewForParameterID:(UInt32)parameterID;
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID;
- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error;
@end
