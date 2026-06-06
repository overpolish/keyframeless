/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKTimelineInspectorView.h"

NS_ASSUME_NONNULL_BEGIN

/// The Presets row + popover wiring. Pure timeline transforms live in
/// KKPresetTimelineOps; this category owns the row, the popover lifecycle, and
/// the apply/save plumbing into the inspector.
@interface KKTimelineInspectorView (Presets)
/// Last reachable clip fraction (the playhead stops one frame before clip end).
- (double)_presetEndFraction;
@end

NS_ASSUME_NONNULL_END
