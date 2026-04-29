/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Pill-row above the stage sequencer that lets the user filter which lanes
/// are visible (and included in bulk operations). Click toggles a single
/// lane; option-click solos that lane (or unsolos when already soloed).
@interface KKLaneVisibilityBar : NSView

@property(class, nonatomic, readonly) CGFloat preferredHeight;

/// Lane labels, left-to-right. Length must match `visibleStates`.
@property(nonatomic, copy) NSArray<NSString *> *labels;
/// Per-lane visibility state. Length must match `labels`.
@property(nonatomic, copy) NSArray<NSNumber *> *visibleStates;

/// Fired when the user clicks a pill. The handler is responsible for
/// computing the new visibleStates array (toggle / solo / unsolo) and
/// pushing it back via `visibleStates` once persisted.
@property(nonatomic, copy, nullable) void (^onPillClicked)
    (NSInteger laneIndex, BOOL optionDown);

@end

NS_ASSUME_NONNULL_END
