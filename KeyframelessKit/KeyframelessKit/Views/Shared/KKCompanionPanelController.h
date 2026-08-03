/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The panel scaffold shared by the companion panels that ride beside an
/// inspector popover (Canvas's layer list, Mirage's template browser): a
/// borderless non-activating panel with the popover's chrome, pinned to the
/// popover card, following it when it moves, flips edge or resizes.
///
/// The host owns the CONTENT and everything the content means. This owns the
/// window: construction, the wait for the popover to actually be on screen, the
/// slide/fade entrance, the child-window relationship and the keep-alive that
/// stops a click inside it dismissing the popover.
///
/// It deliberately does NOT observe KKStaticValuesPopoverDidOpen/Close itself.
/// Each host filters those (Mirage skips the popovers with nothing to switch,
/// Canvas derives its non-selectable set from the kind) and calls
/// -openBesideCard:... when it wants the panel, so no host has to fight a
/// notification that was already handled for it.
@interface KKCompanionPanelController : NSObject

/// `logTag` names the host in the "popover never became visible" warning.
- (instancetype)initWithPanelWidth:(CGFloat)panelWidth
                            logTag:(NSString *)logTag;

/// Builds the panel's content view, called once, the first time the panel is
/// needed. Hosts keep their own reference to what they return - the panel is
/// created lazily, beside the first popover that wants it.
@property(nonatomic, copy, nullable) NSView *_Nullable (^contentBuilder)(void);

/// Ran once the panel is parented to the popover and the keep-alive is in
/// place, before the entrance animation - the moment the host's content is on
/// screen and worth populating.
@property(nonatomic, copy, nullable) void (^onDidAttach)(void);

/// Ran on EVERY -hide, including one that finds nothing showing (the host state
/// that tracks "a popover is open" has to clear either way).
@property(nonatomic, copy, nullable) void (^onPrepareHide)(void);

/// Ran only when a visible panel is actually being torn down, after the
/// follow-the-popover observers are gone and before the window is unparented.
@property(nonatomic, copy, nullable) void (^onDidHide)(void);

/// The panel itself, nil until the first open. For a host that needs to reach
/// the window (appearance, ordering); placement belongs to this class.
@property(nonatomic, readonly, nullable) NSPanel *panel;

/// YES between a completed open and the matching hide.
@property(nonatomic, readonly) BOOL visible;

/// Show beside `card` (the popover's visible rect in screen coordinates, which
/// excludes the arrow). `contentView` is the popover's content view, re-read on
/// every retry: at cold boot the window handed over at open time can be one the
/// view never ends up in. Either may be nil as long as the other is not.
- (void)openBesideCard:(NSRect)card
         popoverWindow:(nullable NSWindow *)popoverWindow
    popoverContentView:(nullable NSView *)contentView;

/// Hand the keyboard back to the popover this panel rides beside.
///
/// Call it when an action STARTED in the panel is finished with (a template
/// applied, a row committed): the popover owns the keyboard shortcuts, and a
/// panel that took key for a text field would otherwise keep it long after the
/// text field mattered. A no-op when the panel isn't the key window.
- (void)returnKeyFocusToPopover;

/// Tear the panel down (popover closed, or the host is going away).
- (void)hide;

@end

NS_ASSUME_NONNULL_END
