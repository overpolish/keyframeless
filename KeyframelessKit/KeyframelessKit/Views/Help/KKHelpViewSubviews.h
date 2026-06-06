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

/// Non-flipped background that paints the inspector colour and tucks a
/// faded rotated logo into the bottom-right corner.
@interface KKHelpBackgroundView : NSView
@end

/// Self-rounding capsule (cornerRadius tracks height) - matches the
/// app-wide InfoBadge look.
@interface _KKCapsuleView : NSView
@end

/// Holds the live controls for one guide row so its enabled appearance can
/// be updated in place - no tearing down and rebuilding the whole stack on
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
/// The text column's trailing edge stops before the badge when it's showing,
/// and runs to the row edge when it's hidden. Toggled in -_applyStateToRefs.
@property(nonatomic, strong, nullable)
    NSLayoutConstraint *textTrailingWithBadge;
@property(nonatomic, strong, nullable) NSLayoutConstraint *textTrailingNoBadge;
@property(nonatomic) BOOL hasState;
@property(nonatomic) BOOL lastEnabled;
@property(nonatomic) BOOL lastViewed;
@end

NS_ASSUME_NONNULL_END
