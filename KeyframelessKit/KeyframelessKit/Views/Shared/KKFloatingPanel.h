/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A transparent KKFloatingPanel drag strip. The panel owns cursor tracking so
/// it can distinguish empty strip space from buttons layered above the strip.
@interface KKPanelDragHandleView : NSView
@end

/// A chrome-less companion panel the user can DRAG, which remembers where they
/// left it.
///
/// The existing companion panels (Mirage's template browser, Canvas's layer
/// list) are pinned beside the popover that opened them and recompute their
/// frame every time. That is right for a list you glance at, and wrong for a
/// panel you work in: the popover that triggers it opens at whatever height its
/// lane sits at, so a fixed placement puts the panel somewhere new each time
/// and the user re-drags it on every open.
///
/// So this one starts beside the card, then honours the position the user put
/// it in for every later open, persisted across processes.
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
/// on macOS 26, an inspector-matched visual-effect view below it, rounded to
/// the same radius with the shadow following the corners.
///
/// This is the chrome MirageBrowserController and CanvasLayerListController
/// each build by hand, mask image and all. New panels take it from here
/// instead, and those two can adopt it when they next need touching.
- (void)setPanelContentView:(NSView *)content;

/// Show as a child of `parent`, using the remembered origin when there is one
/// and `card` (the popover's visible rect, in screen coordinates) to place it
/// beside on the first ever open. A remembered origin that no longer lands on a
/// visible screen is discarded rather than restored off-screen, which is the
/// difference between "remembers where I put it" and "the panel is gone".
- (void)showBesideCard:(NSRect)card ofWindow:(NSWindow *)parent;

/// Hide and unparent. Does not forget the position.
- (void)hidePanel;

/// Editor panels opt into becoming key so text fields and code editors work.
/// The default remains NO for control-only companions such as the colour
/// surface, preserving their host-shortcut behaviour.
@property(nonatomic) BOOL allowsKeyWindow;

/// Whether background / drag-handle presses move the panel. Defaults to YES.
/// Primary editor panels leave this off until their dedicated movable mode is
/// enabled; companion surfaces keep their existing draggable behaviour.
@property(nonatomic) BOOL userMovable;

/// Enable normal window-style resizing from every edge and corner, driven by
/// the same cross-window event monitors as panel dragging. `minSize` supplies
/// the content floor and the active screen supplies the maximum. The final
/// frame is kept reachable and remembered.
@property(nonatomic) BOOL userResizable;

/// Clamp the whole panel inside one screen's visible frame on show, resize and
/// drag. Defaults to NO so existing companions retain their current placement
/// semantics. Primary editors enable it so no control can be stranded beyond
/// a display edge.
@property(nonatomic) BOOL keepsEntireFrameVisible;

/// Resize without moving the top edge, then apply the panel's screen-safety
/// policy. Editor content changes height frequently as categories and modes
/// change, and growing downward is much less disruptive than moving the title.
- (void)setContentSizeKeepingTopEdge:(NSSize)size;
/// Resize against an already-captured top edge. Useful when changing the
/// hosted layout itself can synchronously perturb the panel frame.
- (void)setContentSize:(NSSize)size keepingTopEdgeAt:(CGFloat)top;

/// The view dragging is initiated from. Defaults to the whole content view, so
/// the panel drags by any part of its background that does not handle the click
/// itself. Set to a header strip for a panel whose body is interactive.
///
/// Use KKPanelDragHandleView for a transparent strip; KKFloatingPanel shows the
/// grab cursor only over its non-interactive space.
@property(nonatomic, weak, nullable) NSView *dragHandleView;

/// Called after a user drag settles, for a host that wants to react (e.g. save
/// nothing else, or re-align a pointer). The origin is already persisted.
@property(nonatomic, copy, nullable) void (^onUserMoved)(NSPoint origin);

/// Fired continuously during a user resize so hosted content can reflow its
/// width-dependent layout, then once more at mouse-up with the settled size.
@property(nonatomic, copy, nullable) void (^onUserResized)(NSSize size);

/// Host command routing for key equivalents AppKit would otherwise resolve
/// against this remote panel's empty undo manager.
@property(nonatomic, copy, nullable) void (^onUndoRequested)(void);
@property(nonatomic, copy, nullable) void (^onRedoRequested)(void);

@end

NS_ASSUME_NONNULL_END
