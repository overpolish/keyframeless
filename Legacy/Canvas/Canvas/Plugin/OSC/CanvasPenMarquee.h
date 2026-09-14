/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Hard cap on the dash segments a single marquee emits (a runaway guard for a
/// degenerate rect); a real selection never approaches it.
enum { kCanvasPenMarqueeMaxSegments = 4096 };

/// Called once per dash along the rectangle perimeter. `light` is YES for the
/// "on" dash, NO for the "off" gap (drawn as the dark two-tone underlay).
typedef void (^CanvasPenMarqueeSegmentBlock)(CGPoint from, CGPoint to,
                                             BOOL light);

/// Walk the pixel-snapped (floor + 0.5) perimeter of `r`, invoking `segment`
/// for each on/off dash so a two-tone dashed rectangle reads on any background.
/// The walk is shared by the viewer OSC and the inspector mini so their
/// marquees can't drift apart; each surface supplies the dash/gap (in surface
/// points) and the actual line drawing. A non-finite rect draws nothing.
void CanvasPenMarqueeWalk(CGRect r, CGFloat dash, CGFloat gap,
                          CanvasPenMarqueeSegmentBlock segment);

NS_ASSUME_NONNULL_END
