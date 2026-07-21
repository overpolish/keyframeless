/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Context-aware autocomplete for a Custom shader's code editor - the single
/// source of truth for the `//` directive + OSC-block vocabulary, wired to
/// `lane.codeCompletionProvider`. Given the full `text` and the caret offset,
/// returns the candidate items (each a `name`/`signature`/`desc`/`insert` dict,
/// the KKCodeEditorView completion shape) filtered to the caret CONTEXT:
///   - a directive kind while typing `// #…` / `// @…`,
///   - a directive's attribute keys (`label=`, `min=`, `osc=`, …),
///   - an `// @osc` block's field keys (`primitive`, `binds`, `toPos`, …),
///   - enum / uniform VALUES right after `key =` (osc=point, style=hollow, a
///     bound uniform name, an OSC expression builtin),
///   - GLSL builtins/types + the shader's own declared uniforms in code.
/// Sets `*outReplaceRange` to the text range an accepted item replaces; returns
/// an empty array (and a NotFound range) when no completion applies.
NSArray<NSDictionary<NSString *, NSString *> *> *
ShaderDirectiveCompletions(NSString *text, NSUInteger caret,
                           NSRange *outReplaceRange);

/// Tidy the `//` directive comments in `source` (run after KKFormatGLSL): a
/// `// #kind …` line's attributes collapse to single spaces (strings
/// preserved), and an `// @osc` block's `key = value` fields re-indent to `//
/// ` with their
/// `=` aligned down the block. Non-directive lines are untouched.
NSString *ShaderTidyDirectives(NSString *source);

NS_ASSUME_NONNULL_END
