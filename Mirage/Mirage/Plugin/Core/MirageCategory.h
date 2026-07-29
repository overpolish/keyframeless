/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import "MirageLocalized.h"
#import "MirageTemplateType.h"

NS_ASSUME_NONNULL_BEGIN

// What a shader IS, so the browser can be narrowed to the one you're after.
// Declared by `// #template ...` in Image code and copied to metadata.json for
// remote filtering before the source is downloaded. Unlike a favourite, it
// travels with the template.
//
// The STORED value is the raw string, never an index. A shader published by a
// newer build can name a category this one doesn't know, and keeping the string
// means a rename or a re-publish here doesn't silently rewrite it to something
// else. Only DISPLAY resolves an unknown, and it resolves to the default rather
// than inventing a category (see MirageCategoryNormalize).

/// Draws its own look; the source clip is a backdrop at most. The default, and
/// the most common - so it is also index 0 of MirageCategoryIDs().
static NSString *const kMirageCategoryGenerator = @"generator";
/// Processes the clip it is applied to (reads iChannel0).
static NSString *const kMirageCategoryFilter = @"filter";
/// Blends two clips across iProgress: the "To" well, usually via a Motion
/// transition template.
static NSString *const kMirageCategoryTransition = @"transition";
/// Draws its clip into one region of the frame (picture-in-picture, split,
/// quarters) and stays transparent elsewhere (`// #alpha`), so stacked
/// instances composite on Final Cut's lanes.
static NSString *const kMirageCategoryLayout = @"layout";
/// Converts a declared camera/display encoding into a practical output space.
/// The shipped Color Transform is the reference implementation; keeping it a
/// template type lets the browser and saved metadata preserve its identity.
static NSString *const kMirageCategoryColorTransform = @"color-transform";

/// Absent or unknown resolves here.
#define kMirageCategoryDefault kMirageCategoryGenerator

/// Every category id, in the order pickers and filters show them. The default
/// leads, so a picker's index 0 is the value a shader gets when nobody chooses.
static inline NSArray<NSString *> *MirageCategoryIDs(void) {
  return @[
    kMirageCategoryGenerator, kMirageCategoryFilter, kMirageCategoryTransition,
    kMirageCategoryLayout, kMirageCategoryColorTransform
  ];
}

/// The mandatory Image-source directive is the category's source of truth.
/// metadata.json carries the same value only so the remote browser can filter
/// an entry before downloading its GLSL.
static inline NSString *_Nullable MirageCategoryForSource(
    NSString *_Nullable source) {
  return MirageTemplateTypeID(MirageTemplateTypeForSource(source, NULL));
}

/// `raw` if it names a category this build knows, else the default. Read
/// metadata through this: it turns both a missing key (every entry saved before
/// categories existed) and a newer build's unknown value into something
/// displayable, with no migration pass over the folder.
static inline NSString *MirageCategoryNormalize(NSString *_Nullable raw) {
  if (raw.length && [MirageCategoryIDs() containsObject:raw])
    return raw;
  return kMirageCategoryDefault;
}

/// The SF Symbol that stands for a category on a card badge / filter row.
static inline NSString *MirageCategorySymbol(NSString *_Nullable categoryID) {
  NSString *c = MirageCategoryNormalize(categoryID);
  if ([c isEqualToString:kMirageCategoryFilter])
    return @"camera.filters";
  if ([c isEqualToString:kMirageCategoryTransition])
    return @"rectangle.2.swap";
  if ([c isEqualToString:kMirageCategoryLayout])
    return @"rectangle.grid.2x2";
  if ([c isEqualToString:kMirageCategoryColorTransform])
    return @"arrow.trianglehead.2.clockwise.rotate.90";
  return @"sparkles"; // generator
}

/// The category's user-facing name.
static inline NSString *
MirageCategoryDisplayName(NSString *_Nullable categoryID) {
  NSString *c = MirageCategoryNormalize(categoryID);
  if ([c isEqualToString:kMirageCategoryFilter])
    return RLoc(@"Filter", @"Mirage category: processes the clip.");
  if ([c isEqualToString:kMirageCategoryTransition])
    return RLoc(@"Transition", @"Mirage category: blends two clips.");
  if ([c isEqualToString:kMirageCategoryLayout])
    return RLoc(@"Layout", @"Mirage category: places a clip in a region.");
  if ([c isEqualToString:kMirageCategoryColorTransform])
    return RLoc(@"Color Transform",
                @"Mirage category: converts between color spaces.");
  return RLoc(@"Generator", @"Mirage category: draws its own look.");
}

NS_ASSUME_NONNULL_END
