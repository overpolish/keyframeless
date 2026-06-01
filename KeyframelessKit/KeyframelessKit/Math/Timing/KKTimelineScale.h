/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Plugin- and model-agnostic timeline scale / scrubber math. Shared by
/// `KKTimelineBasicView` and the upcoming Advanced sequencer so the ruler,
/// the log time-warp and the zoom/pan transform are identical across both.
/// The per-model frac↔u remap (Basic's 3-section, Advanced's N-segment)
/// stays in each view; everything model-independent lives here.

/// Ruler timecode: `1.2s` (sub-minute, fractional) / `1:05` (≥1 min) /
/// `5s`. Reused verbatim from the old `KKStageSequencerRulerView`.
FOUNDATION_EXPORT NSString *KKTimelineScaleTimecode(double seconds);

/// Smallest "nice" tick interval (seconds) from a fixed candidate ladder
/// whose on-screen spacing is ≥ `minSpacing` px at `pixelsPerSecond`.
FOUNDATION_EXPORT double KKTimelineScaleTickInterval(CGFloat pixelsPerSecond,
                                                     CGFloat minSpacing);

/// Per-segment log-weight: `log(1 + seconds/τ)` where `seconds = frac *
/// clipDur`. Normalising these across a timeline's segments gives display
/// widths where short transitions stay visible against long holds and the
/// map is strictly monotonic. Generalises to N intervals (Advanced).
FOUNDATION_EXPORT double KKTimelineScaleLogWeight(double frac, double clipDur);

/// Normalised display position `u∈[0,1]` → screen x within rect `g`, with
/// zoom/pan applied (`zoom=1, pan=0` ⇒ identity across `g`). The model's
/// frac→u remap composes *before* this.
FOUNDATION_EXPORT CGFloat KKTimelineScaleUToX(double u, NSRect g, double zoom,
                                              double pan);

/// Inverse of `KKTimelineScaleUToX`: screen x → normalised `u`.
FOUNDATION_EXPORT double KKTimelineScaleXToU(CGFloat x, NSRect g, double zoom,
                                             double pan);

/// Clamp a pan offset to the valid range for `zoom` (`[0, 1 − 1/zoom]`).
FOUNDATION_EXPORT double KKTimelineScaleClampPan(double pan, double zoom);

NS_ASSUME_NONNULL_END
