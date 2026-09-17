/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <FxPlug/FxPlugSDK.h>
@import PluginHost;

FOUNDATION_EXPORT NSSet<Class> *MMClassesForCustomParameter(UInt32 parameterID);

@interface MagicMovePlugin : KFEffect <FxTileableEffect, FxCustomParameterViewHost_v2>
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID;
@end
