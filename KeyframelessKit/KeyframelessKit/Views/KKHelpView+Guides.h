/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKHelpView.h"
#import "KKHelpViewSubviews.h"

@class KKHelpGuide;

NS_ASSUME_NONNULL_BEGIN

/// Interactive-guides block: the guide row list plus the in-place
/// enabled/completed state machine. Split out of KKHelpView.m purely for
/// file size.
@interface KKHelpView (Guides)

/// Builds the "Interactive Guides" block (subheading + one row per guide)
/// and records the per-row refs used by the refresh state machine.
- (NSView *)_guidesBlockForGuides:(NSArray<KKHelpGuide *> *)guides;

/// Re-evaluates each guide's enabledProvider and rebuilds the guide rows.
/// Call this when external state that gates enabledProvider may have changed.
- (void)refreshGuideRows;

/// Registers an NSNotificationCenter observer that calls refreshGuideRows
/// whenever the named notification is posted. The observer is removed when
/// the view leaves its superview (via -_teardownGuideRefresh).
- (void)observeGuideRefreshNotificationNamed:(NSNotificationName)name;

/// Invalidates the refresh observer/timer and per-row loader timers. Called
/// from -viewDidMoveToSuperview when the view is detached.
- (void)_teardownGuideRefresh;

@end

NS_ASSUME_NONNULL_END
