/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKHelpSection.h"

NS_ASSUME_NONNULL_BEGIN

/// A rendered tip is prefixed with one of these markers per level of bullet
/// indentation (a nested `  - ` sub-bullet in the markdown). The help view
/// counts the leading markers to indent the row, so lists read as a nested
/// hierarchy instead of a flat run. Survives KKMarkup untouched.
FOUNDATION_EXPORT NSString *const KKHelpTipIndentMarker;

/// Renders the shared timeline knowledge markdown (the same `.md` files the AI
/// assistant reads, now carried in the KeyframelessKit bundle) into help-window
/// tip markup. One English source of truth feeds both the AI docs and the help
/// window; the help view localizes the rendered prose at display time.
///
/// Mapping: each top-level `- ` bullet (with any indented sub-bullets folded in)
/// and each paragraph becomes one tip. Inline `**bold**` maps to an `<accent>`
/// run and `` `code` `` to a `<kbd>` badge, so the help view keeps its styling
/// while the markdown stays clean prose for the LLM.
@interface KKHelpSection (Markdown)

/// Pure parse (Foundation only): markdown body -> ordered tip markup strings.
/// Frontmatter, if present, is stripped. Strings are NOT localized.
+ (NSArray<NSString *> *)tipMarkupFromKnowledgeMarkdown:(NSString *)markdown;

/// Load `<topicID>.md` from `bundle` (optionally a `subdirectory`), parse it,
/// and - when `localizer` is non-nil - run each rendered tip through it (pass a
/// plugin's Loc so the translations live in that plugin's catalog). Returns an
/// empty array if the topic file is missing. This is the general entry point;
/// a plugin reaches it via -[KKPlugin helpSectionFromKnowledgeTopic:...].
+ (NSArray<NSString *> *)tipMarkupFromKnowledgeTopic:(NSString *)topicID
                                            inBundle:(NSBundle *)bundle
                                        subdirectory:(nullable NSString *)subdir
                                           localizer:
                                               (nullable NSString * (^)(
                                                   NSString *tip))localizer;

/// Convenience for the kit's own shared timeline docs: loads from the
/// KeyframelessKit bundle (flattened Resources root, like the OSC docs) and
/// localizes via the KKLocalizable table.
+ (NSArray<NSString *> *)localizedTipMarkupFromKnowledgeTopic:(NSString *)topicID;

@end

NS_ASSUME_NONNULL_END
