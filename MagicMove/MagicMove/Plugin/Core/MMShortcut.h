/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

// The plugin's own shortcut: Control-Option-M toggles motion blur for the
// selected effect. Routing and capture live in PluginHost.
FOUNDATION_EXPORT NSString *MMMotionBlurShortcutKey(void);
FOUNDATION_EXPORT NSEventModifierFlags MMMotionBlurShortcutModifiers(void);
FOUNDATION_EXPORT NSString *MMMotionBlurShortcutDisplay(void);
BOOL MMShortcutMatches(unsigned short keyCode, NSEventModifierFlags modifiers);
BOOL MMToggleMotionBlur(id<PROAPIAccessing> manager, id sender);
