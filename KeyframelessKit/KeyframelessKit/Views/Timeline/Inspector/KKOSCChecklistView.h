/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Grouped, checkable, filterable list of on-screen-control elements - the same
/// row + search styling as the animated / manage-lanes dropdown, replacing the
/// OSC pill bar so the two surfaces read consistently.
///
/// Driven by the inspector's `oscVisibilityCompounds` (arrays of element keys)
/// plus parallel `states`. Each row's display label is the element key's last
/// dot-separated component (so `Rotation.X` reads as "X"), localized at draw
/// time like the manage dropdown's rows. A key that is `Parent.Child` (prefixed
/// by an earlier key in the SAME compound, e.g. `Rotation.X` under `Rotation`)
/// renders indented under that parent; every other key is a top-level row.
/// Toggling a row emits the SAME `(compoundIndex, segmentIndex, isOn)` the pill
/// bar emitted, so the visibility storage path is unchanged.
@interface KKOSCChecklistView : NSView

- (instancetype)initWithCompounds:(NSArray<NSArray<NSString *> *> *)compounds
                           states:(NSArray<NSArray<NSNumber *> *> *)states;

/// Maps an element key to the user-facing name to SHOW for it (else the key's
/// localized leaf is used). Lets a dynamic plugin key elements on a stable id
/// (e.g. a shader uniform name) while the checklist shows the display label.
/// Set BEFORE the view is added; applied at build time.
- (instancetype)initWithCompounds:(NSArray<NSArray<NSString *> *> *)compounds
                           states:(NSArray<NSArray<NSNumber *> *> *)states
                    displayForKey:
                        (nullable NSString * (^)(NSString *key))displayForKey;

/// Fired when a row's checkbox toggles, with the element's position in
/// `compounds` and its new state.
@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger compoundIndex, NSInteger segmentIndex, BOOL isOn);

/// Set so the view can re-fit the popover as the search filter hides rows.
@property(nonatomic, weak, nullable) NSPopover *popover;

/// Replace the checkbox states (parallel to the init `compounds`), e.g. when
/// the host swaps to a different owner's set while the popover stays open.
/// No-op if the shape doesn't match.
- (void)reloadStates:(NSArray<NSArray<NSNumber *> *> *)states;

/// Popover content width + the height that hugs the currently-visible rows.
+ (CGFloat)preferredWidth;
- (CGFloat)fittingHeight;

/// Screen rect of the first (top-level) row of `compoundIndex`, for a guide
/// spotlight; NSZeroRect if out of range / not in a window.
- (NSRect)screenRectForCompoundIndex:(NSInteger)compoundIndex;

@end

NS_ASSUME_NONNULL_END
