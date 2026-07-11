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

/// Fired ~0.4s after the last keystroke with the current text.
@property(nonatomic, copy, nullable) void (^onChange)(NSString *code);

/// Optional validator run (debounced) after edits and on first load. Return an
/// error message to surface in a bar under the editor, or nil when the code is
/// valid. Set `*outLine` to the 1-based line to highlight (0 for none). Runs on
/// the main thread; keep it cheap or it will stutter typing.
@property(nonatomic, copy, nullable) NSString *_Nullable (^codeValidator)
    (NSString *code, NSInteger *outLine);

@end

NS_ASSUME_NONNULL_END
