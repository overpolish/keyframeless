/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
static NSString *const kPluginID = @"com.keyframeless.MagicMoveNext";
// Every keyframed property is one custom parameter holding an MMPose. Its
// transient cache token carries the inspector snapshot identity, and its
// Match In/Out toggle is lane-wide rather than part of the pose payload. The
// remaining parameters are custom inspector views, hidden settings and the
// saved scratch value that asks the host to repaint.
enum { MMPositionControls = 1000, MMScaleControls = 1001, MMRotationControls = 1002,
       MMOpacityControls = 1003, MMBlurControls = 1004, MMAnchorControls = 1005,
       MMPositionCacheToken = 1010, MMScaleCacheToken = 1011, MMRotationCacheToken = 1012,
       MMOpacityCacheToken = 1013, MMBlurCacheToken = 1014, MMAnchorCacheToken = 1015,
       MMPositionMatchEnds = 1020, MMScaleMatchEnds = 1021, MMRotationMatchEnds = 1022,
       MMOpacityMatchEnds = 1023, MMBlurMatchEnds = 1024, MMAnchorMatchEnds = 1025,
       MMHeaderControls = 1030, MMTimingControls = 1031,
       MMExplicitCreation = 1040, MMScaleProportional = 1041,
       MMMotionBlur = 1042, MMMotionBlurSamples = 1043, MMMotionBlurShutterAngle = 1044,
       // On-screen control visibility: Position owns the box outline, Scale the
       // handles, Rotation the three rings and Anchor the pivot square.
       MMShowPositionOSC = 1050, MMShowScaleOSC = 1051, MMShowRotationOSC = 1052, MMShowAnchorOSC = 1053,
       MMHostRefreshToken = 1060 };
_Static_assert(MMPositionControls >= 1 && MMHostRefreshToken <= 9999,
               "FxPlug parameter IDs must be between 1 and 9999");

static const int MMMotionBlurDefaultSamples = 16;
static const int MMMotionBlurMinSamples = 2;
static const int MMMotionBlurMaxSamples = 128;
static const int MMMotionBlurDefaultShutterAngle = 180;
static const int MMMotionBlurMinShutterAngle = 0;
static const int MMMotionBlurMaxShutterAngle = 360;
