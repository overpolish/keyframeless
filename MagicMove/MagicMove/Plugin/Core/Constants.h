/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
static NSString *const kPluginID = @"com.keyframeless.MagicMoveNext";
// MMLinkProperties is retained hidden for saved-effect compatibility; pair IDs now own linking.
// Former Match Out row IDs remain hidden and ignored; the shared match state lives in the data blobs.
// Earlier prototype pose/group/timing IDs are retired, not repurposed.
enum { MMTransitionDuration = 1102, MMPositionX = 1300, MMDurationData = 1301, MMPositionAvailableTime = 1302, MMPositionLink = 1303, MMPositionMatch = 1304, MMPositionLegacyMatchOut = 1305, MMPositionEasing = 1306, MMPositionAddedMotion = 1307,
       MMScale = 1400, MMScaleDuration = 1401, MMScaleDurationData = 1402, MMScaleAvailableTime = 1403, MMScaleLink = 1404, MMScaleMatch = 1405, MMScaleLegacyMatchOut = 1406, MMScaleEasing = 1407, MMScaleAddedMotion = 1408, MMLinkProperties = 1500, MMCustomControls = 1600, MMCombinedCacheToken = 1601, MMCombinedEasing = 1602, MMExplicitCreation = 1603, MMCombinedAddedMotion = 1604, MMMotionBlur = 1700 };
_Static_assert(MMTransitionDuration >= 1 && MMExplicitCreation <= 9999,
               "FxPlug parameter IDs must be between 1 and 9999");
