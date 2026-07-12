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
