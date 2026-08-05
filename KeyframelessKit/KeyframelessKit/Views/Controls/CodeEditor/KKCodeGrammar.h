/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

// A code grammar drives KKCodeEditorView's syntax highlighting: a tokenizer
// plus the per-token colour rule. The editor holds an `id<KKCodeGrammar>` and
// paints through it, so adding a language is a new grammar object, not another
// branch in -_applyHighlighting. Built-ins: KKCodeGrammars.glslGrammar /
// .expressionGrammar. Colours come from KKCodeTheme (KKGLSLSyntax.h).

NS_ASSUME_NONNULL_BEGIN

@protocol KKCodeGrammar <NSObject>

/// The tokenizer whose matches drive per-token colouring.
- (NSRegularExpression *)tokenizer;

/// For one tokenizer `match` in `source`, the colour to paint and the range it
/// applies to (via `outRange`). `declaredIdentifiers` are the source's own
/// declarable names (see -declaredIdentifiersInSource:). Return nil (or an
/// `outRange` of `{NSNotFound, 0}`) to leave the token default-coloured.
- (nullable NSColor *)colorForMatch:(NSTextCheckingResult *)match
                           inSource:(NSString *)source
                declaredIdentifiers:(NSSet<NSString *> *)declaredIdentifiers
                           outRange:(NSRange *)outRange;

/// Identifiers declared IN `source` to paint like built-ins (a GLSL shader's
/// own `uniform` names). Empty set when the grammar has none.
- (NSSet<NSString *> *)declaredIdentifiersInSource:(NSString *)source;

/// YES if `// #kind` / `// @block` directive annotations get the extra overlay
/// pass on top of the comment colour (GLSL yes, expressions no).
@property(nonatomic, readonly) BOOL highlightsDirectives;

@end

/// The built-in grammars (process-lifetime singletons).
@interface KKCodeGrammars : NSObject
@property(class, nonatomic, readonly) id<KKCodeGrammar> glslGrammar;
@property(class, nonatomic, readonly) id<KKCodeGrammar> expressionGrammar;
@end

NS_ASSUME_NONNULL_END
