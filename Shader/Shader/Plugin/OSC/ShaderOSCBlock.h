/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Parsing `// @osc` blocks out of a Custom shader's source into ShaderOSCBlock
// specs - the template-supplied "custom handling" for a primitive OSC. Pure
// string parsing (CLI-testable), no rendering. A block declares a primitive,
// the lane it binds, a glyph style, and the forward (value -> geometry) +
// inverse (geometry -> value) expressions the OSC runtime evaluates via
// KKLinkExpr.
//
//   // @osc Radius
//   //   primitive = point
//   //   binds     = uRadius
//   //   style     = hollow
//   //   toPos     = tr - vec2(uRadius)
//   //   fromPos   = length(tr - pos)
//
// The block lives in `//` comments (like `// #float` directives) so the GLSL
// stays valid; a later dedicated editor tab is just presentation over the same
// syntax. `toPos`/`toRect` -> forward; `fromPos`/`fromRect` -> inverse.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>

#define KK_SHADER_MAX_OSC_BLOCKS 8
#define KK_SHADER_MAX_OSC_LOCALS 12

typedef struct ShaderOSCBlock {
  char name[64];      // OSC display name
  char primitive[16]; // "point" / "box" / "ring" / "rotate"
  char binds[64];     // the bound uniform (lane) name
  char style[16];     // point glyph: "dot" / "square" / "hollow" ("" = default)
  char cursor[16];    // hover cursor: "move" / "crosshair" / "resize-h/v/diag"…
  char forward[256];  // value -> geometry (toPos / toRect)
  // Optional. When empty, a scalar handle's drag NUMERICALLY inverts `forward`
  // (searches the value whose forward-position is nearest the cursor, like
  // Rounded's binary search), so a non-linear forward needs no explicit
  // inverse.
  char inverse[256]; // geometry -> value (fromPos / fromRect)
  // Local variables: any `key = expr` line whose key isn't a reserved field. In
  // declaration order; a local may reference earlier locals (+ the bound value
  // + OSC builtins), so a complex forward reads as a few named steps instead of
  // one duplicated line.
  char localNames[KK_SHADER_MAX_OSC_LOCALS][32];
  char localExprs[KK_SHADER_MAX_OSC_LOCALS][256];
  int localCount;
} ShaderOSCBlock;

static inline void ShaderOSCSetField(char *dst, size_t cap, NSString *src) {
  strncpy(dst, src.UTF8String ?: "", cap - 1);
  dst[cap - 1] = '\0';
}

// Parse every `// @osc` block in `source` into `out` (up to `max`). Returns the
// count. A block starts at a `// @osc <Name>` line and consumes the following
// `//   key = value` comment lines until a non-comment line, a blank comment,
// or the next `// @osc`.
static inline int ShaderParseOSCBlocks(NSString *source, ShaderOSCBlock *out,
                                       int max) {
  if (source.length == 0 || max <= 0)
    return 0;
  NSArray<NSString *> *lines = [source
      componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  int count = 0;
  BOOL inBlock = NO;
  for (NSString *raw in lines) {
    NSString *line = [raw stringByTrimmingCharactersInSet:ws];
    if (![line hasPrefix:@"//"]) {
      inBlock = NO; // a non-comment line ends any open block
      continue;
    }
    // Strip the leading `//` and surrounding space -> the comment's content.
    NSString *body =
        [[line substringFromIndex:2] stringByTrimmingCharactersInSet:ws];

    if ([body hasPrefix:@"@osc"]) {
      if (count >= max)
        break;
      inBlock = YES;
      memset(&out[count], 0, sizeof(out[count]));
      NSString *name =
          [[body substringFromIndex:4] stringByTrimmingCharactersInSet:ws];
      // Allow a trailing "{" on the header line.
      name = [[name stringByReplacingOccurrencesOfString:@"{" withString:@""]
          stringByTrimmingCharactersInSet:ws];
      ShaderOSCSetField(out[count].name, sizeof(out[count].name), name);
      count++;
      continue;
    }
    if (!inBlock)
      continue;
    if (body.length == 0 || [body isEqualToString:@"}"]) {
      inBlock = NO;
      continue;
    }
    // key = value
    NSRange eq = [body rangeOfString:@"="];
    if (eq.location == NSNotFound)
      continue;
    NSString *key = [[body substringToIndex:eq.location]
        stringByTrimmingCharactersInSet:ws];
    NSString *val = [[body substringFromIndex:eq.location + 1]
        stringByTrimmingCharactersInSet:ws];
    ShaderOSCBlock *b = &out[count - 1];
    if ([key isEqualToString:@"primitive"])
      ShaderOSCSetField(b->primitive, sizeof(b->primitive), val);
    else if ([key isEqualToString:@"binds"])
      ShaderOSCSetField(b->binds, sizeof(b->binds), val);
    else if ([key isEqualToString:@"style"])
      ShaderOSCSetField(b->style, sizeof(b->style), val);
    else if ([key isEqualToString:@"cursor"])
      ShaderOSCSetField(b->cursor, sizeof(b->cursor), val);
    else if ([key isEqualToString:@"toPos"] || [key isEqualToString:@"toRect"])
      ShaderOSCSetField(b->forward, sizeof(b->forward), val);
    else if ([key isEqualToString:@"fromPos"] ||
             [key isEqualToString:@"fromRect"])
      ShaderOSCSetField(b->inverse, sizeof(b->inverse), val);
    else if (b->localCount < KK_SHADER_MAX_OSC_LOCALS) {
      // Any other key = a local variable (in order; may use earlier locals).
      int li = b->localCount++;
      ShaderOSCSetField(b->localNames[li], sizeof(b->localNames[li]), key);
      ShaderOSCSetField(b->localExprs[li], sizeof(b->localExprs[li]), val);
    }
  }
  return count;
}

#endif // __METAL_VERSION__
