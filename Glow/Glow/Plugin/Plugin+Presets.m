/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

typedef struct {
  double radiusX, radiusY;
  double intensity, falloff;
  double positionX, positionY;
  double threshold;
  double noise, noiseOffset, noiseSpeed;
  double colorR, colorG, colorB;
  int colorMode;
  int gradientType;
} GlowPresetValues;

static const GlowPresetValues kPresets[] = {
    [GlowPresetSoftGlow] =
        {
            .radiusX = 100,
            .radiusY = 100,
            .intensity = 1.0,
            .falloff = 0.0,
            .positionX = 0.5,
            .positionY = 0.5,
            .noise = 0,
            .noiseOffset = 0,
            .noiseSpeed = 0,
            .colorR = 1,
            .colorG = 1,
            .colorB = 1,
            .colorMode = 0, // Dynamic (first in modes array)
        },
    [GlowPresetShadow] =
        {
            .radiusX = 20,
            .radiusY = 20,
            .intensity = 0.5,
            .falloff = 0.5,
            .positionX = 0.50,
            .positionY = 0.44,
            .noise = 0,
            .noiseOffset = 0,
            .noiseSpeed = 0,
            .colorR = 0,
            .colorG = 0,
            .colorB = 0,
            .colorMode = 1, // Solid (second in modes array)
        },
    [GlowPresetFire] =
        {
            .radiusX = 100,
            .radiusY = 100,
            .intensity = 1.0,
            .falloff = 0.0,
            .positionX = 0.5,
            .positionY = 0.5,
            .noise = 2.0,
            .noiseOffset = 0.3,
            .noiseSpeed = 1.0,
            .colorR = 1.0,
            .colorG = 0.4,
            .colorB = 0.0,
            .colorMode = 1, // Solid (second in modes array)
        },
};

@implementation GlowPlugin (Presets)

- (void)applyPresetAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!getAPI || !setAPI || !actAPI)
    return;

  int presetIdx = 0;
  [getAPI getIntValue:&presetIdx fromParameter:kParamPreset atTime:time];
  if (presetIdx < 0 ||
      presetIdx >= (int)(sizeof(kPresets) / sizeof(kPresets[0])))
    return;

  GlowPresetValues p = kPresets[presetIdx];

  [actAPI startAction:self];
  [setAPI setFloatValue:p.radiusX toParameter:kParamRadiusX atTime:time];
  [setAPI setFloatValue:p.radiusY toParameter:kParamRadiusY atTime:time];
  [setAPI setFloatValue:p.intensity toParameter:kParamIntensity atTime:time];
  [setAPI setFloatValue:p.falloff toParameter:kParamFalloff atTime:time];
  [setAPI setFloatValue:p.threshold toParameter:kParamThreshold atTime:time];
  [setAPI setXValue:p.positionX
             YValue:p.positionY
        toParameter:kParamPosition
             atTime:time];
  [setAPI setFloatValue:p.noise toParameter:kParamNoise atTime:time];
  [setAPI setFloatValue:p.noiseOffset
            toParameter:kParamNoiseOffset
                 atTime:time];
  [setAPI setFloatValue:p.noiseSpeed toParameter:kParamNoiseSpeed atTime:time];
  if (p.colorMode == 1) { // Solid (index 1 in modes array)
    [setAPI setRedValue:p.colorR
             greenValue:p.colorG
              blueValue:p.colorB
            toParameter:kKKParamColorSolid
                 atTime:time];
  }
  [setAPI setIntValue:p.colorMode toParameter:kKKParamColorMode atTime:time];
  [setAPI setIntValue:p.gradientType
          toParameter:kParamGradientType
               atTime:time];
  [actAPI endAction:self];

  [self updateParameterVisibilityAtTime:time];
}

@end
