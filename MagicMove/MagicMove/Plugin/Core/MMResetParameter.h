/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

// Host integration for the native custom property lanes. A reset is one undo group.
BOOL MMResetParameter(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID);
NSMenu *MMCreatePropertyMenu(id<PROAPIAccessing> manager, NSView *sender);
NSMenu *MMResetParameterMenu(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID);

// Hidden bool settings (motion blur, explicit creation, on-screen control
// visibility) share one host path: read and toggle inside a host action, with
// the toggle in an undo group followed by the refresh-token write. Visibility
// toggles also record the value as the creation preference.
BOOL MMReadBoolSetting(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID, BOOL *value);
BOOL MMToggleBoolSetting(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID, NSString *undoName);
// Checkmarked item shared by the header settings menu and the Position and
// Scale row menus. The item starts disabled: its state needs an open host
// action, so the caller refreshes it inside one.
NSMenuItem *MMOSCVisibilityMenuItem(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID, NSString *title);
// Call from a menu's state handler, which already runs inside a host action.
void MMRefreshSettingMenuItem(NSMenuItem *item);
// One action for a whole menu, for callers building items outside an action.
void MMRefreshSettingMenuItems(NSMenu *menu, id<PROAPIAccessing> manager, NSView *sender);

// Menu lifecycle: handled actions already refresh inside their undo group;
// cancellation and failed actions still need a host refresh after tracking ends.
void MMPropertyMenuActionScheduled(NSMenu *menu);
void MMPropertyMenuActionFinished(NSMenu *menu, BOOL refreshed);

// Called inside a host action to present already-published cache state.
void MMPropertyMenuSetStateHandler(NSMenu *menu, void (^handler)(void));
// Call after a native parameter callback has refreshed its cached keyposes.
void MMPropertyMenuParametersChanged(id<PROAPIAccessing> manager);
