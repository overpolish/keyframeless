/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

BOOL MMShortcutMatches(unsigned short keyCode, NSEventModifierFlags modifiers);
BOOL MMToggleMotionBlur(id<PROAPIAccessing> manager, id sender);

// Main-thread routing. Owners are weak; callbacks must not retain their owner.
@interface MMShortcutRouter : NSObject
- (void)registerOwner:(id)owner eligible:(BOOL (^)(void))eligible action:(BOOL (^)(void))action;
- (void)unregisterOwner:(id)owner;
- (void)activateOwner:(id)owner;
- (BOOL)handleKeyCode:(unsigned short)code modifiers:(NSEventModifierFlags)modifiers repeat:(BOOL)repeat;
@end

// Plugin-local AppKit adapter; does not depend on the legacy shortcut helpers.
@interface MMShortcutCapture : NSObject
+ (instancetype)sharedCapture;
- (void)attachView:(NSView *)view action:(BOOL (^)(void))action;
- (void)detachView:(NSView *)view;
- (void)activateView:(NSView *)view;
@end
