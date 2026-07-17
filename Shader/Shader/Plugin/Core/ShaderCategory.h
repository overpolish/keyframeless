/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import "ShaderLocalized.h"

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
// than inventing a category (see ShaderCategoryNormalize).

/// Draws its own look; the source clip is a backdrop at most. The default, and
/// the most common - so it is also index 0 of ShaderCategoryIDs().
static NSString *const kShaderCategoryGenerator = @"generator";
/// Reacts to a Sonar-published `#audio` binding.
static NSString *const kShaderCategoryAudio = @"audio";
/// Processes the clip it is applied to (reads iChannel0).
static NSString *const kShaderCategoryFilter = @"filter";
/// Blends two clips across iProgress: the "To" well, usually via a Motion
/// transition template.
static NSString *const kShaderCategoryTransition = @"transition";
/// Draws its clip into one region of the frame (picture-in-picture, split,
/// quarters) and stays transparent elsewhere (`// #alpha`), so stacked
/// instances composite on Final Cut's lanes.
static NSString *const kShaderCategoryLayout = @"layout";

/// Absent or unknown resolves here.
#define kShaderCategoryDefault kShaderCategoryGenerator

/// Every category id, in the order pickers and filters show them. The default
/// leads, so a picker's index 0 is the value a shader gets when nobody chooses.
static inline NSArray<NSString *> *ShaderCategoryIDs(void) {
  return @[
    kShaderCategoryGenerator, kShaderCategoryAudio, kShaderCategoryFilter,
    kShaderCategoryTransition, kShaderCategoryLayout
  ];
}

/// `raw` if it names a category this build knows, else the default. Read
/// metadata through this: it turns both a missing key (every entry saved before
/// categories existed) and a newer build's unknown value into something
/// displayable, with no migration pass over the folder.
static inline NSString *ShaderCategoryNormalize(NSString *_Nullable raw) {
  if (raw.length && [ShaderCategoryIDs() containsObject:raw])
    return raw;
  return kShaderCategoryDefault;
}

/// Index into ShaderCategoryIDs(), for a picker's selection. Unknown -> 0.
static inline NSInteger ShaderCategoryIndex(NSString *_Nullable categoryID) {
  NSUInteger i =
      [ShaderCategoryIDs() indexOfObject:ShaderCategoryNormalize(categoryID)];
  return i == NSNotFound ? 0 : (NSInteger)i;
}

/// The inverse: a picker's index back to a category id. Out of range (and a nil
/// index, i.e. a save bar that showed no picker at all) -> the default.
static inline NSString *ShaderCategoryAtIndex(NSNumber *_Nullable index) {
  NSArray<NSString *> *ids = ShaderCategoryIDs();
  NSInteger i = index ? index.integerValue : -1;
  return (i >= 0 && i < (NSInteger)ids.count) ? ids[i] : kShaderCategoryDefault;
}

/// The SF Symbol that stands for a category on a card badge / filter row.
static inline NSString *ShaderCategorySymbol(NSString *_Nullable categoryID) {
  NSString *c = ShaderCategoryNormalize(categoryID);
  if ([c isEqualToString:kShaderCategoryAudio])
    return @"waveform";
  if ([c isEqualToString:kShaderCategoryFilter])
    return @"camera.filters";
  if ([c isEqualToString:kShaderCategoryTransition])
    return @"rectangle.2.swap";
  if ([c isEqualToString:kShaderCategoryLayout])
    return @"rectangle.grid.2x2";
  return @"sparkles"; // generator
}

/// The category's user-facing name.
static inline NSString *
ShaderCategoryDisplayName(NSString *_Nullable categoryID) {
  NSString *c = ShaderCategoryNormalize(categoryID);
  if ([c isEqualToString:kShaderCategoryAudio])
    return RLoc(@"Audio", @"Shader category: reacts to audio.");
  if ([c isEqualToString:kShaderCategoryFilter])
    return RLoc(@"Filter", @"Shader category: processes the clip.");
  if ([c isEqualToString:kShaderCategoryTransition])
    return RLoc(@"Transition", @"Shader category: blends two clips.");
  if ([c isEqualToString:kShaderCategoryLayout])
    return RLoc(@"Layout", @"Shader category: places a clip in a region.");
  return RLoc(@"Generator", @"Shader category: draws its own look.");
}

/// Display names in ShaderCategoryIDs() order, for a picker's option list.
static inline NSArray<NSString *> *ShaderCategoryDisplayNames(void) {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSString *c in ShaderCategoryIDs())
    [out addObject:ShaderCategoryDisplayName(c)];
  return out;
}

NS_ASSUME_NONNULL_END
