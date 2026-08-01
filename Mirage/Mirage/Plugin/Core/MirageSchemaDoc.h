/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// The document behind the code editor's "Copy Schema" button: a short preamble
// telling an AI assistant what it is writing, then the directive reference
// VERBATIM from the same AIKnowledge markdown the built-in AI reads, so the two
// vocabularies can never drift, and - on an Option-click - the user's own tabs
// under a marked heading. The preamble is deliberately NOT localized: it is
// prose addressed to a model, and every model in reach reads English better
// than it reads a translation of a technical spec.
//
// Foundation only, and the reference arrives as a URL rather than a bundle
// lookup, so the composition can be exercised outside the plugin.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

static inline NSString *MirageSchemaPreamble(void) {
  return @"You are writing a Mirage template for Final Cut Pro.\n\n"
         @"Mirage is a Final Cut Pro plugin that runs a Shadertoy-style GLSL "
         @"shader live on a clip. You write `void mainImage(out vec4 "
         @"fragColor, in vec2 fragCoord)`, with the usual Shadertoy uniforms "
         @"available: `iResolution`, `iTime`, `iChannel0` (the clip itself, "
         @"gamma-encoded), `iMouse`, `iFrame`. Inspector controls and "
         @"on-screen controls are declared with `// #` comments above the "
         @"uniforms they annotate.\n\n"
         @"Output ONE complete Image shader (the Image tab) with no marker "
         @"line and no commentary wrapped around it - just the GLSL.\n\n"
         @"If the effect genuinely needs multiple passes, output every tab in "
         @"ONE block, each opened by a `// #tab <name>` line on its own - the "
         @"editor splits that blob back into its tabs when the user pastes "
         @"it. The names are `image`, `common`, and `buffer-a` through "
         @"`buffer-d`; anything before the first marker is the Image tab. For "
         @"example:\n\n"
         @"    // #tab common\n"
         @"    float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, "
         @"78.233))) * 43758.5453); }\n"
         @"    // #tab buffer-a\n"
         @"    void mainImage(out vec4 O, in vec2 I) { O = vec4(hash(I), 0.0, "
         @"0.0, 1.0); }\n"
         @"    // #tab image\n"
         @"    void mainImage(out vec4 O, in vec2 I) { O = "
         @"texture(iChannel0, I / iResolution.xy); }\n\n"
         @"Use a marker for EVERY tab you output, including Image, and give "
         @"each pass its own `mainImage`. `// #tab` is an interchange marker "
         @"only: it is stripped on paste and is not one of the `// #` "
         @"directives below.\n\n"
         @"Follow the reference below EXACTLY: only the directives it lists "
         @"exist, only with the attributes it lists, and every Image shader "
         @"must declare exactly one `// #template ...`.\n\n"
         @"---\n\n";
}

/// Where the reference markdown ships in a plugin bundle. Plugin bundles
/// flatten their Resources, so the AIKnowledge subdirectory can be gone at
/// runtime - the flat fallback mirrors the help + AI doc loaders. nil when the
/// bundle carries no copy at all.
static inline NSURL *_Nullable MirageSchemaReferenceURLInBundle(
    NSBundle *bundle) {
  NSURL *url = [bundle URLForResource:@"directives"
                        withExtension:@"md"
                         subdirectory:@"AIKnowledge"];
  return url ?: [bundle URLForResource:@"directives" withExtension:@"md"];
}

/// The reference markdown at `url`, front matter stripped (it addresses the
/// knowledge loader, not the reader). nil when it can't be read.
static inline NSString *_Nullable MirageSchemaReferenceAtURL(
    NSURL *_Nullable url) {
  NSString *raw = url ? [NSString stringWithContentsOfURL:url
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil]
                      : nil;
  if (!raw.length)
    return nil;
  if (![raw hasPrefix:@"---\n"])
    return raw;
  NSRange end = [raw rangeOfString:@"\n---\n"
                           options:0
                             range:NSMakeRange(3, raw.length - 3)];
  return end.location == NSNotFound ? raw
                                    : [raw substringFromIndex:NSMaxRange(end)];
}

/// The `// #tab` marker spelling for a tab name (`Buffer A` -> `buffer-a`).
/// Mirrors the kit's KKCodeTabMarkerSpelling, which is what reads the blob back
/// on paste - kept as a local Foundation-only copy so this document composes
/// without linking the kit. Any spelling resolves on the way back in; the
/// export just has to be consistent.
static inline NSString *MirageSchemaTabMarkerSpelling(NSString *name) {
  NSMutableString *out = [NSMutableString stringWithCapacity:name.length];
  NSString *lower = name.lowercaseString;
  BOOL pendingSeparator = NO;
  for (NSUInteger i = 0; i < lower.length; i++) {
    unichar c = [lower characterAtIndex:i];
    BOOL alnum = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
    if (!alnum) {
      pendingSeparator = out.length > 0;
      continue;
    }
    if (pendingSeparator) {
      [out appendString:@"-"];
      pendingSeparator = NO;
    }
    [out appendFormat:@"%C", c];
  }
  return out;
}

/// Preamble + directive reference, for the clipboard. nil when the reference
/// can't be loaded - the button then no-ops rather than copying a preamble that
/// promises a spec it doesn't carry.
///
/// `sections` (the editor's whole tab set, @{@"name", @"code"}) is appended
/// verbatim under a marked heading when the user Option-clicks, so the model
/// gets the shader it is being asked to change. nil / empty = schema only,
/// which is what the plain click sends.
static inline NSString *_Nullable MirageSchemaDocument(
    NSURL *_Nullable referenceURL,
    NSArray<NSDictionary<NSString *, NSString *> *> *_Nullable sections) {
  NSString *ref = MirageSchemaReferenceAtURL(referenceURL);
  if (!ref.length)
    return nil;
  NSMutableString *doc = [NSMutableString string];
  [doc appendString:MirageSchemaPreamble()];
  [doc appendString:ref];
  if (!sections.count)
    return doc;
  [doc appendString:@"\n\n---\n\n## Current template\n\nThis is the template "
                    @"the user is working on right now, in the same `// #tab` "
                    @"format your answer must use. Keep every `// #` "
                    @"directive it already declares working unless the user "
                    @"asks otherwise, and return whole tabs, not fragments.\n"
                    @"\n"];
  for (NSDictionary<NSString *, NSString *> *section in sections) {
    NSString *name = section[@"name"] ?: @"Image";
    NSString *code = section[@"code"] ?: @"";
    [doc appendFormat:@"// #tab %@\n%@\n", MirageSchemaTabMarkerSpelling(name),
                      code];
  }
  return doc;
}

NS_ASSUME_NONNULL_END
