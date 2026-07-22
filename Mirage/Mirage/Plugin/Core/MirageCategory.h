/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import "MirageLocalized.h"

NS_ASSUME_NONNULL_BEGIN

// What a shader IS, so a browser that now holds every kind of shader can be
// narrowed to the one you're after. Chosen at save time and carried in
// metadata.json, so it travels with a publish - unlike a favourite, which is a
// per-user opinion and so lives in NSUserDefaults keyed by entry id.
//
// The STORED value is the raw string, never an index. A shader published by a
// newer build can name a category this one doesn't know, and keeping the string
// means a rename or a re-publish here doesn't silently rewrite it to something
// else. Only DISPLAY resolves an unknown, and it resolves to the default rather
// than inventing a category (see MirageCategoryNormalize).

/// Draws its own look; the source clip is a backdrop at most. The default, and
/// the most common - so it is also index 0 of MirageCategoryIDs().
static NSString *const kMirageCategoryGenerator = @"generator";
/// Reacts to a Sonar-published `#audio` binding.
static NSString *const kMirageCategoryAudio = @"audio";
/// Processes the clip it is applied to (reads iChannel0).
static NSString *const kMirageCategoryFilter = @"filter";
/// Blends two clips across iProgress: the "To" well, usually via a Motion
/// transition template.
static NSString *const kMirageCategoryTransition = @"transition";
/// Draws its clip into one region of the frame (picture-in-picture, split,
/// quarters) and stays transparent elsewhere (`// #alpha`), so stacked
/// instances composite on Final Cut's lanes.
static NSString *const kMirageCategoryLayout = @"layout";

/// Absent or unknown resolves here.
#define kMirageCategoryDefault kMirageCategoryGenerator

/// Every category id, in the order pickers and filters show them. The default
/// leads, so a picker's index 0 is the value a shader gets when nobody chooses.
static inline NSArray<NSString *> *MirageCategoryIDs(void) {
  return @[
    kMirageCategoryGenerator, kMirageCategoryAudio, kMirageCategoryFilter,
    kMirageCategoryTransition, kMirageCategoryLayout
  ];
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

/// Index into MirageCategoryIDs(), for a picker's selection. Unknown -> 0.
static inline NSInteger MirageCategoryIndex(NSString *_Nullable categoryID) {
  NSUInteger i =
      [MirageCategoryIDs() indexOfObject:MirageCategoryNormalize(categoryID)];
  return i == NSNotFound ? 0 : (NSInteger)i;
}

/// The inverse: a picker's index back to a category id. Out of range (and a nil
/// index, i.e. a save bar that showed no picker at all) -> the default.
static inline NSString *MirageCategoryAtIndex(NSNumber *_Nullable index) {
  NSArray<NSString *> *ids = MirageCategoryIDs();
  NSInteger i = index ? index.integerValue : -1;
  return (i >= 0 && i < (NSInteger)ids.count) ? ids[i] : kMirageCategoryDefault;
}

/// The SF Symbol that stands for a category on a card badge / filter row.
static inline NSString *MirageCategorySymbol(NSString *_Nullable categoryID) {
  NSString *c = MirageCategoryNormalize(categoryID);
  if ([c isEqualToString:kMirageCategoryAudio])
    return @"waveform";
  if ([c isEqualToString:kMirageCategoryFilter])
    return @"camera.filters";
  if ([c isEqualToString:kMirageCategoryTransition])
    return @"rectangle.2.swap";
  if ([c isEqualToString:kMirageCategoryLayout])
    return @"rectangle.grid.2x2";
  return @"sparkles"; // generator
}

/// The category's user-facing name.
static inline NSString *
MirageCategoryDisplayName(NSString *_Nullable categoryID) {
  NSString *c = MirageCategoryNormalize(categoryID);
  if ([c isEqualToString:kMirageCategoryAudio])
    return RLoc(@"Audio", @"Mirage category: reacts to audio.");
  if ([c isEqualToString:kMirageCategoryFilter])
    return RLoc(@"Filter", @"Mirage category: processes the clip.");
  if ([c isEqualToString:kMirageCategoryTransition])
    return RLoc(@"Transition", @"Mirage category: blends two clips.");
  if ([c isEqualToString:kMirageCategoryLayout])
    return RLoc(@"Layout", @"Mirage category: places a clip in a region.");
  return RLoc(@"Generator", @"Mirage category: draws its own look.");
}

/// Display names in MirageCategoryIDs() order, for a picker's option list.
static inline NSArray<NSString *> *MirageCategoryDisplayNames(void) {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSString *c in MirageCategoryIDs())
    [out addObject:MirageCategoryDisplayName(c)];
  return out;
}

NS_ASSUME_NONNULL_END
