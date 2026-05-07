/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKDataBlob.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@interface GlowPlugin (AnimatableParamUpdate)
- (void)_glowHandleAnimatableParameterChange:(UInt32)parameterID
                                      atTime:(CMTime)time;
@end

@implementation GlowPlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  KKLogInfo(@"GlowPlugin: initialized");
  self = [super initWithAPIManager:newApiManager];
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES,
    kFxPropertyKey_ChangesOutputSize : @YES,
    kFxPropertyKey_NeedsFullBuffer : @YES
  };

  return YES;
}

- (BOOL)forceShowAllParameters {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return NO;
  BOOL on = NO;
  [paramGetAPI getBoolValue:&on
              fromParameter:kParamForceShow
                     atTime:kCMTimeZero];
  return on;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  [self _glowHandleAnimatableParameterChange:parameterID atTime:time];
  [self multiStageRefreshLaneVisibility];

  // Visibility refresh. Timing is gated to specific paramIDs to avoid the
  // cascade documented in project_published_custom_ui_cascade. Motion blur
  // is unconditional — the named-header chevron/checkbox sync lives inside
  // updateMotionBlurParameterVisibility, so cmd-Z of the checkbox or
  // expanded toggle has to land here for the header to redraw.
  if (parameterID == kParamForceShow || parameterID == kKKParamTimingExpanded)
    [self updateTimingParameterVisibility];
  [self updateMotionBlurParameterVisibility];

  // Generic group headers (Noise, Color) — chevron is a separate custom
  // view that doesn't observe its expanded param; on host undo/redo we
  // have to push the reverted bool back to the header explicitly.
  if (parameterID == kParamNoiseExpanded || parameterID == kParamForceShow)
    [self syncGroupHeaderExpandedForExpandedParamID:kParamNoiseExpanded];
  if (parameterID == kKKParamColorExpanded || parameterID == kParamForceShow)
    [self syncGroupHeaderExpandedForExpandedParamID:kKKParamColorExpanded];

  // Host cmd-Z reverts blob params outside our action scopes; the in-
  // memory snapshots / views don't see the change. Force a re-read + push.
  if (parameterID == kKKParamMultiStageData)
    [KKPlugin multiStageRefreshFromParamForAPI:self.apiManager];
  if (parameterID == kKKParamTimingLoopEnabled)
    [KKPlugin multiStageRefreshLoopFromParamForAPI:self.apiManager];
  if (parameterID == kKKParamGradientData)
    [KKPlugin colorSyncFromParams:self.apiManager];

  switch (parameterID) {
  case kKKParamColorMode:
  case kParamGradientType:
  case kParamForceShow:
  case kKKParamTimingExpanded:
  case kParamNoiseExpanded:
  case kKKParamColorExpanded:
  case kKKParamMotionBlurExpanded:
    [self updateParameterVisibilityAtTime:time];
    break;
  case kParamPreset:
    [self applyPresetAtTime:time];
    break;
  default:
    [self handleLinkedParameterChanged:parameterID atTime:time];
    break;
  }
  return YES;
}

- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kParamNoiseExpanded)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [super classesForCustomParameterID:parameterID];
}

@end

@implementation GlowPlugin (AnimatableParamUpdate)

/// paramID → (lane label, current values) translator. Routes a slider /
/// picker change into the corresponding lane's selected segment via
/// `multiStageUpdateSelectedSegmentForLabel:values:` — replaces the
/// `animatableProperties`-driven `multiStageHandleParameterChanged:` path.
- (void)_glowHandleAnimatableParameterChange:(UInt32)parameterID
                                      atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;

  NSString *label = nil;
  NSArray<NSNumber *> *values = nil;
  switch (parameterID) {
  case kParamRadiusX:
  case kParamRadiusY: {
    label = @"Radius";
    double rx = 0, ry = 0;
    [getAPI getFloatValue:&rx fromParameter:kParamRadiusX atTime:time];
    [getAPI getFloatValue:&ry fromParameter:kParamRadiusY atTime:time];
    values = @[ @(rx), @(ry) ];
    break;
  }
  case kParamIntensity: {
    label = @"Intensity";
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamIntensity atTime:time];
    values = @[ @(v) ];
    break;
  }
  case kParamFalloff: {
    label = @"Falloff";
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamFalloff atTime:time];
    values = @[ @(v) ];
    break;
  }
  case kParamNoise: {
    label = @"Noise";
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamNoise atTime:time];
    values = @[ @(v) ];
    break;
  }
  case kParamNoiseOffset: {
    label = @"N. Offset";
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamNoiseOffset atTime:time];
    values = @[ @(v) ];
    break;
  }
  case kParamPosition: {
    label = @"Position";
    double x = 0, y = 0;
    [getAPI getXValue:&x YValue:&y fromParameter:kParamPosition atTime:time];
    values = @[ @(x), @(y) ];
    break;
  }
  case kKKParamColorSolid: {
    label = @"Color";
    double r = 0, g = 0, b = 0;
    [getAPI getRedValue:&r
             greenValue:&g
              blueValue:&b
          fromParameter:kKKParamColorSolid
                 atTime:time];
    values = @[ @(r), @(g), @(b) ];
    break;
  }
  case kKKParamGradientData: {
    label = @"Gradient";
    NSString *json = KKReadCustomParamString(getAPI, kKKParamGradientData);
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
    values = stops ? KKGradientFlatFromStops(stops) : @[];
    break;
  }
  default:
    return;
  }
  if (label.length && values.count)
    [self multiStageUpdateSelectedSegmentForLabel:label values:values];
}

@end
#pragma clang diagnostic pop
