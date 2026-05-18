/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKHelpGuide;

NS_ASSUME_NONNULL_BEGIN

/// Plain NSButton subclass that calls a block on mouseDown so we can
/// capture guide.onStart without needing a target-action object.
@interface _KKGuideStartButton : NSButton
@property(nonatomic, copy) void (^actionBlock)(void);
@end

/// NSGridView that draws hairline separators between its rows.
@interface KKHelpShortcutsGrid : NSGridView
@end

/// Non-flipped background that paints the inspector colour and tucks a
/// faded rotated logo into the bottom-right corner.
@interface KKHelpBackgroundView : NSView
@end

/// Borderless link button used in the help-page table of contents.
/// Holds weak refs to its target section view and the scroll view, so a
/// click can scroll that section's title to the top of the visible
/// area. Confluence-style "On this page" jumplist.
@interface KKHelpTOCLink : NSButton
@property(weak) NSView *anchorView;
/// Document view of the surrounding scroll view (the page stack). Used
/// as the coordinate space for the scroll target and as the receiver of
/// `scrollPoint:`, which walks up to the nearest clip view automatically.
@property(weak) NSView *documentHost;
@end

/// Self-rounding capsule (cornerRadius tracks height) — matches the
/// app-wide InfoBadge look.
@interface _KKCapsuleView : NSView
@end

/// Holds the live controls for one guide row so its enabled appearance can
/// be updated in place — no tearing down and rebuilding the whole stack on
/// every refresh tick (the old churny "polling" behaviour).
@interface _KKGuideRowRefs : NSObject
@property(nonatomic, weak) KKHelpGuide *guide;
@property(nonatomic, weak) _KKGuideStartButton *icon;
@property(nonatomic, weak) NSTextField *title;
@property(nonatomic, weak) NSTextField *subtitle;
@property(nonatomic, weak) NSProgressIndicator *spinner;
@property(nonatomic, weak) NSView *badge;
@property(nonatomic, strong, nullable) NSTimer *loaderTimer;
@property(nonatomic) NSTimeInterval loaderStart;
@property(nonatomic) BOOL hasState;
@property(nonatomic) BOOL lastEnabled;
@property(nonatomic) BOOL lastViewed;
@end

NS_ASSUME_NONNULL_END
