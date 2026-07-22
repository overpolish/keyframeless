/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKArcOSC : KKOnScreenControl

/// Outer radius of the ring in canvas pixels. Default 23.
@property(nonatomic) float oscRadius;

/// Thickness of the ring stroke. Default 10.
@property(nonatomic) float strokeWidth;

/// Width of the outline around the ring. Default 1.75.
@property(nonatomic) float outlineWidth;

/// Multiplier for the fill color alpha. Default 1.0.
@property(nonatomic) float fillAlpha;

/// Multiplier on the WHOLE glyph's alpha (fill + stroke), default 1.0. Draw at
/// < 1.0 to render as a dimmed "ghost" during Opt-reveal - the same contract
/// as the other glyph handles (KKPointOSC / KKSquarePointOSC / KKRingOSC).
@property(nonatomic) float ghostAlpha;

@end

NS_ASSUME_NONNULL_END
