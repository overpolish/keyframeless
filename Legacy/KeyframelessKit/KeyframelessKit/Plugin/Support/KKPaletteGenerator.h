/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKPaletteMode) {
  KKPaletteModeBright = 0, // light, saturated moderate journey
  KKPaletteModeDull,       // muted, darker moderate journey
  KKPaletteModeShades,     // one hue, deep to light
  KKPaletteModeChaotic,    // bold, wide three-anchor journey
};

/// Generates gradient-friendly palettes as a "journey": colours walk between a
/// few anchor points in a hue/lightness disk (adapted from meodai/poline, MIT),
/// so a wide hue sweep passes through richer mids instead of grey. Colour-well
/// friendly: pass the current colours with locked slots pinned and the
/// generator keeps them, seeding the new journey from the locked hues so the
/// rest stay in the same family.
@interface KKPaletteGenerator : NSObject

/// `count` colours for `mode`. `locked` may be nil (all fresh) or an array of
/// length `count` mixing `NSColor` (keep exactly) and `NSNull` (regenerate).
/// Locked colours act as the journey's ANCHORS: the regenerated colours
/// interpolate between them, so pinning two swatches fills a gradient through
/// them (unpinned ends extend the walk). With nothing locked the whole journey
/// is invented from `mode`. Returned colours are sRGB, fully opaque.
+ (NSArray<NSColor *> *)paletteWithMode:(KKPaletteMode)mode
                                  count:(NSInteger)count
                                 locked:(nullable NSArray *)locked;

/// Subtly vary the CURRENT palette instead of rerolling: each unlocked colour
/// gets a small hue / saturation / lightness nudge so you can converge on a
/// keeper. `locked` entries (NSColor) are returned unchanged. `current` and
/// `locked` are parallel to the colour lanes.
+ (NSArray<NSColor *> *)refinedPaletteFrom:(NSArray<NSColor *> *)current
                                    locked:(nullable NSArray *)locked;

@end

NS_ASSUME_NONNULL_END
