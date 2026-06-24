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

/// Template glyph icons for a stroke start/end marker pill, in lane-value
/// order: 0 = None, 1 = Arrow, 2 = Circle, 3 = Square, 4 = Arrowhead, 5 = Line.
/// The glyph orients toward the matching end - `isStart` mirrors it to the left
/// so the Start pill reads as a back-pointing decoration and the End pill
/// forward. Ported from the pre-v3 _Attic marker glyphs.
NSArray<NSImage *> *CanvasMarkerGlyphs(BOOL isStart);

NS_ASSUME_NONNULL_END
