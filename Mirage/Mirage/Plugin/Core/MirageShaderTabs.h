/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Both directions of the `// #tab` interchange for the AI's code route: the
// shader lane's sections out as ONE flat blob (what the model is shown, and
// what Copy Schema puts on the clipboard), and a split blob back into a section
// set (what the model answers with). The split itself is the kit's
// KKCodeSplitTabbedText - this is only the lane-shaped half either side of it.
//
// Foundation only, and the lane's parts arrive as plain strings/dictionaries
// rather than a KKLane, so the composition can be exercised outside the plugin.
#import <Foundation/Foundation.h>

#import "MirageSchemaDoc.h" // MirageSchemaTabMarkerSpelling

NS_ASSUME_NONNULL_BEGIN

/// `image` (the primary section) plus `tabs` (@{@"name", @"code"}, the extra
/// sections) as one `// #tab` blob, Image first and the rest in their stored
/// order. An empty `tabs` gives the bare Image source back with no marker at
/// all: a single-pass shader has nothing to interchange.
static inline NSString *MirageShaderTabsBlob(
    NSString *_Nullable image,
    NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable tabs) {
  NSString *primary = image ?: @"";
  if (!tabs.count)
    return primary;
  NSMutableString *blob = [NSMutableString string];
  [blob appendFormat:@"// #tab %@\n%@\n",
                     MirageSchemaTabMarkerSpelling(@"Image"), primary];
  for (NSDictionary<NSString *, NSString *> *tab in tabs) {
    NSString *name = tab[@"name"];
    if (!name.length)
      continue;
    [blob appendFormat:@"// #tab %@\n%@\n", MirageSchemaTabMarkerSpelling(name),
                       tab[@"code"] ?: @""];
  }
  return blob;
}

/// `existing` extra sections with `split` (a KKCodeSplitTabbedText result) laid
/// over them: a named section replaces the tab of that name, KEEPS a tab the
/// answer didn't mention, and a new one is inserted in catalog order.
/// `knownNames` is Image followed by the catalog, so it doubles as that order.
/// The Image section is the caller's business (it lives on `codeString`).
///
/// Mirrors the code editor's own paste semantics (`_applyTabbedPaste:`) so an
/// AI answer and a hand paste land identically.
static inline NSArray<NSDictionary<NSString *, NSString *> *> *
MirageShaderTabsMerged(
    NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable existing,
    NSDictionary<NSString *, NSString *> *split,
    NSArray<NSString *> *knownNames) {
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *tabs =
      [(existing ?: @[]) mutableCopy];
  for (NSString *name in knownNames) {
    if ([name isEqualToString:@"Image"])
      continue;
    NSString *code = split[name];
    if (!code)
      continue;
    NSDictionary<NSString *, NSString *> *entry =
        @{@"name" : name, @"code" : code};
    NSUInteger at = NSNotFound;
    for (NSUInteger i = 0; i < tabs.count; i++)
      if ([tabs[i][@"name"] isEqualToString:name]) {
        at = i;
        break;
      }
    if (at != NSNotFound) {
      tabs[at] = entry;
      continue;
    }
    // The first present tab that sorts AFTER this one is where it belongs.
    NSUInteger want = [knownNames indexOfObject:name];
    NSUInteger insertAt = tabs.count;
    for (NSUInteger i = 0; i < tabs.count; i++) {
      NSUInteger ci = [knownNames indexOfObject:tabs[i][@"name"] ?: @""];
      if (ci != NSNotFound && ci > want) {
        insertAt = i;
        break;
      }
    }
    [tabs insertObject:entry atIndex:insertAt];
  }
  return tabs;
}

NS_ASSUME_NONNULL_END
