/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

// Restores a lane's default and drops its keyposes. One undo group, and a
// rejected write restores the whole curve, including native interpolation.
BOOL KFResetParameter(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID);
// A property menu whose first item is Reset Parameter.
NSMenu *KFResetParameterMenu(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID);
