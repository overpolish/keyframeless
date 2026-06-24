/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Template glyph icons for the stroke Line Cap pill, in lane-value order:
/// 0 = Butt, 1 = Round, 2 = Square. Ported from the pre-v3 _Attic cap glyphs.
NSArray<NSImage *> *CanvasLineCapGlyphs(void);

/// Template glyph icons for the stroke Line Join pill, in lane-value order:
/// 0 = Miter, 1 = Round, 2 = Bevel. Ported from the pre-v3 _Attic join glyphs.
NSArray<NSImage *> *CanvasLineJoinGlyphs(void);

NS_ASSUME_NONNULL_END
