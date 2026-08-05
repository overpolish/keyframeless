/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// The `// #tab <name>` interchange: one flat blob carrying every tab of a
// multi-section code editor, so an AI assistant can answer a multi-pass
// question in a single paste. Pure text in, pure text out - Foundation only, no
// editor state - so the rules below can be exercised by a scratchpad harness
// without an AppKit host.
//
// This is NOT a directive: it never reaches any language parser, because the
// paste path strips the marker lines before the content lands in a tab.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A tab name reduced to its identity: lowercase, letters and digits only. So
/// `Buffer A`, `buffer-a` and `BUFFER_A` are all the same tab, and a marker can
/// be written however the model felt like writing it.
FOUNDATION_EXPORT NSString *KKCodeTabCanonicalName(NSString *_Nullable name);

/// The name a `// #tab <name>` marker line opens, or nil when `line` is not a
/// marker. The whole line must be the marker (leading whitespace is fine);
/// `#tab` is matched case-insensitively and must be followed by whitespace, so
/// a `// #table ...` comment is ordinary text.
FOUNDATION_EXPORT NSString *_Nullable KKCodeTabMarkerName(NSString *line);

/// Split a pasted blob into per-tab content.
///
/// `knownNames` is every tab name this editor could hold - the sections it has
/// plus the ones its "+" menu offers. The result maps the MATCHED entry of
/// `knownNames` (spelled as that array spells it) to that tab's content.
///
/// Returns nil - meaning "this is not a multi-tab blob, paste it as plain
/// text" - when:
///   - the blob contains no `// #tab` marker at all, or
///   - any marker names something outside `knownNames`. Nothing is silently
///     dropped: an unrecognised tab makes the WHOLE paste ordinary text.
///
/// Rules when it does split:
///   - a marker line opens a section and is itself stripped; the section runs
///     to the next marker or the end of the blob,
///   - content before the first marker belongs to the FIRST entry of
///     `knownNames` (the Image tab), so a model that forgets the opening marker
///     still lands, unless that content is blank,
///   - each section's content is trimmed of leading and trailing whitespace, so
///     two adjacent markers - or markers separated by a blank line - yield an
///     empty tab rather than a stray newline,
///   - a repeated marker for one tab keeps the LAST block,
///   - CRLF input is normalised to LF.
FOUNDATION_EXPORT
NSDictionary<NSString *, NSString *> *_Nullable KKCodeSplitTabbedText(
    NSString *_Nullable text, NSArray<NSString *> *_Nullable knownNames);

/// The marker spelling this convention emits for `name` (`Buffer A` ->
/// `buffer-a`): lowercase, inner runs of non-alphanumerics collapsed to one
/// hyphen. Any spelling round-trips through `KKCodeSplitTabbedText`, but an
/// export should be consistent.
FOUNDATION_EXPORT NSString *KKCodeTabMarkerSpelling(NSString *name);

NS_ASSUME_NONNULL_END
