/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageDirectiveCatalog.h"

#import "MirageDirectiveVocab.h" // vocabulary tables (shares E / Colored / kVAR)
#import "MirageShaderModel.h"    // `// #gradient` sampler names

// The shader's declared uniform names (`uniform <type> <name>`), for `binds =`
// / `link =` value completion. Array subscripts are stripped.
static NSArray<NSDictionary<NSString *, NSString *> *> *
DeclaredUniforms(NSString *text) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"\\buniform\\s+\\w+\\s+([A-Za-z_]\\w*)"
                             options:0
                               error:nil];
  });
  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  [re enumerateMatchesInString:text
                       options:0
                         range:NSMakeRange(0, text.length)
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f,
                                 BOOL *stop) {
                      NSString *n =
                          [text substringWithRange:[m rangeAtIndex:1]];
                      if ([seen containsObject:n])
                        return;
                      [seen addObject:n];
                      NSMutableDictionary *e =
                          [E(n, n, @"A declared input.", n) mutableCopy];
                      e[@"color"] = kVAR;
                      [out addObject:e];
                    }];
  return out;
}

static BOOL IsIdentChar(unichar c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') || c == '_';
}

// The component count of `base`: an OSC builtin point (2), or its vec2/3/4
// declaration in `text` (2/3/4), else 0 (not a swizzleable vector).
static int VectorSizeForIdentifier(NSString *text, NSString *base) {
  static NSSet<NSString *> *vec2Builtins;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    vec2Builtins = [NSSet setWithArray:@[
      @"mouse", @"pos", @"tr", @"tl", @"bl", @"br", @"center", @"size"
    ]];
  });
  if ([vec2Builtins containsObject:base])
    return 2;
  NSString *pat = [NSString
      stringWithFormat:@"\\b(vec2|vec3|vec4)\\s+%@\\b",
                       [NSRegularExpression escapedPatternForString:base]];
  NSRegularExpression *re =
      [NSRegularExpression regularExpressionWithPattern:pat
                                                options:0
                                                  error:nil];
  NSTextCheckingResult *m = [re firstMatchInString:text
                                           options:0
                                             range:NSMakeRange(0, text.length)];
  if (!m)
    return 0;
  NSString *t = [text substringWithRange:[m rangeAtIndex:1]];
  return [t isEqualToString:@"vec3"] ? 3
                                     : ([t isEqualToString:@"vec4"] ? 4 : 2);
}

// What a `// #gradient` uniform is actually CALLED in shader code. Its declared
// array is stripped by the transpiler and replaced by a sampler, so completing
// the bare name would only ever produce an undeclared-identifier error.
static NSArray<NSDictionary<NSString *, NSString *> *> *
GradientSymbols(NSString *text) {
  MirageShaderModel *model = [MirageShaderModel modelForSource:text];
  const MirageGradientProp *props = model.gradientProps;
  NSMutableArray *out = [NSMutableArray array];
  for (int i = 0; i < model.gradientCount; i++) {
    NSString *nm = @(props[i].name);
    NSString *at = [nm stringByAppendingString:@"At"];
    NSMutableDictionary *fn =
        [E(at, [at stringByAppendingString:@"(t)"],
           @"The ramp's colour at t, from 0 to 1.",
           [at stringByAppendingString:@"("]) mutableCopy];
    fn[@"color"] = kVAR;
    [out addObject:fn];
    NSString *cnt = [nm stringByAppendingString:@"Stops"];
    NSMutableDictionary *n =
        [E(cnt, cnt, @"How many stops the ramp has.", cnt) mutableCopy];
    n[@"color"] = kVAR;
    [out addObject:n];
  }
  return out;
}

// The `// #` directive line just above `base`'s `uniform` declaration, or nil -
// it carries the field names (`fields={…}`) / colour nature for swizzle labels.
static NSString *DirectiveLineForUniform(NSString *text, NSString *base) {
  NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
  NSString *decl = [NSString
      stringWithFormat:@"\\buniform\\s+\\w+\\s+%@\\b",
                       [NSRegularExpression escapedPatternForString:base]];
  NSRegularExpression *re =
      [NSRegularExpression regularExpressionWithPattern:decl
                                                options:0
                                                  error:nil];
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
    if (![re firstMatchInString:lines[i]
                        options:0
                          range:NSMakeRange(0, lines[i].length)])
      continue;
    for (NSInteger j = i - 1; j >= 0; j--) { // nearest `// #` above (blanks ok)
      NSString *t = [lines[j] stringByTrimmingCharactersInSet:ws];
      if (t.length == 0)
        continue;
      if ([t hasPrefix:@"//"]) {
        NSString *b =
            [[t substringFromIndex:2] stringByTrimmingCharactersInSet:ws];
        if ([b hasPrefix:@"#"])
          return b;
      }
      break; // a non-directive line ends the search
    }
    break;
  }
  return nil;
}

// Component completions for `base.` : x/y/z/w sized to the vector, each
// labelled with its field name when a `#multi fields={…}` (or `#color`)
// declares one - so the popup shows what's actually inside. nil when `base`
// isn't a vector.
static NSArray<NSDictionary<NSString *, NSString *> *> *
SwizzleCompletions(NSString *text, NSString *base) {
  int size = VectorSizeForIdentifier(text, base);
  if (size < 2)
    return nil;
  NSString *dir = DirectiveLineForUniform(text, base);
  BOOL isColor = [dir containsString:@"#color"];
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  NSRange f =
      dir ? [dir rangeOfString:@"fields={"] : NSMakeRange(NSNotFound, 0);
  if (f.location != NSNotFound) {
    NSUInteger s = NSMaxRange(f);
    NSRange close = [dir rangeOfString:@"}"
                               options:0
                                 range:NSMakeRange(s, dir.length - s)];
    if (close.location != NSNotFound)
      for (NSString *p in
           [[dir substringWithRange:NSMakeRange(s, close.location - s)]
               componentsSeparatedByString:@","])
        [labels addObject:[p stringByTrimmingCharactersInSet:ws]];
  }
  NSArray<NSString *> *xyzw = @[ @"x", @"y", @"z", @"w" ];
  NSArray<NSString *> *rgba = @[ @"r", @"g", @"b", @"a" ];
  NSArray<NSString *> *rgbaName = @[ @"Red", @"Green", @"Blue", @"Alpha" ];
  NSArray<NSString *> *ord = @[ @"1st", @"2nd", @"3rd", @"4th" ];
  NSMutableArray *out = [NSMutableArray array];
  for (int i = 0; i < size; i++) {
    NSString *label =
        (i < (int)labels.count && labels[i].length)
            ? labels[i]
            : (isColor ? rgbaName[i]
                       : [ord[i] stringByAppendingString:@" component"]);
    [out addObject:E(xyzw[i], xyzw[i], label, xyzw[i])];
  }
  if (isColor)
    for (int i = 0; i < size; i++)
      [out addObject:E(rgba[i], rgba[i], rgbaName[i], rgba[i])];
  NSString *full = [[xyzw subarrayWithRange:NSMakeRange(0, size)]
      componentsJoinedByString:@""];
  [out addObject:E(full, full,
                   [NSString stringWithFormat:@"All %d components.", size],
                   full)];
  return Colored(out, kVAR);
}

// Keep items whose `name` starts with `prefix` (case-insensitive). An empty
// prefix keeps all. Drops the list when the only survivor is already fully
// typed (so the popover closes once you've completed a word).
static NSArray<NSDictionary<NSString *, NSString *> *> *
FilterByPrefix(NSArray<NSDictionary<NSString *, NSString *> *> *items,
               NSString *prefix) {
  if (prefix.length == 0)
    return items;
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary<NSString *, NSString *> *e in items)
    if ([e[@"name"] rangeOfString:prefix
                          options:NSCaseInsensitiveSearch | NSAnchoredSearch]
            .location == 0)
      [out addObject:e];
  if (out.count == 1 &&
      [out[0][@"name"] caseInsensitiveCompare:prefix] == NSOrderedSame)
    return @[];
  return out;
}

// YES when the current line sits inside an open `// @…` block (its indented
// `key = value` fields), scanning up from `lineStart`. Mirrors the block scan
// in MirageParseOSCBlocks: a non-comment line, a blank comment, or a `#`/`@`
// header ends the search.
static BOOL InsideOSCBlock(NSString *text, NSUInteger lineStart) {
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  NSUInteger pos = lineStart;
  while (pos > 0) {
    NSUInteger end = pos - 1; // the '\n' before the current line
    NSUInteger start = end;
    while (start > 0 && [text characterAtIndex:start - 1] != '\n')
      start--;
    NSString *line = [[text substringWithRange:NSMakeRange(start, end - start)]
        stringByTrimmingCharactersInSet:ws];
    if (![line hasPrefix:@"//"])
      return NO;
    NSString *body =
        [[line substringFromIndex:2] stringByTrimmingCharactersInSet:ws];
    if ([body hasPrefix:@"@"])
      return YES; // reached the block header
    if (body.length == 0 || [body hasPrefix:@"#"] ||
        [body isEqualToString:@"}"])
      return NO;
    pos = start; // a `key = value` continuation: keep walking up
  }
  return NO;
}

// The user locals declared ABOVE the current line in the same `@osc` block -
// any `key = value` line whose key isn't a reserved field
// (primitive/binds/style/ cursor/toPos/…). A later line can reference them, so
// they complete: `pad` in `toPos`, `power` in `inset`, etc.
static NSArray<NSDictionary<NSString *, NSString *> *> *
LocalsInOSCBlockAbove(NSString *text, NSUInteger lineStart) {
  static NSSet<NSString *> *reserved;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    reserved = [NSSet setWithArray:@[
      @"primitive", @"binds", @"style", @"cursor", @"topos", @"frompos",
      @"torect", @"fromrect", @"tor", @"fromr", @"center", @"axes", @"linked",
      @"body"
    ]];
  });
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  NSMutableArray *out = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  NSUInteger pos = lineStart;
  while (pos > 0) {
    NSUInteger end = pos - 1, start = end;
    while (start > 0 && [text characterAtIndex:start - 1] != '\n')
      start--;
    NSString *line = [[text substringWithRange:NSMakeRange(start, end - start)]
        stringByTrimmingCharactersInSet:ws];
    if (![line hasPrefix:@"//"])
      break;
    NSString *body =
        [[line substringFromIndex:2] stringByTrimmingCharactersInSet:ws];
    if ([body hasPrefix:@"@"] || [body hasPrefix:@"#"] || body.length == 0 ||
        [body isEqualToString:@"}"])
      break;
    NSRange eq = [body rangeOfString:@"="];
    if (eq.location != NSNotFound) {
      NSString *key = [[body substringToIndex:eq.location]
          stringByTrimmingCharactersInSet:ws];
      if (key.length && ![reserved containsObject:key.lowercaseString] &&
          ![seen containsObject:key]) {
        [seen addObject:key];
        NSMutableDictionary *e =
            [E(key, key, @"A local in this block.", key) mutableCopy];
        e[@"color"] = kVAR;
        [out addObject:e];
      }
    }
    pos = start;
  }
  return out;
}

// Collapse runs of whitespace to a single space, EXCEPT inside a double-quoted
// string (so `label="My Label"` keeps its spaces). Leading/trailing trimmed.
static NSString *CollapseSpacesOutsideQuotes(NSString *s) {
  NSMutableString *out = [NSMutableString string];
  BOOL inQuote = NO, pendingSpace = NO;
  for (NSUInteger i = 0; i < s.length; i++) {
    unichar c = [s characterAtIndex:i];
    if (c == '"')
      inQuote = !inQuote;
    if (!inQuote && (c == ' ' || c == '\t')) {
      pendingSpace = out.length > 0; // no leading space
      continue;
    }
    if (pendingSpace) {
      [out appendString:@" "];
      pendingSpace = NO;
    }
    [out appendFormat:@"%C", c];
  }
  return out;
}

// Is `body` (a comment's text, `//` already stripped) an actual directive
// header rather than ordinary prose that happens to open with `#` or `@`?
// Tidying re-flows a line to column 0 and reshapes the comment lines under it,
// so a `// #1 pass: blur` note inside a function gets dragged to the margin
// where it then LOOKS like a top-level directive.
//
// Two signals, both required:
//
//   1. The leading token is a registered kind - the same set the highlighter
//      greens, so what the editor calls a directive and what Format touches
//      can't disagree. Kills `// #1 pass: blur`.
//   2. What follows is ATTRIBUTE-SHAPED: nothing, `key=…` / `key={…}` pairs,
//      or bare registered flags (`skipsnapping`) and values (`native`). Kills
//      `// #color of the sky is picked here`, which passes (1) - `#color` is a
//      real kind, and the difference between the two is only ever the tail.
//
// Deliberately NOT keyed on indentation: a real directive can be indented (the
// parsers allow leading whitespace), and prose can sit at column 0, so the tail
// is the honest discriminator.
static BOOL IsDirectiveHeader(NSString *body) {
  if (body.length < 2)
    return NO;
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  NSRange sp = [body rangeOfCharacterFromSet:ws];
  NSString *token =
      sp.location == NSNotFound ? body : [body substringToIndex:sp.location];
  if (![MirageDirectiveKindTokens() containsObject:token])
    return NO;
  if (sp.location == NSNotFound)
    return YES; // a bare kind (`#alpha`, `@osc`) has no tail to check
  // Drop quoted runs before tokenising, so `label="My Label"` stays one
  // attribute instead of splitting into `label="My` + a bare `Label"`.
  NSString *tail = [[NSRegularExpression
      regularExpressionWithPattern:@"\"[^\"]*\""
                           options:0
                             error:nil]
      stringByReplacingMatchesInString:body
                               options:0
                                 range:NSMakeRange(sp.location,
                                                   body.length - sp.location)
                          withTemplate:@""];
  for (NSString *raw in [tail componentsSeparatedByCharactersInSet:ws]) {
    NSString *t = [raw stringByTrimmingCharactersInSet:ws];
    if (t.length == 0 || [t containsString:@"="])
      continue;
    if ([MirageDirectiveValueKeywords() containsObject:t] ||
        [MirageDirectiveKindTokens() containsObject:t])
      continue;
    return NO; // a bare word that isn't vocabulary - this is prose
  }
  return YES;
}

NSString *MirageTidyDirectives(NSString *source) {
  if (!source.length)
    return source;
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  NSArray<NSString *> *lines = [source componentsSeparatedByString:@"\n"];
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  NSUInteger i = 0;
  while (i < lines.count) {
    NSString *trimmed = [lines[i] stringByTrimmingCharactersInSet:ws];
    NSString *body = [trimmed hasPrefix:@"//"]
                         ? [[trimmed substringFromIndex:2]
                               stringByTrimmingCharactersInSet:ws]
                         : nil;
    // An `// @osc` block: normalize the header, then gather + align its fields.
    if (body && [body hasPrefix:@"@"] && IsDirectiveHeader(body)) {
      [out
          addObject:[@"// " stringByAppendingString:CollapseSpacesOutsideQuotes(
                                                        body)]];
      NSMutableArray<NSArray<NSString *> *> *fields = [NSMutableArray array];
      NSUInteger j = i + 1;
      for (; j < lines.count; j++) {
        NSString *ft = [lines[j] stringByTrimmingCharactersInSet:ws];
        if (![ft hasPrefix:@"//"])
          break;
        NSString *fb =
            [[ft substringFromIndex:2] stringByTrimmingCharactersInSet:ws];
        if (fb.length == 0 || [fb hasPrefix:@"@"] || [fb hasPrefix:@"#"] ||
            [fb isEqualToString:@"}"])
          break;
        NSRange eq = [fb rangeOfString:@"="];
        if (eq.location == NSNotFound)
          break;
        NSString *key = [[fb substringToIndex:eq.location]
            stringByTrimmingCharactersInSet:ws];
        NSString *val = [[fb substringFromIndex:eq.location + 1]
            stringByTrimmingCharactersInSet:ws];
        [fields addObject:@[ key, val ]];
      }
      NSUInteger maxKey = 0;
      for (NSArray<NSString *> *f in fields)
        maxKey = MAX(maxKey, f[0].length);
      for (NSArray<NSString *> *f in fields) {
        NSString *pad = [@"" stringByPaddingToLength:maxKey - f[0].length
                                          withString:@" "
                                     startingAtIndex:0];
        [out addObject:[NSString stringWithFormat:@"//   %@%@ = %@", f[0], pad,
                                                  f[1]]];
      }
      i = j;
      continue;
    }
    // A `// #kind …` line: single-space its attributes (strings preserved).
    if (body && [body hasPrefix:@"#"] && IsDirectiveHeader(body)) {
      [out
          addObject:[@"// " stringByAppendingString:CollapseSpacesOutsideQuotes(
                                                        body)]];
      i++;
      continue;
    }
    [out addObject:lines[i]]; // untouched
    i++;
  }
  return [out componentsJoinedByString:@"\n"];
}

NSArray<NSDictionary<NSString *, NSString *> *> *
MirageDirectiveCompletions(NSString *text, NSUInteger caret,
                           NSRange *outReplaceRange) {
  *outReplaceRange = NSMakeRange(NSNotFound, 0);
  if (!text.length)
    return @[];
  if (caret > text.length)
    caret = text.length;

  // Line start + the identifier word ending at the caret.
  NSUInteger lineStart = caret;
  while (lineStart > 0 && [text characterAtIndex:lineStart - 1] != '\n')
    lineStart--;
  NSUInteger wordStart = caret;
  while (wordStart > lineStart &&
         IsIdentChar([text characterAtIndex:wordStart - 1]))
    wordStart--;
  NSString *word =
      [text substringWithRange:NSMakeRange(wordStart, caret - wordStart)];

  // Vector swizzle: `ident.<partial>` -> the vector's components (x/y/z/w),
  // labelled from its #multi fields when known. Fires in code AND OSC
  // expressions; after a dot it's swizzle-or-nothing (never GLSL identifiers).
  if (wordStart > 0 && [text characterAtIndex:wordStart - 1] == '.') {
    NSUInteger baseEnd = wordStart - 1, baseStart = baseEnd;
    while (baseStart > 0 && IsIdentChar([text characterAtIndex:baseStart - 1]))
      baseStart--;
    unichar bf = baseStart < baseEnd ? [text characterAtIndex:baseStart] : '.';
    if (baseStart < baseEnd && !(bf >= '0' && bf <= '9')) {
      NSArray *items = SwizzleCompletions(
          text, [text substringWithRange:NSMakeRange(baseStart,
                                                     baseEnd - baseStart)]);
      NSArray *f = FilterByPrefix(items ?: @[], word);
      if (f.count)
        *outReplaceRange = NSMakeRange(wordStart, caret - wordStart);
      return f;
    }
  }

  NSString *linePrefix =
      [text substringWithRange:NSMakeRange(lineStart, caret - lineStart)];
  NSRange slash = [linePrefix rangeOfString:@"//"];

  // --- GLSL code context (no `//` before the caret on this line) ---
  if (slash.location == NSNotFound) {
    if (word.length == 0)
      return @[]; // don't pop on empty word in code
    NSMutableArray *pool = [NSMutableArray arrayWithArray:MirageGLSLIdents()];
    [pool addObjectsFromArray:DeclaredUniforms(text)];
    [pool addObjectsFromArray:GradientSymbols(text)];
    NSArray *items = FilterByPrefix(pool, word);
    if (items.count)
      *outReplaceRange = NSMakeRange(wordStart, caret - wordStart);
    return items;
  }

  // --- Directive comment context ---
  NSUInteger bodyStart = lineStart + NSMaxRange(slash);
  unichar beforeWord =
      wordStart > lineStart ? [text characterAtIndex:wordStart - 1] : 0;

  // (a) Directive KIND: `// #…` / `// @…`, with only whitespace between the
  // `//` and the `#`/`@`, which sits right before the caret word.
  if ((beforeWord == '#' || beforeWord == '@') && wordStart - 1 >= bodyStart) {
    NSString *between = [text
        substringWithRange:NSMakeRange(bodyStart, (wordStart - 1) - bodyStart)];
    if ([between stringByTrimmingCharactersInSet:NSCharacterSet
                                                     .whitespaceCharacterSet]
            .length == 0) {
      NSString *token =
          [text substringWithRange:NSMakeRange(wordStart - 1,
                                               caret - (wordStart - 1))];
      NSArray *items = FilterByPrefix(MirageDirectiveKinds(), token);
      if (items.count)
        *outReplaceRange = NSMakeRange(wordStart - 1, caret - (wordStart - 1));
      return items;
    }
  }

  NSCharacterSet *wsp = NSCharacterSet.whitespaceCharacterSet;
  NSString *beforeWordBody =
      wordStart > bodyStart
          ? [text substringWithRange:NSMakeRange(bodyStart,
                                                 wordStart - bodyStart)]
          : @"";
  NSString *bwTrim = [beforeWordBody stringByTrimmingCharactersInSet:wsp];
  BOOL inBlock = InsideOSCBlock(text, lineStart);
  NSRange firstEq = [beforeWordBody rangeOfString:@"="];
  // Value position: on an `@osc` field line the WHOLE right-hand side is a
  // value (anywhere past the field's `=`), so a mid-expression caret (pad = 0.5
  // + le|) still completes; on a `#kind` line (many key=value pairs) only the
  // token right after a `=` is a value.
  BOOL valuePos =
      inBlock ? (firstEq.location != NSNotFound) : [bwTrim hasSuffix:@"="];

  if (valuePos) {
    // The key names what the value is for: the text before the field's `=` in a
    // block, else the token right before the trailing `=` on a `#kind` line.
    NSString *key;
    if (inBlock) {
      key = [[beforeWordBody substringToIndex:firstEq.location]
          stringByTrimmingCharactersInSet:wsp];
    } else {
      NSString *keyPart = [[bwTrim substringToIndex:bwTrim.length - 1]
          stringByTrimmingCharactersInSet:wsp];
      NSRange sp = [keyPart rangeOfCharacterFromSet:wsp
                                            options:NSBackwardsSearch];
      key = sp.location != NSNotFound
                ? [keyPart substringFromIndex:NSMaxRange(sp)]
                : keyPart;
    }
    NSArray *pool = MirageValueEnumForKey(key);
    NSString *lk = key.lowercaseString;
    if (!pool &&
        ([lk isEqualToString:@"binds"] || [lk isEqualToString:@"link"]))
      pool = DeclaredUniforms(text);
    // Any other value inside an `@osc` block is an expression: toPos / fromPos,
    // and user locals (pad, inset, power…). Offer the OSC builtins + uniforms +
    // the locals declared above this line in the block.
    if (!pool && inBlock) {
      NSMutableArray *m =
          [NSMutableArray arrayWithArray:MirageOSCExprBuiltins()];
      [m addObjectsFromArray:LocalsInOSCBlockAbove(text, lineStart)];
      [m addObjectsFromArray:DeclaredUniforms(text)];
      pool = m;
    }
    if (!pool)
      return @[];
    NSArray *items = FilterByPrefix(pool, word);
    if (items.count)
      *outReplaceRange = NSMakeRange(wordStart, caret - wordStart);
    return items;
  }

  // (c) KEY position: a `#…` directive line offers attribute keys; a line
  // inside an `// @osc` block offers field keys.
  NSString *body =
      [text substringWithRange:NSMakeRange(bodyStart, caret - bodyStart)];
  NSString *bodyTrim = [body stringByTrimmingCharactersInSet:wsp];
  NSArray *pool = nil;
  if ([bodyTrim hasPrefix:@"#"])
    pool = MirageDirectiveAttributeKeys();
  else if (![bodyTrim hasPrefix:@"@"] && inBlock)
    pool = MirageOSCFieldKeys();
  if (!pool)
    return @[];
  NSArray *items = FilterByPrefix(pool, word);
  if (items.count)
    *outReplaceRange = NSMakeRange(wordStart, caret - wordStart);
  return items;
}
