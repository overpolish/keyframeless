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

/// Re-apply text / sections from an EXTERNAL source (a host timeline change -
/// an undo/redo of a committed edit, a preset load, an AI merge). Unlike
/// `setSections:` / `codeText=`, these are SKIPPED while the user has an
/// uncommitted local typing burst (so a background param echo never clobbers
/// what they're mid-typing) and clear the local undo once applied (the new text
/// is a durable, host-undo-owned state). A no-op when the text already matches.
- (void)applyExternalText:(NSString *)text;
- (void)applyExternalSections:
    (NSArray<NSDictionary<NSString *, NSString *> *> *)sections;

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

/// Optional formatter. When set, a "Format" button appears at the trailing end
/// of the top tab strip; pressing it passes the active section's text through
/// this block and replaces the editor content with the result (or no-ops when
/// the block returns nil / unchanged text). The replacement is a single
/// undoable edit and commits through `onChange` / `onSectionsChange` like a
/// normal edit. Runs on the main thread; keep it reasonably quick.
@property(nonatomic, copy, nullable) NSString *_Nullable (^codeFormatter)
    (NSString *code);

/// When YES, shows a save bar under the editor: a name field + Save button
/// (disabled until a name is entered). Pressing Save posts
/// `KKCodeEditorSaveRequestedNotification` (declared in KKTimingStage.h, the
/// public header, so a plugin host can observe it) with the name + current
/// sections in userInfo. Default NO.
@property(nonatomic) BOOL savable;

/// Optional single-select picker in the save bar, between the name field and
/// Save, wearing the same chrome as a `#choice dropdown` lane. Set the labels a
/// host wants to offer (already localized); nil or empty hides it entirely, so
/// a save bar without one looks exactly as it did before.
///
/// The editor treats these as opaque strings - what they MEAN is the host's
/// business, which is why the save notification reports the picked index rather
/// than trying to name it (see `KKCodeEditorSaveCategoryIndexKey`).
@property(nonatomic, copy, nullable) NSArray<NSString *> *saveCategoryLabels;

/// The picked row, an index into `saveCategoryLabels`. Default 0, so a host
/// that puts its default first gets it for free when the user just hits Save.
/// Out of range reads back as 0.
@property(nonatomic) NSInteger saveCategoryIndex;

@end

NS_ASSUME_NONNULL_END
