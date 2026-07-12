/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A dumb, self-contained multi-line code editor: a monospaced NSTextView in a
/// scroll view, with the auto-substitutions (smart quotes / dashes / spelling)
/// that would corrupt source turned off, lines that overflow horizontally
/// instead of wrapping, and edits reported (debounced) through `onChange`. Used
/// by the code-lane row (`KKLaneValueTypeCode`) to edit e.g. a shader source.
@interface KKCodeEditorView : NSView

/// Set/replace the editor text without firing `onChange`.
@property(nonatomic, copy) NSString *codeText;

/// Fired ~0.4s after the last keystroke with the current text (single-section
/// hosts). Tabbed hosts use `onSectionsChange` instead.
@property(nonatomic, copy, nullable) void (^onChange)(NSString *code);

/// Multi-section (tabbed) editing. Each section is
/// @{ @"name": display, @"code": source }. Setting 2+ sections shows a tab
/// strip above the editor; 0 or 1 leaves the plain single editor unchanged. The
/// active tab's text is what `codeText` reflects and what the validator runs
/// on.
- (void)setSections:(NSArray<NSDictionary<NSString *, NSString *> *> *)sections;

/// The current sections, with the active tab's live edits folded in.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)sections;

/// Fired ~0.4s after an edit with the full current section set. Tabbed hosts
/// use this to persist every section (the plain `onChange` fires too, with the
/// active tab's text). Also fires immediately when a tab is added or removed.
@property(nonatomic, copy, nullable) void (^onSectionsChange)
    (NSArray<NSDictionary<NSString *, NSString *> *> *sections);

/// The ordered catalog of EXTRA section names a "+" button offers to add (e.g.
/// @[@"Common", @"Buffer A"]). When non-empty the editor shows a tab strip with
/// the current sections + a "+" menu of the not-yet-added catalog names; added
/// (non-first) tabs get a close button. Empty = no "+" (plain / fixed tabs).
@property(nonatomic, copy, nullable) NSArray<NSString *> *addableTabNames;

/// Optional validator run (debounced) after edits and on first load. Return an
/// error message to surface in a bar under the editor, or nil when the code is
/// valid. Set `*outLine` to the 1-based line to highlight (0 for none). Runs on
/// the main thread; keep it cheap or it will stutter typing.
@property(nonatomic, copy, nullable) NSString *_Nullable (^codeValidator)
    (NSString *code, NSInteger *outLine);

/// When YES, shows a save bar under the editor: a name field + Save button
/// (disabled until a name is entered). Pressing Save posts
/// `KKCodeEditorSaveRequestedNotification` (declared in KKTimingStage.h, the
/// public header, so a plugin host can observe it) with the name + current
/// sections in userInfo. Default NO.
@property(nonatomic) BOOL savable;

@end

NS_ASSUME_NONNULL_END
