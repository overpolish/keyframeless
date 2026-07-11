/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Push the current timeline into the framework's process-snapshot store so OSC
/// draw ticks (where blob-param reads are flaky) can resolve lane values.
/// Set from `parameterChanged:` + the cold-boot seed in `createView:`.
void ShaderSetTimelineSnapshot(KKTimeline *_Nullable timeline);

/// Per-frame duration (seconds), pushed from the render path where FxTimingAPI
/// resolves, for frame-aware keypose snap tolerances.
void ShaderSetFrameDurationSeconds(double frameDurSec);

NS_ASSUME_NONNULL_END
