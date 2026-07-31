/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A KKFloatingPanel drag strip that shows the open-hand grab cursor while the
/// pointer is over it.
///
/// The cursor comes from a tracking area rather than -addCursorRect:cursor:,
/// which AppKit only services for the key window - a non-activating panel beside
/// a popover frequently isn't one, and the cursor simply never changed.
@interface KKPanelDragHandleView : NSView
@end

/// A chrome-less companion panel the user can DRAG, which remembers where they
/// left it.
///
/// The existing companion panels (Mirage's template browser, Canvas's layer
/// list) are pinned beside the popover that opened them and recompute their
/// frame every time. That is right for a list you glance at, and wrong for a
/// panel you work in: the popover that triggers it opens at whatever height its
/// lane sits at, so a fixed placement puts the panel somewhere new each time and
/// the user re-drags it on every open.
///
/// So this one starts beside the card, then honours the position the user put it
/// in for every later open, persisted across processes.
///
/// It stays a CHILD window of the popover (ordered below), which is what keeps
/// clicks in it from dismissing the popover and keeps the pair moving together
/// when the inspector scrolls. Dragging only changes the offset within that
/// relationship.
@interface KKFloatingPanel : NSPanel

/// `positionKey` is the KKScopedDefaults field the origin persists under, so
/// two different floating panels remember separate places. Positions are stored
/// per PLUGIN rather than under the active scope: Mirage's active scope carries
/// the loaded shader's id, and a panel that jumped every time you switched
/// shader would be worse than one that never remembered at all.
- (instancetype)initWithContentSize:(NSSize)size
                        positionKey:(NSString *)positionKey;

/// Install `content` behind the standard companion-panel backing: liquid glass
/// on macOS 26, an inspector-matched visual-effect view below it, rounded to the
/// same radius with the shadow following the corners.
///
/// This is the chrome MirageBrowserController and CanvasLayerListController each
/// build by hand, mask image and all. New panels take it from here instead, and
/// those two can adopt it when they next need touching.
- (void)setPanelContentView:(NSView *)content;

/// Show as a child of `parent`, using the remembered origin when there is one
/// and `card` (the popover's visible rect, in screen coordinates) to place it
/// beside on the first ever open. A remembered origin that no longer lands on a
/// visible screen is discarded rather than restored off-screen, which is the
/// difference between "remembers where I put it" and "the panel is gone".
- (void)showBesideCard:(NSRect)card ofWindow:(NSWindow *)parent;

/// Hide and unparent. Does not forget the position.
- (void)hidePanel;

/// The view dragging is initiated from. Defaults to the whole content view, so
/// the panel drags by any part of its background that does not handle the click
/// itself. Set to a header strip for a panel whose body is interactive.
///
/// Use KKPanelDragHandleView for the strip to get the grab cursor: a drag region
/// with no background of its own is invisible, so the cursor is the only thing
/// telling the user it is there.
@property(nonatomic, weak, nullable) NSView *dragHandleView;

/// Called after a user drag settles, for a host that wants to react (e.g. save
/// nothing else, or re-align a pointer). The origin is already persisted.
@property(nonatomic, copy, nullable) void (^onUserMoved)(NSPoint origin);

@end

NS_ASSUME_NONNULL_END
