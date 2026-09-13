/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

// Host integration for the native custom property lanes. A reset is one undo group.
BOOL MMResetParameter(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID);
NSMenu *MMResetParameterMenu(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID);

// Menu lifecycle: handled actions already refresh inside their undo group;
// cancellation and failed actions still need a host refresh after tracking ends.
void MMPropertyMenuActionScheduled(NSMenu *menu);
void MMPropertyMenuActionFinished(NSMenu *menu, BOOL refreshed);

// Called inside a host action to present already-published cache state.
void MMPropertyMenuSetStateHandler(NSMenu *menu, void (^handler)(void));
// Call after a native parameter callback has refreshed its cached keyposes.
void MMPropertyMenuParametersChanged(id<PROAPIAccessing> manager);
