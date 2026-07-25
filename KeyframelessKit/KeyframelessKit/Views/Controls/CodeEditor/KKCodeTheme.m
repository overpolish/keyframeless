/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The fixed GitHub-Dark colour palette for the code editor (theme, not
// grammar). Declared in KKGLSLSyntax.h; grammar/tokenizers live there, the
// expression catalog in KKExprCatalog.m.

#import "KKGLSLSyntax.h"

NSColor *KKHex(uint32_t rgb) {
  return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                             green:((rgb >> 8) & 0xff) / 255.0
                              blue:(rgb & 0xff) / 255.0
                             alpha:1.0];
}
NSColor *KKCodeBG(void) { return KKHex(0x0d1117); }
NSColor *KKCodeBorder(void) { return KKHex(0x30363d); }
NSColor *KKCodeText(void) { return KKHex(0xe6edf3); }
NSColor *KKCodeComment(void) { return KKHex(0x8b949e); }
NSColor *KKCodeKeyword(void) { return KKHex(0xff7b72); }
NSColor *KKCodeUniform(void) { return KKHex(0xffa657); }
NSColor *KKCodeFunction(void) { return KKHex(0xd2a8ff); }
NSColor *KKCodeNumber(void) { return KKHex(0x79c0ff); }
NSColor *KKCodeString(void) { return KKHex(0xa5d6ff); }
NSColor *KKCodeDirective(void) { return KKHex(0x7ee787); }
NSColor *KKCodeCursor(void) { return KKHex(0x58a6ff); }
NSColor *KKCodeError(void) { return KKHex(0xf85149); }
NSColor *KKCodeWarning(void) { return KKHex(0xd29922); }
