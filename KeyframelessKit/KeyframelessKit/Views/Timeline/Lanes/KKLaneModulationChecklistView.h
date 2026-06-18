/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKLaneChecklistView.h"

NS_ASSUME_NONNULL_BEGIN

/// The modulate (Hold) popover's "Applies to" checklist - same chrome as the
/// in-out participation checklist (category pill nav + search + embedded
/// scroll), but compound: a multi-component lane shows a top-level master row
/// plus indented per-component sub-rows (so you can wiggle a Position's X but
/// not Y), mirroring the compound pill bar it replaces and the OSC checklist's
/// indented rows. Driven by the Hold popover's `compounds` (each = one lane:
/// master label then its component labels) + parallel `states`. `lanes[i]` is
/// the lane behind `compounds[i]`, used only for the category pill nav /
/// per-row category page. Toggling emits the SAME `(compoundIndex,
/// segmentIndex, isOn)` the pill bar emitted, so the host's flat-index callback
/// is unchanged.
@interface KKLaneModulationChecklistView : _KKLaneChecklistView

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                    compounds:(NSArray<NSArray<NSString *> *> *)compounds
                       states:(NSArray<NSArray<NSNumber *> *> *)states
                        width:(CGFloat)width
                maxBodyHeight:(CGFloat)maxBodyHeight;

@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger compoundIndex, NSInteger segmentIndex, BOOL isOn);

/// Refresh every row's checkbox after the model mutates externally (cmd-Z).
/// No-op if the shape no longer matches.
- (void)reloadStates:(NSArray<NSArray<NSNumber *> *> *)states;

/// Replace the whole row set (a multi-owner host re-scoping to a different
/// layer's compounds while the popover stays open) and rebuild in place.
- (void)reloadLanes:(NSArray<KKLane *> *)lanes
          compounds:(NSArray<NSArray<NSString *> *> *)compounds
             states:(NSArray<NSArray<NSNumber *> *> *)states;

@end

NS_ASSUME_NONNULL_END
