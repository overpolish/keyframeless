/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimeline.h>

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

/// Scope the "Make Default" / "Reset" pair reads and writes (see
/// KKOSCVisibilityDefaults). nil = the process-wide active scope, which is the
/// plugin (plus the shader template in Mirage); Canvas passes a kind-suffixed
/// scope so a vector layer's default can't leave an image layer with no
/// visible control. Set before the view is shown.
@property(nonatomic, copy, nullable) NSString *defaultsScope;

/// Feed the owner (layer) dimension, from the plugin's lane templates: an
/// element key's owner is the `layerKey` of the lane whose `key` matches it (a
/// motion-path element, `<lane> Path`, inherits its base lane's). When the
/// CURRENT compounds resolve to two or more distinct owners, a layer pill row
/// appears above the search field and the rows are scoped to the selected one,
/// exactly as the Animated dropdown's nav does; below two it is a no-op and the
/// list stays pixel-identical. `selectedLayerKey` is the owner to open on (an
/// unknown key falls back to the first - there is no "all owners" page).
///
/// Call BEFORE the view is sized / presented: it changes `fittingHeight`.
- (void)applyLayerLanes:(NSArray<KKLane *> *)lanes
       selectedLayerKey:(nullable NSString *)selectedLayerKey;

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
