/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

// A context menu that can run host work: it leaves AppKit's tracking loop
// before opening an action, routes Command-Z to the host's own history while
// it is open, and asks for a repaint when an action was cancelled or failed.
NSMenu *KFCreatePropertyMenu(id<PROAPIAccessing> manager, NSView *sender);

// Menu lifecycle: handled actions already refresh inside their undo group;
// cancellation and failed actions still need a host refresh after tracking ends.
void KFPropertyMenuActionScheduled(NSMenu *menu);
void KFPropertyMenuActionFinished(NSMenu *menu, BOOL refreshed);

// Called inside a host action to present already-published cache state.
void KFPropertyMenuSetStateHandler(NSMenu *menu, void (^handler)(void));
// Call after a native parameter callback has refreshed its cached values.
void KFPropertyMenuParametersChanged(id<PROAPIAccessing> manager);
