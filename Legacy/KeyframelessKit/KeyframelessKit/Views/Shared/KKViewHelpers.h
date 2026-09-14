/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Does `existing` still describe `rect`, so -updateTrackingAreas can leave it
/// alone?
///
/// AppKit calls -updateTrackingAreas from its PER-DISPLAY-CYCLE structural
/// regions pass, and add/removeTrackingArea marks those regions dirty. So a
/// method that rebuilds unconditionally re-dirties what the pass just cleaned,
/// the pass runs again next cycle, and it never settles - on a 120Hz display
/// that is 120 full recursive walks of the view tree a second, which pins the
/// main thread and makes the UI stop responding to input. Rebuild only on an
/// actual change.
///
/// A tracking area built with `NSTrackingInVisibleRect` ignores its rect
/// (AppKit maintains it), so those pass NSZeroRect and this still compares
/// equal.
static inline BOOL KKTrackingAreaMatches(NSTrackingArea *_Nullable existing,
                                         NSRect rect) {
  return existing != nil && NSEqualRects(existing.rect, rect);
}

NS_ASSUME_NONNULL_END
