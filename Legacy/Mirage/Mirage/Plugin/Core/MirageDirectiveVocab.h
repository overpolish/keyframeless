/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import "MirageLocalized.h" // RLoc - the `desc` help text is user-facing

NS_ASSUME_NONNULL_BEGIN

// The vocabulary tables behind the shader code editor's autocomplete: the `//`
// directive kinds + attribute/field keys, the OSC-expression builtins, and the
// GLSL identifiers - each an item in the KKCodeEditorView completion shape
// (`name`/`signature`/`desc`/`insert`/`color`). Split out of the completion
// ENGINE (MirageDirectiveCatalog) so the data lives on its own. The small
// `E` / `Colored` / `kVAR` helpers are shared with the engine (which builds its
// own items for declared uniforms, swizzles and block locals).

/// One completion entry. `sig` is the row text, `desc` the footer help (passed
/// as the English source and LOCALIZED here from the MirageUI table, so every
/// caller gets a translated description for free), `insert` the text dropped at
/// the caret. `name`/`sig`/`insert` are code identifiers and stay literal.
static inline NSDictionary<NSString *, NSString *> *
E(NSString *name, NSString *sig, NSString *desc, NSString *insert) {
  return @{
    @"name" : name,
    @"signature" : sig ?: name,
    @"desc" : desc.length
        ? RLoc(desc, @"Mirage code-editor autocomplete: the help line "
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
NSArray<NSDictionary<NSString *, NSString *> *> *MirageDirectiveKinds(void);

/// The valid directive-header TOKENS (`#float`, `@osc`, ...), derived from
/// MirageDirectiveKinds. Passed to the code editor's `directiveKinds` so it
/// greens only real directives, not any `// #word`.
NSSet<NSString *> *MirageDirectiveKindTokens(void);
/// Attribute keys on a `#…` directive line (`label=`, `min=`, `osc=`, …).
NSArray<NSDictionary<NSString *, NSString *> *> *
MirageDirectiveAttributeKeys(void);
/// `// @osc` block field keys (`primitive`, `binds`, `toPos`, …).
NSArray<NSDictionary<NSString *, NSString *> *> *MirageOSCFieldKeys(void);
/// OSC expression builtins available in a `toPos` / `fromPos` value.
NSArray<NSDictionary<NSString *, NSString *> *> *MirageOSCExprBuiltins(void);
/// The entry point, the plugin's inputs, GLSL types/keywords + built-in fns.
NSArray<NSDictionary<NSString *, NSString *> *> *MirageGLSLIdents(void);
/// Enum values for a directive attribute / OSC field VALUE by key, or nil.
NSArray<NSDictionary<NSString *, NSString *> *>
    *_Nullable MirageValueEnumForKey(NSString *key);
/// Directive/`@osc` VALUE words the editor highlights as keywords (enum values,
/// booleans, bare flags) - passed to the code editor's `directiveKeywords`.
NSSet<NSString *> *MirageDirectiveValueKeywords(void);

/// The `// #motionblur <mode>` modes, with descriptions. A BARE word rather
/// than a `key=value` pair, so the generic value-completion rule (which keys
/// off a trailing `=`) never reaches it and it needs its own table. Also read
/// by the AI authoring path, which learns the directive vocabulary from these
/// tables rather than from the docs.
NSArray<NSDictionary<NSString *, NSString *> *> *MirageMotionBlurModes(void);

/// The four valid bare values after `// #template`.
NSArray<NSDictionary<NSString *, NSString *> *> *MirageTemplateTypes(void);

/// A curated set of SF Symbol names for a `group=`'s icon slot. NOT a
/// whitelist: any symbol macOS knows resolves at runtime, and the parser takes
/// whatever is typed. There is no API to enumerate the ~6,900 installed
/// symbols, and offering all of them would be worse than offering the few
/// dozen that suit a shader control group, so this is a discovery list. Every
/// name here was checked against `imageWithSystemSymbolName:` - see
/// MirageUnknownGroupSymbol for what happens to one that isn't.
NSArray<NSDictionary<NSString *, NSString *> *> *MirageGroupSymbols(void);

NS_ASSUME_NONNULL_END
