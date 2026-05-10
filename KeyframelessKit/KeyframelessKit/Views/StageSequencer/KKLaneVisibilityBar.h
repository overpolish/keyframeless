/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

/// Fired while the user drags across pills after a non-option mouseDown.
/// `visible` is the target state (= new state of the pill the drag started
/// on) — handler should set that lane's visibility to `visible` directly,
/// without solo semantics. Fires once per pill the cursor enters.
@property(nonatomic, copy, nullable) void (^onPillDraggedToVisible)
    (NSInteger laneIndex, BOOL visible);

/// Fired on mouseDown for any non-option pill click (whether or not the
/// user goes on to drag). Pairs with `onDragEnd` on mouseUp. Plugin uses
/// these to bracket the entire interaction in one outer action scope +
/// undo group so the click-and-drag toggles coalesce into one undo entry.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

@end

NS_ASSUME_NONNULL_END
