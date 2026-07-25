/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Which grammar drives syntax colouring: GLSL (the shader code lane, default)
/// or the parameter-link expression language (KKLinkExpr).
typedef NS_ENUM(NSInteger, KKCodeSyntax) {
  KKCodeSyntaxGLSL = 0,
  KKCodeSyntaxExpression,
};

/// A dumb, self-contained multi-line code editor: a monospaced NSTextView in a
/// scroll view, with the auto-substitutions (smart quotes / dashes / spelling)
/// that would corrupt source turned off, lines that overflow horizontally
/// instead of wrapping, and edits reported (debounced) through `onChange`. Used
/// by the code-lane row (`KKLaneValueTypeCode`) to edit e.g. a shader source.
@interface KKCodeEditorView : NSView

/// Set/replace the editor text without firing `onChange`.
@property(nonatomic, copy) NSString *codeText;

/// Insert `text` at the current caret (replacing any selection) as a single
/// undoable edit, committing through the normal debounce so the host persists
/// it like typed text. Used by the expression editor's reference-insert menu to
/// drop a `${...}` token where the cursor is (appends when the editor isn't
/// focused).
- (void)insertReferenceText:(NSString *)text;

/// Which grammar colours the text. Default `KKCodeSyntaxGLSL`. Set before the
/// first `codeText` so the initial highlight uses the right mode.
@property(nonatomic) KKCodeSyntax syntax;

/// Optional autocomplete provider for GLSL mode (Expression mode uses the
/// built-in KKExprCatalog). Called live on each edit with the full `text` and
/// the caret offset; return the candidate items already FILTERED to the caret
/// context (each a `name`/`signature`/`desc`/`insert` dict, same shape as
/// KKExprCatalog), and set `*outReplaceRange` to the text range the accepted
/// item's `insert` replaces. Return nil/empty for no completion here. This
/// keeps the language vocabulary + context detection in the host (e.g. a
/// shader's `//` directives, GLSL builtins, its own declared uniforms); the
/// editor only shows and inserts what comes back.
@property(nonatomic, copy, nullable)
    NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable (
        ^completionProvider)
        (NSString *text, NSUInteger caret, NSRange *outReplaceRange);

/// Optional link-reference completion for Expression mode: fires while the
/// caret sits inside an unclosed-to-the-left `${...` token, with the partial
/// the user has typed after `${`. Return the candidate items (same
/// `name`/`signature`/`desc`/`insert` shape) already filtered against the
/// partial; the accepted item's `insert` (which must include the closing `}`)
/// replaces from after `${` through the token's closing `}` when the caret is
/// inside an already-complete ref, else up to the caret. nil/empty shows no
/// list. Host-supplied so the kit stays vocabulary-agnostic - the expression
/// popover owns the discovered link sources.
@property(nonatomic, copy, nullable)
    NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable (
        ^linkCompletionProvider)(NSString *partial);

/// VALUE words the directive/`@osc` highlighter paints as keywords (coral) -
/// enum values, booleans, bare flags (`position`, `none`, `true`,
/// `skipsnapping`, …). Host-supplied so the kit stays vocabulary-agnostic; a
/// bare value identifier not in this set stays plain text. nil = none.
@property(nonatomic, copy, nullable) NSSet<NSString *> *directiveKeywords;

/// The valid directive-header tokens (`#float`, `@osc`, ...). When set, the
/// highlighter greens a `// #kind` / `// @block` header ONLY if its token is in
/// this set, so a half-typed or unknown directive (`// #alp`) stays a plain
/// grey comment. Host-supplied so the kit stays vocabulary-agnostic. nil = the
/// old lexical behaviour (green any `// #word` / `// @word`).
@property(nonatomic, copy, nullable) NSSet<NSString *> *directiveKinds;

/// Optional read-only result strip under the editor (styled like the error
/// bar): a host pushes the live computed result of an expression here for
/// clarity. nil/empty hides the strip.
@property(nonatomic, copy, nullable) NSString *resultText;

/// Optional warning for the result strip. Unlike a parser error, the
/// expression is VALID and does produce a value - something about it just needs
/// saying (a `${ref}` that names nothing published, which silently reads 0).
/// Amber, and it ranks between the red error and the dim value readout: the
/// value is still what renders, so the sparkline stays visible beside it.
/// nil = no warning.
@property(nonatomic, copy, nullable) NSString *resultWarningText;

/// Optional inline sparkline drawn at the trailing end of the result strip: the
/// expression sampled across the whole clip (fraction 0->1), so it reads the
/// same in constants and keypose modes regardless of the current playhead.
/// First component only for multi-component lanes. Fewer than 2 samples draws a
/// flat baseline; nil/empty hides the curve (the number keeps the full row).
/// Only visible while `resultText` is showing the strip.
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *sparklineSamples;

/// Where the current playhead sits along `sparklineSamples` (0..1): draws an
/// accent dot on the curve. Negative (the default) hides the dot.
@property(nonatomic) double sparklineMarker;

/// Fired ~0.4s after the last keystroke with the current text (single-section
/// hosts). Tabbed hosts use `onSectionsChange` instead.
@property(nonatomic, copy, nullable) void (^onChange)(NSString *code);

/// Re-apply text from an EXTERNAL source (a host timeline change - an
/// undo/redo of a committed edit, a preset load, an AI merge). SKIPPED while
/// the user has an uncommitted local typing burst (so a background param echo
/// never clobbers what they're mid-typing) and clears the local undo once
/// applied. A no-op when the text already matches. (The sections sibling
/// `applyExternalSections:` lives in the `(Sections)` category below.)
- (void)applyExternalText:(NSString *)text;

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

/// Optional pre-pass that builds the source actually handed to `codeValidator`
/// from the current section set (e.g. a shader prepending a shared "Common"
/// section, or appending a stub entry point when validating that shared section
/// itself). Return the composed source, and set `*outPrependLines` to how many
/// lines were added ABOVE the active section so a reported error line maps back
/// (an error landing in the prepended region is suppressed here - it surfaces
/// on that section's own tab). nil (the default) validates the active section
/// as-is. Keeps language-specific composition in the host, not this editor.
@property(nonatomic, copy, nullable)
    NSString *_Nullable (^validationSourceComposer)
        (NSString *activeSectionName, NSString *activeCode,
         NSArray<NSDictionary<NSString *, NSString *> *> *sections,
         NSInteger *outPrependLines);

/// Optional formatter. When set, a "Format" button appears at the trailing end
/// of the top tab strip; pressing it passes the active section's text through
/// this block and replaces the editor content with the result (or no-ops when
/// the block returns nil / unchanged text). The replacement is a single
/// undoable edit and commits through `onChange` / `onSectionsChange` like a
/// normal edit. Runs on the main thread; keep it reasonably quick.
@property(nonatomic, copy, nullable) NSString *_Nullable (^codeFormatter)
    (NSString *code);

/// Placeholder shown in the save bar's name field. Defaults to a generic
/// "Name"; a host (e.g. a shader preset editor) can set something
/// domain-specific.
@property(nonatomic, copy, null_resettable) NSString *saveNamePlaceholder;

/// The name currently in the save bar's field. A host seeds it from its own
/// storage and reads it back through `onSaveNameChange`, so the name survives
/// the editor being rebuilt (inspector reopen, undo, preset apply).
@property(nonatomic, copy, null_resettable) NSString *saveName;

/// Fired when the user COMMITS a name (blur / Enter), not per keystroke - a
/// host persisting this would otherwise record one undo entry per character.
@property(nonatomic, copy, nullable) void (^onSaveNameChange)(NSString *name);

/// When YES, shows a save bar under the editor: a name field + Save button
/// (disabled until a name is entered). Pressing Save posts
/// `KKCodeEditorSaveRequestedNotification` (declared in KKTimeline.h, the
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

/// Multi-section (tabbed) editing + formatting. Declared as a category because
/// these are implemented in KKCodeEditorView+Sections.m / +Validation.m, not
/// the primary @implementation - keeping them here (vs the main @interface)
/// silences the -Wincomplete-implementation / -Wobjc-protocol-method
/// pair while staying public API.
@interface KKCodeEditorView (Sections)

/// Multi-section (tabbed) editing. Each section is
/// @{ @"name": display, @"code": source }. Setting 2+ sections shows a tab
/// strip above the editor; 0 or 1 leaves the plain single editor unchanged. The
/// active tab's text is what `codeText` reflects and what the validator runs
/// on.
- (void)setSections:(NSArray<NSDictionary<NSString *, NSString *> *> *)sections;

/// The current sections, with the active tab's live edits folded in.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)sections;

/// The sections sibling of `applyExternalText:` - re-apply an external section
/// set (undo/redo, preset, AI merge), skipped mid-typing.
- (void)applyExternalSections:
    (NSArray<NSDictionary<NSString *, NSString *> *> *)sections;

/// Replace the whole content with `formatter(currentText)` as one undoable edit
/// (committing through the normal debounce), or no-op when the block returns
/// nil / unchanged text. Lets a host drive formatting from its own control
/// instead of the built-in `codeFormatter` tab-strip button.
- (void)formatUsing:(NSString *_Nullable (^)(NSString *code))formatter;

@end

NS_ASSUME_NONNULL_END
