/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Draw the shared timeline empty-state hint: a dimmed, single-line label
/// (KKFontSizeSM, inspectorLabel at 0.4 alpha) centered in `rect`. Used by the
/// Basic and Advanced graphs to render their "nothing animated" / "all lanes
/// hidden" message in the track area. No-op for an empty string.
FOUNDATION_EXPORT void KKTimelineDrawCenteredHint(NSString *text, NSRect rect);

NS_ASSUME_NONNULL_END
