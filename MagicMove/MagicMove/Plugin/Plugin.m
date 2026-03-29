/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Plugin.h"
#import "Constants.h"
#import "MagicMovePath.h"
#import "ShaderTypes.h"
#import <AppKit/NSView.h>
#import <Foundation/Foundation.h>
#include <FxPlug/FxTypes.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static double mmSmoothstep(double x) { return x * x * (3.0 - 2.0 * x); }
static double mmEaseOutCubic(double x) { return 1.0 - pow(1.0 - x, 3.0); }
static double mmEaseOutSpring(double x) {
  const double c1 = 1.0, c3 = c1 + 1.0;
  return 1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0);
}

static double mmApplyCurveIn(double raw, int curve) {
  switch (curve) {
  case 0:
    return raw;
  case 1:
    return mmSmoothstep(raw);
  case 3:
    return mmEaseOutSpring(raw);
  default:
    return mmEaseOutCubic(raw);
  }
}

static double mmApplyCurveOut(double raw, int curve) {
  switch (curve) {
  case 0:
    return raw;
  case 1:
    return mmSmoothstep(raw);
  case 3:
    return mmEaseOutSpring(raw);
  default:
    return mmSmoothstep(raw);
  }
}

@interface MagicMovePreviewClearTarget : NSObject
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
- (void)clearPreviews:(id)sender;
@end

@implementation MagicMovePreviewClearTarget
- (void)clearPreviews:(id)sender {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxTimingAPI_v4> timingAPI =
      [_apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime now = kCMTimeZero;
  if (timingAPI) {
    CMTime start = kCMTimeZero;
    [timingAPI startTimeForEffect:&start];
    now = start;
  }
  UInt32 previews[] = {kParamPreviewA, kParamPreviewB, kParamPreviewDrift,
                       kParamPreviewExit};
  for (int i = 0; i < 4; i++)
    [paramSetAPI setBoolValue:NO toParameter:previews[i] atTime:now];
  [actionAPI endAction:self];
}
@end

@implementation MagicMovePlugin {
  KKLog *_log;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  [_log info:@"MagicMovePlugin: initWithAPIManager called - plugin is loading"];
  self = [super initWithAPIManager:newApiManager];
  if (self != nil) {
    [_log info:@"MagicMovePlugin: Successfully initialized"];
  }
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES
  };

  return YES;
}

- (BOOL)addPointSectionWithName:(NSString *)name
                    separatorID:(UInt32)separatorID
                        pointID:(UInt32)pointID
                     rotationID:(UInt32)rotationID
                    rotationXID:(UInt32)rotationXID
                    rotationYID:(UInt32)rotationYID
                       scaleXID:(UInt32)scaleXID
                       scaleYID:(UInt32)scaleYID
                      opacityID:(UInt32)opacityID
                      previewID:(UInt32)previewID
                       defaultX:(double)defaultX
                       defaultY:(double)defaultY
                  defaultHidden:(BOOL)defaultHidden
                        withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                          error:(NSError **)error {
  FxParameterFlags flags =
      defaultHidden ? kFxParameterFlag_HIDDEN : kFxParameterFlag_DEFAULT;

  NSImage *icon = [NSImage imageWithSystemSymbolName:@"circle.circle"
                            accessibilityDescription:nil];
  if (![self addSeparatorParameterWithText:name
                                      icon:icon
                               parameterID:separatorID
                                   withAPI:paramAPI
                                     error:error])
    return NO;

  if (previewID != 0) {
    if (![paramAPI addToggleButtonWithName:@"Preview"
                               parameterID:previewID
                              defaultValue:NO
                            parameterFlags:flags])
      return NO;
  }

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:pointID
                                  defaultX:defaultX
                                  defaultY:defaultY
                            parameterFlags:flags])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation"
                            parameterID:rotationID
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:flags])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation X"
                            parameterID:rotationXID
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:flags])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation Y"
                            parameterID:rotationYID
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:flags])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale X"
                              parameterID:scaleXID
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:flags])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale Y"
                              parameterID:scaleYID
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:flags])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Opacity"
                              parameterID:opacityID
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:flags])
    return NO;

  return YES;
}

- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  if (paramAPI == nil) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:FxPlugErrorDomain
                                   code:kFxError_APIUnavailable
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to obtain an FxPlug API Object"
                               }];
    }
    return NO;
  }

  if (![self addUpdateBannerParameterWithAPI:paramAPI error:error])
    return NO;

  if (![paramAPI
          addToggleButtonWithName:@"Force Show Alerts"
                      parameterID:kParamForceShowAlerts
                     defaultValue:NO
                   parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                  kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD])
    return NO;

  if (![self addInfoParameterWithText:
                 @"Create a Compound Clip before applying to avoid clipping"
                                 icon:[NSImage imageWithSystemSymbolName:
                                                   @"exclamationmark.triangle"
                                                accessibilityDescription:nil]
                          parameterID:kParamInfoCompound
                              withAPI:paramAPI
                                error:error])
    return NO;

  if (![self addInfoParameterWithText:@"Preview mode is active"
                                 icon:[NSImage
                                          imageWithSystemSymbolName:@"eye.fill"
                                           accessibilityDescription:nil]
                          parameterID:kParamPreviewWarning
                              withAPI:paramAPI
                                error:error])
    return NO;

  // Hide alerts initially — updateParameterVisibilityAtTime: will show them
  // when appropriate.
  id<FxParameterSettingAPI_v5> initSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (initSetAPI) {
    FxParameterFlags hiddenAlert =
        kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
        kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_DISABLED |
        kFxParameterFlag_HIDDEN;
    [initSetAPI setParameterFlags:hiddenAlert toParameter:kParamPreviewWarning];
  }

  if (![self addAnimationParametersWithAPI:paramAPI error:error])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Rotate with Motion"
                             parameterID:kParamRotateWithMotion
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![self addPointSectionWithName:@"Point A"
                         separatorID:kParamGroupPointA
                             pointID:kParamPointA
                          rotationID:kParamRotationA
                         rotationXID:kParamRotationXA
                         rotationYID:kParamRotationYA
                            scaleXID:kParamScaleA
                            scaleYID:kParamScaleYA
                           opacityID:kParamOpacityA
                           previewID:kParamPreviewA
                            defaultX:0.5
                            defaultY:0.5
                       defaultHidden:YES
                             withAPI:paramAPI
                               error:error])
    return NO;

  if (![self addPointSectionWithName:@"Point B"
                         separatorID:kParamGroupPointB
                             pointID:kParamPointB
                          rotationID:kParamRotationB
                         rotationXID:kParamRotationXB
                         rotationYID:kParamRotationYB
                            scaleXID:kParamScaleB
                            scaleYID:kParamScaleYB
                           opacityID:kParamOpacityB
                           previewID:kParamPreviewB
                            defaultX:0.5
                            defaultY:0.5
                       defaultHidden:NO
                             withAPI:paramAPI
                               error:error])
    return NO;

  NSImage *circleIcon = [NSImage imageWithSystemSymbolName:@"circle.circle"
                                  accessibilityDescription:nil];

  if (![self addSeparatorParameterWithText:@"Drift"
                                      icon:circleIcon
                               parameterID:kParamGroupDrift
                                   withAPI:paramAPI
                                     error:error])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Enable"
                             parameterID:kParamDrift
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Preview"
                             parameterID:kParamPreviewDrift
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:kParamDriftPoint
                                  defaultX:0.5
                                  defaultY:0.5
                            parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation"
                            parameterID:kParamDriftRotation
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation X"
                            parameterID:kParamDriftRotationX
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation Y"
                            parameterID:kParamDriftRotationY
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale X"
                              parameterID:kParamDriftScale
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale Y"
                              parameterID:kParamDriftScaleY
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Opacity"
                              parameterID:kParamDriftOpacity
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![self addSeparatorParameterWithText:@"Exit"
                                      icon:circleIcon
                               parameterID:kParamGroupExit
                                   withAPI:paramAPI
                                     error:error])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Enable"
                             parameterID:kParamExit
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Preview"
                             parameterID:kParamPreviewExit
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:kParamExitPoint
                                  defaultX:0.5
                                  defaultY:0.5
                            parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation"
                            parameterID:kParamExitRotation
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation X"
                            parameterID:kParamExitRotationX
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation Y"
                            parameterID:kParamExitRotationY
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale X"
                              parameterID:kParamExitScale
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale Y"
                              parameterID:kParamExitScaleY
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Opacity"
                              parameterID:kParamExitOpacity
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  UInt32 pathIDs[] = {kParamPathAB, kParamPathBDrift, kParamPathDriftExit,
                      kParamPathBExit};
  NSString *pathNames[] = {@"PathAB", @"PathBDrift", @"PathDriftExit",
                           @"PathBExit"};
  for (int i = 0; i < 4; i++) {
    if (![paramAPI addStringParameterWithName:pathNames[i]
                                  parameterID:pathIDs[i]
                                 defaultValue:@""
                               parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;
  }

  return YES;
}

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL animIn = NO, animOut = NO, driftOn = NO, exitOn = NO;
  [paramGetAPI getBoolValue:&animIn
              fromParameter:kKKParamAnimateIn
                     atTime:time];
  [paramGetAPI getBoolValue:&animOut
              fromParameter:kKKParamAnimateOut
                     atTime:time];
  [paramGetAPI getBoolValue:&driftOn fromParameter:kParamDrift atTime:time];
  [paramGetAPI getBoolValue:&exitOn fromParameter:kParamExit atTime:time];

  BOOL previewA = NO, previewB = NO, previewDrift = NO, previewExit = NO;
  [paramGetAPI getBoolValue:&previewA fromParameter:kParamPreviewA atTime:time];
  [paramGetAPI getBoolValue:&previewB fromParameter:kParamPreviewB atTime:time];
  [paramGetAPI getBoolValue:&previewDrift
              fromParameter:kParamPreviewDrift
                     atTime:time];
  [paramGetAPI getBoolValue:&previewExit
              fromParameter:kParamPreviewExit
                     atTime:time];
  BOOL forceAlerts = NO;
  [paramGetAPI getBoolValue:&forceAlerts
              fromParameter:kParamForceShowAlerts
                     atTime:time];

  FxParameterFlags alertBase =
      kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
      kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_DISABLED;

  BOOL anyPreview = previewA || previewB || previewDrift || previewExit;
  [paramSetAPI setParameterFlags:(anyPreview || forceAlerts)
                                     ? alertBase
                                     : (alertBase | kFxParameterFlag_HIDDEN)
                     toParameter:kParamPreviewWarning];

  BOOL showA = animIn || (animOut && !exitOn);
  BOOL showExit = exitOn && animOut;

  FxParameterFlags flagA =
      showA ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  FxParameterFlags flagDrift =
      driftOn ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  FxParameterFlags flagExit =
      showExit ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;

  // Point A: separator always visible, parameters hidden when not needed
  [paramSetAPI setParameterFlags:flagA toParameter:kParamPreviewA];
  [paramSetAPI setParameterFlags:flagA toParameter:kParamPointA];
  [paramSetAPI setParameterFlags:flagA toParameter:kParamRotationA];
  [paramSetAPI setParameterFlags:flagA toParameter:kParamRotationXA];
  [paramSetAPI setParameterFlags:flagA toParameter:kParamRotationYA];
  [paramSetAPI setParameterFlags:flagA toParameter:kParamScaleA];
  [paramSetAPI setParameterFlags:flagA toParameter:kParamScaleYA];
  [paramSetAPI setParameterFlags:flagA toParameter:kParamOpacityA];

  // Drift sub-parameters (keep Enable toggle visible)
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamPreviewDrift];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftPoint];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftRotation];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftRotationX];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftRotationY];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftScale];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftScaleY];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftOpacity];

  // Exit sub-parameters (keep Enable toggle visible)
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamPreviewExit];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitPoint];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitRotation];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitRotationX];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitRotationY];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitScale];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitScaleY];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitOpacity];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamPreviewWarning) {
    KKAlertView *alert =
        [[KKAlertView alloc] initWithText:@"Preview mode is active"
                                    color:[NSColor warning]];
    alert.icon = [NSImage imageWithSystemSymbolName:@"eye.fill"
                           accessibilityDescription:nil];

    MagicMovePreviewClearTarget *target =
        [[MagicMovePreviewClearTarget alloc] init];
    target.apiManager = self.apiManager;
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear"
                                            target:target
                                            action:@selector(clearPreviews:)];
    clearBtn.controlSize = NSControlSizeSmall;
    clearBtn.bezelStyle = NSBezelStyleAccessoryBarAction;
    clearBtn.contentTintColor = [NSColor warning];
    // Keep target alive as long as the button exists
    objc_setAssociatedObject(clearBtn, "clearTarget", target,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    alert.accessoryView = clearBtn;
    return alert;
  }
  // KKPlugin implements this via FxCustomParameterViewHost_v2 in a private
  // category, so call through to it explicitly.
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  if (parameterID == kParamPreviewA || parameterID == kParamPreviewB ||
      parameterID == kParamPreviewDrift || parameterID == kParamPreviewExit) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL isOn = NO;
    [paramGetAPI getBoolValue:&isOn fromParameter:parameterID atTime:time];
    if (isOn) {
      const UInt32 allPreviews[] = {kParamPreviewA, kParamPreviewB,
                                    kParamPreviewDrift, kParamPreviewExit};
      for (int i = 0; i < 4; i++) {
        if (allPreviews[i] != parameterID)
          [paramSetAPI setBoolValue:NO toParameter:allPreviews[i] atTime:time];
      }
    }
  }
  [self updateParameterVisibilityAtTime:time];
  return YES;
}

- (MagicMovePath *)readPath:(UInt32)paramID
                    withAPI:(id<FxParameterRetrievalAPI_v6>)api {
  NSString *str = nil;
  [api getStringParameterValue:&str fromParameter:paramID];
  if (str.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:str options:0];
    if (data)
      return [MagicMovePath pathWithData:data];
  }
  return [[MagicMovePath alloc] init];
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  [self updateParameterVisibilityAtTime:renderTime];

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI == nil) {
    if (error != NULL) {
      *error =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_ThirdPartyDeveloperStart + 20
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Unable to retrieve FxParameterRetrievalAPI_v6"
                          }];
    }
    return NO;
  }
  BOOL previewA = NO, previewB = NO, previewDrift = NO, previewExit = NO;
  [paramGetAPI getBoolValue:&previewA
              fromParameter:kParamPreviewA
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&previewB
              fromParameter:kParamPreviewB
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&previewDrift
              fromParameter:kParamPreviewDrift
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&previewExit
              fromParameter:kParamPreviewExit
                     atTime:renderTime];

  UInt32 previewPointID = 0, previewRotID = 0, previewRotXID = 0,
         previewRotYID = 0, previewScaleXID = 0, previewScaleYID = 0,
         previewOpacityID = 0;
  if (previewA) {
    previewPointID = kParamPointA;
    previewRotID = kParamRotationA;
    previewRotXID = kParamRotationXA;
    previewRotYID = kParamRotationYA;
    previewScaleXID = kParamScaleA;
    previewScaleYID = kParamScaleYA;
    previewOpacityID = kParamOpacityA;
  } else if (previewB) {
    previewPointID = kParamPointB;
    previewRotID = kParamRotationB;
    previewRotXID = kParamRotationXB;
    previewRotYID = kParamRotationYB;
    previewScaleXID = kParamScaleB;
    previewScaleYID = kParamScaleYB;
    previewOpacityID = kParamOpacityB;
  } else if (previewDrift) {
    previewPointID = kParamDriftPoint;
    previewRotID = kParamDriftRotation;
    previewRotXID = kParamDriftRotationX;
    previewRotYID = kParamDriftRotationY;
    previewScaleXID = kParamDriftScale;
    previewScaleYID = kParamDriftScaleY;
    previewOpacityID = kParamDriftOpacity;
  } else if (previewExit) {
    previewPointID = kParamExitPoint;
    previewRotID = kParamExitRotation;
    previewRotXID = kParamExitRotationX;
    previewRotYID = kParamExitRotationY;
    previewScaleXID = kParamExitScale;
    previewScaleYID = kParamExitScaleY;
    previewOpacityID = kParamExitOpacity;
  }

  if (previewPointID != 0) {
    double px = 0.5, py = 0.5;
    [paramGetAPI getXValue:&px
                    YValue:&py
             fromParameter:previewPointID
                    atTime:renderTime];
    double rot = 0, rotX = 0, rotY = 0, scaleX = 1, scaleY = 1, opacity = 1;
    [paramGetAPI getFloatValue:&rot
                 fromParameter:previewRotID
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&rotX
                 fromParameter:previewRotXID
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&rotY
                 fromParameter:previewRotYID
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&scaleX
                 fromParameter:previewScaleXID
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&scaleY
                 fromParameter:previewScaleYID
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&opacity
                 fromParameter:previewOpacityID
                        atTime:renderTime];

    MagicMoveParams params;
    params.translate = (simd_float2){(float)(px - 0.5), (float)(py - 0.5)};
    params.rotation = (float)rot;
    params.rotationX = (float)rotX;
    params.rotationY = (float)rotY;
    params.scaleX = (float)scaleX;
    params.scaleY = (float)scaleY;
    params.opacity = (float)opacity;

    *pluginState = [NSData dataWithBytes:&params length:sizeof(params)];
    return (*pluginState != nil);
  }

  double t = [self animationFactorAtTime:renderTime];

  double posAx = 0.5, posAy = 0.5, posBx = 0.5, posBy = 0.5;
  [paramGetAPI getXValue:&posAx
                  YValue:&posAy
           fromParameter:kParamPointA
                  atTime:renderTime];
  [paramGetAPI getXValue:&posBx
                  YValue:&posBy
           fromParameter:kParamPointB
                  atTime:renderTime];

  double rotA = 0, rotB = 0, rotXA = 0, rotXB = 0, rotYA = 0, rotYB = 0;
  double scaleXA = 1, scaleXB = 1, scaleYA = 1, scaleYB = 1;
  double opacityA = 1, opacityB = 1;
  [paramGetAPI getFloatValue:&rotA
               fromParameter:kParamRotationA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&rotB
               fromParameter:kParamRotationB
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&rotXA
               fromParameter:kParamRotationXA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&rotXB
               fromParameter:kParamRotationXB
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&rotYA
               fromParameter:kParamRotationYA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&rotYB
               fromParameter:kParamRotationYB
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&scaleXA
               fromParameter:kParamScaleA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&scaleXB
               fromParameter:kParamScaleB
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&scaleYA
               fromParameter:kParamScaleYA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&scaleYB
               fromParameter:kParamScaleYB
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&opacityA
               fromParameter:kParamOpacityA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&opacityB
               fromParameter:kParamOpacityB
                      atTime:renderTime];

  BOOL driftEnabled = NO;
  [paramGetAPI getBoolValue:&driftEnabled
              fromParameter:kParamDrift
                     atTime:renderTime];

  double driftX = 0.5, driftY = 0.5, driftRot = 0, driftRotX = 0, driftRotY = 0,
         driftScaleX = 1, driftScaleY = 1, driftOpacity = 1;
  if (driftEnabled) {
    [paramGetAPI getXValue:&driftX
                    YValue:&driftY
             fromParameter:kParamDriftPoint
                    atTime:renderTime];
    [paramGetAPI getFloatValue:&driftRot
                 fromParameter:kParamDriftRotation
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&driftRotX
                 fromParameter:kParamDriftRotationX
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&driftRotY
                 fromParameter:kParamDriftRotationY
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&driftScaleX
                 fromParameter:kParamDriftScale
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&driftScaleY
                 fromParameter:kParamDriftScaleY
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&driftOpacity
                 fromParameter:kParamDriftOpacity
                        atTime:renderTime];
  }

  BOOL exitToggle = NO;
  [paramGetAPI getBoolValue:&exitToggle
              fromParameter:kParamExit
                     atTime:renderTime];
  BOOL animateOut = NO;
  [paramGetAPI getBoolValue:&animateOut
              fromParameter:kKKParamAnimateOut
                     atTime:renderTime];
  BOOL exitEnabled = exitToggle && animateOut;

  double exitX = 0.5, exitY = 0.5, exitRot = 0, exitRotX = 0, exitRotY = 0,
         exitScaleX = 1, exitScaleY = 1, exitOpacity = 1;
  if (exitEnabled) {
    [paramGetAPI getXValue:&exitX
                    YValue:&exitY
             fromParameter:kParamExitPoint
                    atTime:renderTime];
    [paramGetAPI getFloatValue:&exitRot
                 fromParameter:kParamExitRotation
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&exitRotX
                 fromParameter:kParamExitRotationX
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&exitRotY
                 fromParameter:kParamExitRotationY
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&exitScaleX
                 fromParameter:kParamExitScale
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&exitScaleY
                 fromParameter:kParamExitScaleY
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&exitOpacity
                 fromParameter:kParamExitOpacity
                        atTime:renderTime];
  }

  double targetX = posBx, targetY = posBy;
  double targetRot = rotB, targetRotX = rotXB, targetRotY = rotYB;
  double targetScaleX = scaleXB, targetScaleY = scaleYB,
         targetOpacity = opacityB;

  id<FxTimingAPI_v4> timingAPI = nil;
  double startSec = 0, durSec = 0, nowSec = 0;
  if (driftEnabled || exitEnabled) {
    timingAPI = [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
    [timingAPI startTimeForEffect:&effectStart];
    [timingAPI durationTimeForEffect:&effectDuration];
    startSec = CMTimeGetSeconds(effectStart);
    durSec = CMTimeGetSeconds(effectDuration);
    nowSec = CMTimeGetSeconds(renderTime);
  }

  double animDur = 0.5;
  if (exitEnabled)
    [paramGetAPI getFloatValue:&animDur
                 fromParameter:kKKParamAnimationDuration
                        atTime:renderTime];

  if (driftEnabled) {
    double driftDur = exitEnabled ? durSec - animDur : durSec;
    double d = (driftDur > 0) ? (nowSec - startSec) / driftDur : 1.0;
    d = MAX(0.0, MIN(1.0, d));
    MagicMovePath *pathBDrift = [self readPath:kParamPathBDrift
                                       withAPI:paramGetAPI];
    simd_float2 driftPos =
        [pathBDrift positionAtT:(float)d
                          start:(simd_float2){(float)posBx, (float)posBy}
                            end:(simd_float2){(float)driftX, (float)driftY}];
    targetX = driftPos.x;
    targetY = driftPos.y;
    targetRot = (1 - d) * rotB + d * driftRot;
    targetRotX = (1 - d) * rotXB + d * driftRotX;
    targetRotY = (1 - d) * rotYB + d * driftRotY;
    targetScaleX = (1 - d) * scaleXB + d * driftScaleX;
    targetScaleY = (1 - d) * scaleYB + d * driftScaleY;
    targetOpacity = (1 - d) * opacityB + d * driftOpacity;
  }

  MagicMovePath *pathAB = [self readPath:kParamPathAB withAPI:paramGetAPI];

  MagicMoveParams params;
  if (exitEnabled) {
    int curve = 2;
    [paramGetAPI getIntValue:&curve
               fromParameter:kKKParamAnimationInterpolation
                      atTime:renderTime];

    // Compute in-factor only (exit replaces animate-out for position)
    double tIn = 1.0;
    BOOL animateIn = NO;
    [paramGetAPI getBoolValue:&animateIn
                fromParameter:kKKParamAnimateIn
                       atTime:renderTime];
    if (animateIn) {
      double rawIn = MAX(0.0, MIN(1.0, (nowSec - startSec) / animDur));
      tIn = mmApplyCurveIn(rawIn, curve);
    }

    // Exit factor: 0 before out-window, 1 at effect end
    double effectEndSec = startSec + durSec;
    double rawE =
        MAX(0.0, MIN(1.0, (nowSec - (effectEndSec - animDur)) / animDur));
    double e = mmApplyCurveOut(rawE, curve);

    // Blend target toward exit along path
    MagicMovePath *exitPath =
        [self readPath:(driftEnabled ? kParamPathDriftExit : kParamPathBExit)
               withAPI:paramGetAPI];
    simd_float2 effPos =
        [exitPath positionAtT:(float)e
                        start:(simd_float2){(float)targetX, (float)targetY}
                          end:(simd_float2){(float)exitX, (float)exitY}];
    double effX = effPos.x;
    double effY = effPos.y;
    double effRot = (1 - e) * targetRot + e * exitRot;
    double effRotX = (1 - e) * targetRotX + e * exitRotX;
    double effRotY = (1 - e) * targetRotY + e * exitRotY;
    double effScaleX = (1 - e) * targetScaleX + e * exitScaleX;
    double effScaleY = (1 - e) * targetScaleY + e * exitScaleY;
    double effOpacity = (1 - e) * targetOpacity + e * exitOpacity;

    simd_float2 startPos = {(float)posAx, (float)posAy};
    simd_float2 endPos = {(float)effX, (float)effY};
    simd_float2 pos = [pathAB positionAtT:(float)tIn start:startPos end:endPos];
    params.translate = (simd_float2){pos.x - 0.5f, pos.y - 0.5f};
    params.rotation = (float)((1 - tIn) * rotA + tIn * effRot);
    params.rotationX = (float)((1 - tIn) * rotXA + tIn * effRotX);
    params.rotationY = (float)((1 - tIn) * rotYA + tIn * effRotY);
    params.scaleX = (float)((1 - tIn) * scaleXA + tIn * effScaleX);
    params.scaleY = (float)((1 - tIn) * scaleYA + tIn * effScaleY);
    params.opacity = (float)((1 - tIn) * opacityA + tIn * effOpacity);
  } else {
    simd_float2 startPos = {(float)posAx, (float)posAy};
    simd_float2 endPos = {(float)targetX, (float)targetY};
    simd_float2 pos = [pathAB positionAtT:(float)t start:startPos end:endPos];
    params.translate = (simd_float2){pos.x - 0.5f, pos.y - 0.5f};
    params.rotation = (float)((1 - t) * rotA + t * targetRot);
    params.rotationX = (float)((1 - t) * rotXA + t * targetRotX);
    params.rotationY = (float)((1 - t) * rotYA + t * targetRotY);
    params.scaleX = (float)((1 - t) * scaleXA + t * targetScaleX);
    params.scaleY = (float)((1 - t) * scaleYA + t * targetScaleY);
    params.opacity = (float)((1 - t) * opacityA + t * targetOpacity);
  }

  BOOL rotateWithMotion = NO;
  [paramGetAPI getBoolValue:&rotateWithMotion
              fromParameter:kParamRotateWithMotion
                     atTime:renderTime];

  if (rotateWithMotion) {
    double curX = (double)params.translate.x;
    double window = 1.0 / 12.0;
    CMTime tPrev =
        CMTimeSubtract(renderTime, CMTimeMakeWithSeconds(window, 600));
    double prevSec = CMTimeGetSeconds(tPrev);
    double tgtX = posBx;
    if (driftEnabled) {
      double driftDurP = exitEnabled ? durSec - animDur : durSec;
      double dP = (driftDurP > 0) ? (prevSec - startSec) / driftDurP : 1.0;
      dP = MAX(0.0, MIN(1.0, dP));
      tgtX = (1 - dP) * posBx + dP * driftX;
    }
    double prevX;
    if (exitEnabled) {
      int curve = 2;
      [paramGetAPI getIntValue:&curve
                 fromParameter:kKKParamAnimationInterpolation
                        atTime:renderTime];
      double tPIn = 1.0;
      BOOL animateIn = NO;
      [paramGetAPI getBoolValue:&animateIn
                  fromParameter:kKKParamAnimateIn
                         atTime:renderTime];
      if (animateIn) {
        double rawIn = MAX(0.0, MIN(1.0, (prevSec - startSec) / animDur));
        tPIn = mmApplyCurveIn(rawIn, curve);
      }
      double effectEndSec = startSec + durSec;
      double rawE =
          MAX(0.0, MIN(1.0, (prevSec - (effectEndSec - animDur)) / animDur));
      double eP = mmApplyCurveOut(rawE, curve);
      double effX = (1 - eP) * tgtX + eP * exitX;
      prevX = (1 - tPIn) * posAx + tPIn * effX - 0.5;
    } else {
      double tP = [self animationFactorAtTime:tPrev];
      prevX = (1 - tP) * posAx + tP * tgtX - 0.5;
    }
    double vx = (curX - prevX) / window;
    params.rotation -= (float)(vx * 5.0 * (M_PI / 180.0));
  }

  *pluginState = [NSData dataWithBytes:&params length:sizeof(params)];
  return (*pluginState != nil);
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(nonnull FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError *_Nullable *)outError {
  if (sourceImages.count < 1) {
    [_log error:@"No inputImages list"];
    return NO;
  }

  *destinationImageRect = sourceImages[0].imagePixelBounds;
  return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError {
  *sourceTileRect = destinationTileRect;
  return YES;
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface) {
    if (outError != NULL) {
      *outError =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_InvalidParameter
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Invalid plugin state received from host"
                          }];
    }

    return NO;
  }

  MagicMoveParams params;
  [pluginState getBytes:&params length:sizeof(params)];

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];

  if (!pipelineState)
    return NO;

  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       [encoder setRenderPipelineState:
                                                    pipelineState];
                                       [encoder
                                           setFragmentTexture:inputTextures[0]
                                                      atIndex:
                                                          KKTextureIndex_InputImage];
                                       [encoder
                                           setFragmentBytes:&params
                                                     length:sizeof(params)
                                                    atIndex:
                                                        FragmentIndex_Params];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
