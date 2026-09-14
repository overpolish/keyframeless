/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

FOUNDATION_EXPORT NSString *MMMotionBlurShortcutKey(void);
FOUNDATION_EXPORT NSEventModifierFlags MMMotionBlurShortcutModifiers(void);
FOUNDATION_EXPORT NSString *MMMotionBlurShortcutDisplay(void);
BOOL MMShortcutMatches(unsigned short keyCode, NSEventModifierFlags modifiers);
BOOL MMToggleMotionBlur(id<PROAPIAccessing> manager, id sender);

// Main-thread routing. Rows sharing an effect are one candidate; host view
// eligibility is checked anew on every keypress. Owners/effects are weak; callbacks must not retain their owner.
@interface MMShortcutRouter : NSObject
- (void)registerOwner:(id)owner effect:(id)effect eligible:(BOOL (^)(void))eligible action:(BOOL (^)(void))action;
- (void)registerOwner:(id)owner eligible:(BOOL (^)(void))eligible action:(BOOL (^)(void))action;
- (void)unregisterOwner:(id)owner;
- (void)activateOwner:(id)owner;
- (BOOL)handleKeyCode:(unsigned short)code modifiers:(NSEventModifierFlags)modifiers repeat:(BOOL)repeat;
@end

// A temporary history route owned by the currently open menu. Commands are
// queued so remote host work never blocks the input event-tap callback.
@interface MMMenuHistoryShortcut : NSObject
@property(nonatomic,readonly) BOOL active;
- (void)beginForOwner:(id)owner action:(BOOL (^)(BOOL redo))action;
- (void)endForOwner:(id)owner;
- (BOOL)enqueueKeyCode:(unsigned short)code modifiers:(NSEventModifierFlags)flags repeat:(BOOL)repeat;
@end

// Plugin-local AppKit adapter; does not depend on the legacy shortcut helpers.
@interface MMShortcutCapture : NSObject
+ (instancetype)sharedCapture;
- (void)attachView:(NSView *)view effect:(id)effect action:(BOOL (^)(void))action;
- (void)attachView:(NSView *)view action:(BOOL (^)(void))action;
- (void)detachView:(NSView *)view;
- (void)activateView:(NSView *)view;
- (void)beginMenuHistory:(id)owner action:(BOOL (^)(BOOL redo))action;
- (void)endMenuHistory:(id)owner;
@end
