/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

// The saved scratch parameter a menu action writes to ask the host for a
// repaint at a stationary playhead. The plugin registers it once at load.
void KFSetHostRefreshParameter(UInt32 parameterID);
BOOL KFRequestHostRefresh(id<PROAPIAccessing> manager, CMTime time);

// Hidden bool settings share one host path: read and toggle inside a host
// action, with the toggle in an undo group followed by the refresh-token write.
BOOL KFReadBoolSetting(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID, BOOL *value);
BOOL KFToggleBoolSetting(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID, NSString *undoName);
// Settings that double as a creation preference record the new value through
// this writer, so preference storage and key names stay with the plugin.
void KFSetBoolSettingPreferenceWriter(void (^writer)(UInt32 parameterID, BOOL value));

// Checkmarked item shared by header and row menus. The item starts disabled:
// its state needs an open host action, so the caller refreshes it inside one.
NSMenuItem *KFSettingMenuItem(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameterID,
                              NSString *title, NSString *undoName);
// Call from a menu's state handler, which already runs inside a host action.
void KFRefreshSettingMenuItem(NSMenuItem *item);
// One action for a whole menu, for callers building items outside an action.
void KFRefreshSettingMenuItems(NSMenu *menu, id<PROAPIAccessing> manager, NSView *sender);
