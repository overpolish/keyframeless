/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Parsing `// @osc` blocks out of a Custom shader's source into MirageOSCBlock
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
#import <ctype.h>

#define KK_SHADER_MAX_OSC_BLOCKS 16
#define KK_SHADER_MAX_OSC_LOCALS 32
#define KK_SHADER_MAX_OSC_EXPRESSION_BYTES 2048
#define KK_SHADER_MAX_OSC_LOCAL_NAME_BYTES 64

typedef struct MirageOSCBlock {
  char name[64];      // OSC display name
  char primitive[16]; // "point" / "box" / "ring" / "rotate"
  char binds[64];     // the bound uniform (lane) name
  char style[16];     // point glyph: "dot" / "square" / "hollow" ("" = default)
  char cursor[16];    // hover cursor: "move" / "crosshair" / "resize-h/v/diag"…
  char forward[KK_SHADER_MAX_OSC_EXPRESSION_BYTES];
  // value -> geometry (toPos / toRect / toR)
  // Optional. When empty, a scalar handle's drag NUMERICALLY inverts `forward`
  // (searches the value whose forward-position is nearest the cursor, via a
  // binary search), so a non-linear forward needs no explicit
  // inverse. A ring/box REQUIRES its explicit inverse (fromR / fromRect).
  char inverse[KK_SHADER_MAX_OSC_EXPRESSION_BYTES];
  // geometry -> value (fromPos / fromRect / fromR)
  // Optional placement expression for a centred primitive (ring / rotate):
  // evaluates to an object-space point. Empty = the frame centre. May
  // reference another uniform (`center = uOrigin`) to follow a point lane.
  char center[KK_SHADER_MAX_OSC_EXPRESSION_BYTES];
  // Rotate only: the enabled axis set, e.g. "x y z" / "z". Empty = z.
  char axes[16];
  // Rotate only: a DISPLAY-ONLY angle offset in the lane's degrees, one
  // component per axis in the block's braced `axes` order (a scalar covers a
  // single-axis gizmo). Added to the drawn pose - the rings tilt by
  // `angleOffset + value` while a drag still writes the bound value alone - so
  // a shader that renders `presetAngle + uRotation` can put its preset term
  // here and have the gizmo read in phase with what it draws.
  char angleOffset[KK_SHADER_MAX_OSC_EXPRESSION_BYTES];
  // Ring/box ellipse fields: aspect-link the two components by default
  // (`linked = true`); Shift inverts during a drag.
  int linked;
  // Box only: `body = none` disables the interior body-move part (a CENTRED
  // box has no position to write, so its interior passes through). Default =
  // body-move enabled (the crop feel).
  int bodyDisabled;
  // Point only: `skipsnapping` opts a handle out of the Cmd-held snap (to the
  // canvas centre / edges / quarters + the lane's other keyposes) that every
  // point control gets by default, matching osc=position. Bare flag or
  // `skipsnapping = true`.
  int skipSnapping;
  // Local variables: any `key = expr` line whose key isn't a reserved field. In
  // declaration order; a local may reference earlier locals (+ the bound value
  // + OSC builtins), so a complex forward reads as a few named steps instead of
  // one duplicated line.
  char localNames[KK_SHADER_MAX_OSC_LOCALS][KK_SHADER_MAX_OSC_LOCAL_NAME_BYTES];
  char localExprs[KK_SHADER_MAX_OSC_LOCALS][KK_SHADER_MAX_OSC_EXPRESSION_BYTES];
  int localCount;
} MirageOSCBlock;

/// YES when `b` (nullable) declares the given primitive ("rotate", "position",
/// "ring", "box", "point"). The block model is the RUNTIME authority for a
/// uniform's OSC - consumers query the shader model's block for a uniform
/// instead of re-reading the directive's raw `osc=` parse fields.
static inline BOOL MirageOSCBlockPrimitiveIs(const MirageOSCBlock *b,
                                             const char *primitive) {
  return b != NULL && strcmp(b->primitive, primitive) == 0;
}

static inline BOOL MirageOSCBlockIsRotate(const MirageOSCBlock *b) {
  return MirageOSCBlockPrimitiveIs(b, "rotate");
}

/// Ordered axis chars ('x'/'y'/'z') a rotate block drives, from its
/// space-separated `axes` field, lowercased, in braced order. Empty = the Z
/// default. Returns the count (1-3); `out` receives the chars.
static inline int MirageOSCBlockAxes(const MirageOSCBlock *b, char out[3]) {
  int n = 0;
  for (const char *c = b->axes; *c && n < 3; c++) {
    char lc = (char)tolower(*c);
    if (lc == 'x' || lc == 'y' || lc == 'z')
      out[n++] = lc;
  }
  if (n == 0)
    out[n++] = 'z';
  return n;
}

/// The GLSL swizzle mapping a rotate OSC's CANONICAL-order lane components
/// (packed X<Y<Z into the pool vec4's .xyz) onto the shader vec's braced order
/// (shader component N = the axis listed Nth). E.g. axes "y x" -> "yx",
/// "z x y" -> "zxy", a single axis -> "x".
static inline NSString *MirageOSCBlockRotateSwizzle(const MirageOSCBlock *b) {
  char axes[3];
  int n = MirageOSCBlockAxes(b, axes);
  const char *canon = "xyz";
  NSMutableString *sw = [NSMutableString string];
  for (int i = 0; i < n; i++) {
    char axis = axes[i];
    int pos = 0; // count of present axes that sort before `axis` in X<Y<Z
    for (int a = 0; a < 3; a++) {
      if (canon[a] == axis)
        break;
      for (int k = 0; k < n; k++)
        if (axes[k] == canon[a]) {
          pos++;
          break;
        }
    }
    [sw appendFormat:@"%c", canon[pos]];
  }
  return sw.length ? sw : @"x";
}

static inline void MirageOSCSetField(char *dst, size_t cap, NSString *src) {
  strncpy(dst, src.UTF8String ?: "", cap - 1);
  dst[cap - 1] = '\0';
}

// Parse every `// @osc` block in `source` into `out` (up to `max`). Returns the
// count. A block starts at a `// @osc <Name>` line and consumes the following
// `//   key = value` comment lines until a non-comment line, a blank comment,
// or the next `// @osc`.
static inline int MirageParseOSCBlocks(NSString *source, MirageOSCBlock *out,
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
      MirageOSCSetField(out[count].name, sizeof(out[count].name), name);
      count++;
      continue;
    }
    if (!inBlock)
      continue;
    if (body.length == 0 || [body isEqualToString:@"}"]) {
      inBlock = NO;
      continue;
    }
    // A bare flag line (no `=`): the only one is `skipsnapping`.
    NSRange eq = [body rangeOfString:@"="];
    if (eq.location == NSNotFound) {
      if ([body isEqualToString:@"skipsnapping"])
        out[count - 1].skipSnapping = 1;
      continue;
    }
    NSString *key = [[body substringToIndex:eq.location]
        stringByTrimmingCharactersInSet:ws];
    NSString *val = [[body substringFromIndex:eq.location + 1]
        stringByTrimmingCharactersInSet:ws];
    MirageOSCBlock *b = &out[count - 1];
    if ([key isEqualToString:@"primitive"])
      MirageOSCSetField(b->primitive, sizeof(b->primitive), val);
    else if ([key isEqualToString:@"binds"])
      MirageOSCSetField(b->binds, sizeof(b->binds), val);
    else if ([key isEqualToString:@"style"])
      MirageOSCSetField(b->style, sizeof(b->style), val);
    else if ([key isEqualToString:@"cursor"])
      MirageOSCSetField(b->cursor, sizeof(b->cursor), val);
    else if ([key isEqualToString:@"toPos"] ||
             [key isEqualToString:@"toRect"] || [key isEqualToString:@"toR"])
      MirageOSCSetField(b->forward, sizeof(b->forward), val);
    else if ([key isEqualToString:@"fromPos"] ||
             [key isEqualToString:@"fromRect"] ||
             [key isEqualToString:@"fromR"])
      MirageOSCSetField(b->inverse, sizeof(b->inverse), val);
    else if ([key isEqualToString:@"center"])
      MirageOSCSetField(b->center, sizeof(b->center), val);
    else if ([key isEqualToString:@"axes"])
      MirageOSCSetField(b->axes, sizeof(b->axes), val);
    else if ([key isEqualToString:@"angleOffset"])
      MirageOSCSetField(b->angleOffset, sizeof(b->angleOffset), val);
    else if ([key isEqualToString:@"linked"])
      b->linked = [val isEqualToString:@"true"] ||
                  [val isEqualToString:@"yes"] || [val isEqualToString:@"1"];
    else if ([key isEqualToString:@"body"])
      b->bodyDisabled = [val isEqualToString:@"none"];
    else if ([key isEqualToString:@"skipsnapping"])
      b->skipSnapping = [val isEqualToString:@"true"] ||
                        [val isEqualToString:@"yes"] ||
                        [val isEqualToString:@"1"];
    else if (b->localCount < KK_SHADER_MAX_OSC_LOCALS) {
      // Any other key = a local variable (in order; may use earlier locals).
      int li = b->localCount++;
      MirageOSCSetField(b->localNames[li], sizeof(b->localNames[li]), key);
      MirageOSCSetField(b->localExprs[li], sizeof(b->localExprs[li]), val);
    }
  }
  return count;
}

#endif // __METAL_VERSION__
