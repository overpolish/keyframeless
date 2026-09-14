/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
static NSString *const kPluginID = @"com.keyframeless.MagicMoveNext";
// MMLinkProperties is retained hidden for saved-effect compatibility; pair IDs now own linking.
// Former Match Out row IDs remain hidden and ignored; the shared match state lives in the data blobs.
// Retired pose/group/timing IDs must not be reused; saved effects can still contain them.
enum { MMTransitionDuration = 1102, MMPositionX = 1300, MMDurationData = 1301, MMPositionAvailableTime = 1302, MMPositionLink = 1303, MMPositionMatch = 1304, MMPositionLegacyMatchOut = 1305, MMPositionEasing = 1306, MMPositionAddedMotion = 1307, MMPositionY = 1308,
       MMScale = 1400, MMScaleDuration = 1401, MMScaleDurationData = 1402, MMScaleAvailableTime = 1403, MMScaleLink = 1404, MMScaleMatch = 1405, MMScaleLegacyMatchOut = 1406, MMScaleEasing = 1407, MMScaleAddedMotion = 1408, MMLinkProperties = 1500, MMCustomControls = 1600, MMCombinedCacheToken = 1601, MMCombinedEasing = 1602, MMExplicitCreation = 1603, MMCombinedAddedMotion = 1604, MMMotionBlur = 1700, MMMotionBlurSamples = 1701, MMMotionBlurShutterAngle = 1702, MMScaleControls = 1800, MMScaleCacheToken = 1801, MMScaleProportional = 1802, MMScaleX = 1803, MMScaleY = 1804, MMOpacityControls = 2000, MMOpacityCacheToken = 2001, MMRotationControls = 2100, MMRotationCacheToken = 2101, MMHostRefreshToken = 2200, MMBlurControls = 2300, MMBlurCacheToken = 2301, MMAnchorControls = 2400, MMAnchorCacheToken = 2401, MMHeaderControls = 2500 };
_Static_assert(MMTransitionDuration >= 1 && MMExplicitCreation <= 9999,
               "FxPlug parameter IDs must be between 1 and 9999");

static const UInt32 MMTimingControls = 1900;

static const int MMMotionBlurDefaultSamples = 16;
static const int MMMotionBlurMinSamples = 2;
static const int MMMotionBlurMaxSamples = 128;
static const int MMMotionBlurDefaultShutterAngle = 180;
static const int MMMotionBlurMinShutterAngle = 0;
static const int MMMotionBlurMaxShutterAngle = 360;
