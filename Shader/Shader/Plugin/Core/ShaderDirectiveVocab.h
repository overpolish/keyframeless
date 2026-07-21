/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import "ShaderLocalized.h" // RLoc - the `desc` help text is user-facing

NS_ASSUME_NONNULL_BEGIN

// The vocabulary tables behind the shader code editor's autocomplete: the `//`
// directive kinds + attribute/field keys, the OSC-expression builtins, and the
// GLSL identifiers - each an item in the KKCodeEditorView completion shape
// (`name`/`signature`/`desc`/`insert`/`color`). Split out of the completion
// ENGINE (ShaderDirectiveCatalog) so the data lives on its own. The small
// `E` / `Colored` / `kVAR` helpers are shared with the engine (which builds its
// own items for declared uniforms, swizzles and block locals).

/// One completion entry. `sig` is the row text, `desc` the footer help (passed
/// as the English source and LOCALIZED here from the ShaderUI table, so every
/// caller gets a translated description for free), `insert` the text dropped at
/// the caret. `name`/`sig`/`insert` are code identifiers and stay literal.
static inline NSDictionary<NSString *, NSString *> *
E(NSString *name, NSString *sig, NSString *desc, NSString *insert) {
  return @{
    @"name" : name,
    @"signature" : sig ?: name,
    @"desc" : desc.length
        ? RLoc(desc, @"Shader code-editor autocomplete: the help line "
                     @"shown for a directive, GLSL or OSC item.")
        : @"",
    @"insert" : insert ?: name
  };
}

/// White (value / variable) colour hint - the engine tags its generated items
/// (declared uniforms, swizzles, block locals) with it, so it lives here beside
/// the vocab's own colours.
static NSString *const kVAR = @"e6edf3";

/// Tag every item with a `color` hex the completion popup reads for its name.
static inline NSArray<NSDictionary<NSString *, NSString *> *> *
Colored(NSArray<NSDictionary<NSString *, NSString *> *> *items, NSString *hex) {
  NSMutableArray *o = [NSMutableArray arrayWithCapacity:items.count];
  for (NSDictionary<NSString *, NSString *> *e in items) {
    NSMutableDictionary *m = [e mutableCopy];
    m[@"color"] = hex;
    [o addObject:m];
  }
  return o;
}

/// `// #…` / `// @…` directive kinds (the token includes its `#`/`@`).
NSArray<NSDictionary<NSString *, NSString *> *> *ShaderDirectiveKinds(void);
/// Attribute keys on a `#…` directive line (`label=`, `min=`, `osc=`, …).
NSArray<NSDictionary<NSString *, NSString *> *> *
ShaderDirectiveAttributeKeys(void);
/// `// @osc` block field keys (`primitive`, `binds`, `toPos`, …).
NSArray<NSDictionary<NSString *, NSString *> *> *ShaderOSCFieldKeys(void);
/// OSC expression builtins available in a `toPos` / `fromPos` value.
NSArray<NSDictionary<NSString *, NSString *> *> *ShaderOSCExprBuiltins(void);
/// The entry point, the plugin's inputs, GLSL types/keywords + built-in fns.
NSArray<NSDictionary<NSString *, NSString *> *> *ShaderGLSLIdents(void);
/// Enum values for a directive attribute / OSC field VALUE by key, or nil.
NSArray<NSDictionary<NSString *, NSString *> *>
    *_Nullable ShaderValueEnumForKey(NSString *key);

NS_ASSUME_NONNULL_END
