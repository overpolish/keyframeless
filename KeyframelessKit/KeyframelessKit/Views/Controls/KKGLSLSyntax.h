/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

// GitHub-Dark colour theme for the code editor + GLSL syntax classification,
// shared by KKCodeEditorView and its line-number gutter. Fixed (not appearance-
// adaptive): the editor is a solid dark box regardless of the host inspector's
// light/dark mode, like an embedded code editor.

NSColor *KKHex(uint32_t rgb);
NSColor *KKCodeBG(void);
NSColor *KKCodeBorder(void);
NSColor *KKCodeText(void);
NSColor *KKCodeComment(void);
NSColor *KKCodeKeyword(void);  // coral
NSColor *KKCodeUniform(void);  // orange
NSColor *KKCodeFunction(void); // purple
NSColor *KKCodeNumber(void);   // blue
NSColor *KKCodeCursor(void);
NSColor *KKCodeError(void); // red (error bar / flagged line)

/// One regex matching comments, preprocessor directives, numbers and
/// identifiers (capture groups 1..4 respectively).
NSRegularExpression *KKGLSLTokenizer(void);

/// Colour for an identifier by word only (keywords/types -> coral, built-in
/// shader uniforms -> orange). Returns nil for anything else; the caller then
/// colours it as a function call when it's followed by `(`, else leaves it
/// default.
NSColor *KKGLSLWordColor(NSString *w);

/// One regex for the parameter-link EXPRESSION grammar (KKLinkExpr): capture
/// group 1 a `${ref}`, 2 a number, 3 an identifier.
NSRegularExpression *KKExprTokenizer(void);

/// Colour for an expression identifier: a built-in function (sin, clamp, mix,
/// …)
/// -> purple, a variable/constant (value / t / pi / tau / e) -> coral, else nil
/// (default text).
NSColor *KKExprWordColor(NSString *w);

/// The single source of truth for the parameter-link EXPRESSION vocabulary:
/// every variable and function with its display signature, a one-line
/// description, the category it groups under, and the text to insert at the
/// caret. Drives the editor's browse-and-insert reference menu (and, exported
/// the same way, the AI knowledge). Ordered by category then declaration order.
/// Each entry is a dict:
///   @"name"      short identifier (e.g. "pingpong")
///   @"category"  one of: Variables, Math, Easing, Phase, Vector
///   @"signature" how it reads in the menu (e.g. "pingpong(t, period)")
///   @"desc"      one-line plain-language description
///   @"insert"    text dropped at the caret ("pingpong(" for a call, "t" for a
///   var)
NSArray<NSDictionary<NSString *, NSString *> *> *KKExprCatalog(void);

/// The distinct category names in KKExprCatalog(), in menu order.
NSArray<NSString *> *KKExprCatalogCategories(void);
