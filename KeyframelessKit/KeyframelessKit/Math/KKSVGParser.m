/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKSVGParser.h"
#import "KKBezierPath.h"
#import <simd/simd.h>

static const float kEllipseK = 0.5522847498f;

typedef struct {
  float r, g, b;
  BOOL valid;
} KKSVGColor;

typedef struct {
  KKSVGColor fill;
  KKSVGColor stroke;
  float strokeWidth;
  BOOL hasFill;
  BOOL hasStroke;
  BOOL fillNone;
  BOOL strokeNone;
} KKSVGStyle;

static float sRGBToLinear(float c) {
  return (c <= 0.04045f) ? (c / 12.92f) : powf((c + 0.055f) / 1.055f, 2.4f);
}

static KKSVGColor KKSVGColorLinearize(KKSVGColor c) {
  if (!c.valid)
    return c;
  return (KKSVGColor){sRGBToLinear(c.r), sRGBToLinear(c.g), sRGBToLinear(c.b),
                      YES};
}

static KKSVGColor KKSVGColorFromHex(NSString *hex) {
  hex = [hex
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if ([hex hasPrefix:@"#"])
    hex = [hex substringFromIndex:1];

  unsigned int val = 0;
  if (hex.length == 3) {
    NSString *expanded = [NSString
        stringWithFormat:@"%c%c%c%c%c%c", [hex characterAtIndex:0],
                         [hex characterAtIndex:0], [hex characterAtIndex:1],
                         [hex characterAtIndex:1], [hex characterAtIndex:2],
                         [hex characterAtIndex:2]];
    [[NSScanner scannerWithString:expanded] scanHexInt:&val];
  } else if (hex.length == 6) {
    [[NSScanner scannerWithString:hex] scanHexInt:&val];
  } else {
    return (KKSVGColor){0, 0, 0, NO};
  }
  return (KKSVGColor){((val >> 16) & 0xFF) / 255.0f,
                      ((val >> 8) & 0xFF) / 255.0f, (val & 0xFF) / 255.0f, YES};
}

static KKSVGColor KKSVGColorFromRGB(NSString *str) {
  NSScanner *sc = [NSScanner scannerWithString:str];
  [sc scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet]
                     intoString:nil];
  int r = 0, g = 0, b = 0;
  [sc scanInt:&r];
  [sc scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet]
                     intoString:nil];
  [sc scanInt:&g];
  [sc scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet]
                     intoString:nil];
  [sc scanInt:&b];
  return (KKSVGColor){r / 255.0f, g / 255.0f, b / 255.0f, YES};
}

static NSDictionary<NSString *, NSArray<NSNumber *> *> *sNamedColors(void) {
  static NSDictionary *colors;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    colors = @{
      @"black" : @[ @0, @0, @0 ],
      @"white" : @[ @1, @1, @1 ],
      @"red" : @[ @1, @0, @0 ],
      @"green" : @[ @0, @(128.0 / 255.0), @0 ],
      @"blue" : @[ @0, @0, @1 ],
      @"yellow" : @[ @1, @1, @0 ],
      @"cyan" : @[ @0, @1, @1 ],
      @"magenta" : @[ @1, @0, @1 ],
      @"orange" : @[ @1, @(165.0 / 255.0), @0 ],
      @"purple" : @[ @(128.0 / 255.0), @0, @(128.0 / 255.0) ],
      @"gray" : @[ @(128.0 / 255.0), @(128.0 / 255.0), @(128.0 / 255.0) ],
      @"grey" : @[ @(128.0 / 255.0), @(128.0 / 255.0), @(128.0 / 255.0) ],
      @"pink" : @[ @1, @(192.0 / 255.0), @(203.0 / 255.0) ],
      @"brown" : @[ @(165.0 / 255.0), @(42.0 / 255.0), @(42.0 / 255.0) ],
      @"navy" : @[ @0, @0, @(128.0 / 255.0) ],
      @"teal" : @[ @0, @(128.0 / 255.0), @(128.0 / 255.0) ],
      @"lime" : @[ @0, @1, @0 ],
      @"aqua" : @[ @0, @1, @1 ],
      @"maroon" : @[ @(128.0 / 255.0), @0, @0 ],
      @"olive" : @[ @(128.0 / 255.0), @(128.0 / 255.0), @0 ],
      @"silver" : @[ @(192.0 / 255.0), @(192.0 / 255.0), @(192.0 / 255.0) ],
      @"coral" : @[ @1, @(127.0 / 255.0), @(80.0 / 255.0) ],
      @"gold" : @[ @1, @(215.0 / 255.0), @0 ],
    };
  });
  return colors;
}

static KKSVGColor KKSVGParseColor(NSString *str) {
  if (!str || str.length == 0)
    return (KKSVGColor){0, 0, 0, NO};
  str = [str
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  KKSVGColor c = {0, 0, 0, NO};
  if ([str hasPrefix:@"#"])
    c = KKSVGColorFromHex(str);
  else if ([str hasPrefix:@"rgb"])
    c = KKSVGColorFromRGB(str);
  else {
    NSString *lower = str.lowercaseString;
    NSArray<NSNumber *> *named = sNamedColors()[lower];
    if (named)
      c = (KKSVGColor){named[0].floatValue, named[1].floatValue,
                       named[2].floatValue, YES};
  }
  // SVG colors are sRGB — convert to linear for the rendering pipeline
  return KKSVGColorLinearize(c);
}

static KKSVGStyle KKSVGParseStyle(NSDictionary<NSString *, NSString *> *attrs) {
  KKSVGStyle style = {};
  style.strokeWidth = -1;

  NSMutableDictionary<NSString *, NSString *> *merged =
      [NSMutableDictionary dictionary];
  for (NSString *key in attrs)
    merged[key] = attrs[key];

  NSString *cssStyle = attrs[@"style"];
  if (cssStyle) {
    for (NSString *decl in [cssStyle componentsSeparatedByString:@";"]) {
      NSArray *parts = [decl componentsSeparatedByString:@":"];
      if (parts.count == 2) {
        NSString *k = [parts[0]
            stringByTrimmingCharactersInSet:[NSCharacterSet
                                                whitespaceCharacterSet]];
        NSString *v = [parts[1]
            stringByTrimmingCharactersInSet:[NSCharacterSet
                                                whitespaceCharacterSet]];
        merged[k] = v;
      }
    }
  }

  NSString *fillStr = merged[@"fill"];
  if (fillStr) {
    if ([fillStr.lowercaseString isEqualToString:@"none"]) {
      style.fillNone = YES;
      style.hasFill = YES;
    } else if (![fillStr hasPrefix:@"url("]) {
      KKSVGColor c = KKSVGParseColor(fillStr);
      if (c.valid) {
        style.fill = c;
        style.hasFill = YES;
      }
    }
  }

  NSString *strokeStr = merged[@"stroke"];
  if (strokeStr) {
    if ([strokeStr.lowercaseString isEqualToString:@"none"]) {
      style.strokeNone = YES;
      style.hasStroke = YES;
    } else if (![strokeStr hasPrefix:@"url("]) {
      KKSVGColor c = KKSVGParseColor(strokeStr);
      if (c.valid) {
        style.stroke = c;
        style.hasStroke = YES;
      }
    }
  }

  NSString *sw = merged[@"stroke-width"];
  if (sw)
    style.strokeWidth = sw.floatValue;

  return style;
}

static void KKSVGApplyStyle(KKBezierPath *path, KKSVGStyle style) {
  BOOL hasFillColor = style.hasFill && !style.fillNone;
  BOOL hasStrokeColor = style.hasStroke && !style.strokeNone;

  if (style.hasFill) {
    if (style.fillNone) {
      path.fillEnabled = NO;
    } else {
      path.fillEnabled = YES;
      path.fillR = style.fill.r;
      path.fillG = style.fill.g;
      path.fillB = style.fill.b;
    }
  } else {
    // SVG default: fill is black unless explicitly set
    path.fillEnabled = YES;
    path.fillR = 0;
    path.fillG = 0;
    path.fillB = 0;
    hasFillColor = YES;
  }

  if (style.hasStroke) {
    if (style.strokeNone) {
      path.strokeEnabled = NO;
    } else {
      path.strokeEnabled = YES;
      path.strokeR = style.stroke.r;
      path.strokeG = style.stroke.g;
      path.strokeB = style.stroke.b;
    }
  } else {
    // SVG default: no stroke unless explicitly set
    path.strokeEnabled = NO;
    hasStrokeColor = NO;
  }

  if (style.strokeWidth >= 0 && path.strokeEnabled)
    path.strokeWidth = style.strokeWidth;

  // If neither fill nor stroke ended up enabled, fall back to a visible state
  if (!path.fillEnabled && !path.strokeEnabled) {
    if (hasFillColor) {
      path.fillEnabled = YES;
    } else if (hasStrokeColor) {
      path.strokeEnabled = YES;
    } else {
      path.strokeEnabled = YES;
      path.strokeR = 0;
      path.strokeG = 0;
      path.strokeB = 0;
    }
  }
}

typedef struct {
  const unichar *buf;
  NSUInteger len;
  NSUInteger pos;
} KKSVGScanner;

static void svgSkipWS(KKSVGScanner *s) {
  while (s->pos < s->len) {
    unichar c = s->buf[s->pos];
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == ',')
      s->pos++;
    else
      break;
  }
}

static BOOL svgIsCmd(unichar c) {
  return (c == 'M' || c == 'm' || c == 'L' || c == 'l' || c == 'H' ||
          c == 'h' || c == 'V' || c == 'v' || c == 'C' || c == 'c' ||
          c == 'S' || c == 's' || c == 'Q' || c == 'q' || c == 'T' ||
          c == 't' || c == 'A' || c == 'a' || c == 'Z' || c == 'z');
}

static float svgReadFloat(KKSVGScanner *s) {
  svgSkipWS(s);
  if (s->pos >= s->len)
    return 0.0f;
  NSUInteger start = s->pos;
  unichar c = s->buf[s->pos];
  if (c == '-' || c == '+')
    s->pos++;
  BOOL hasDot = NO;
  while (s->pos < s->len) {
    c = s->buf[s->pos];
    if (c >= '0' && c <= '9') {
      s->pos++;
    } else if (c == '.' && !hasDot) {
      hasDot = YES;
      s->pos++;
    } else if ((c == 'e' || c == 'E') && s->pos > start) {
      s->pos++;
      if (s->pos < s->len) {
        c = s->buf[s->pos];
        if (c == '+' || c == '-')
          s->pos++;
      }
      while (s->pos < s->len) {
        c = s->buf[s->pos];
        if (c >= '0' && c <= '9')
          s->pos++;
        else
          break;
      }
      break;
    } else {
      break;
    }
  }
  if (s->pos == start)
    return 0.0f;
  // Fast float parse from unichar buffer
  char tmp[64];
  NSUInteger n = s->pos - start;
  if (n >= sizeof(tmp))
    n = sizeof(tmp) - 1;
  for (NSUInteger i = 0; i < n; i++)
    tmp[i] = (char)s->buf[start + i];
  tmp[n] = '\0';
  return strtof(tmp, NULL);
}

static BOOL svgHasMoreArgs(KKSVGScanner *s) {
  svgSkipWS(s);
  if (s->pos >= s->len)
    return NO;
  unichar c = s->buf[s->pos];
  if (svgIsCmd(c))
    return NO;
  return (c == '-' || c == '+' || c == '.' || (c >= '0' && c <= '9'));
}

@interface KKSVGPathParser : NSObject
+ (NSArray<KKBezierPath *> *)parseD:(NSString *)d;
@end

@implementation KKSVGPathParser

+ (NSArray<KKBezierPath *> *)parseD:(NSString *)d {
  if (!d || d.length == 0)
    return @[];

  NSUInteger len = d.length;
  unichar *buf = malloc(len * sizeof(unichar));
  [d getCharacters:buf range:NSMakeRange(0, len)];
  KKSVGScanner sc = {buf, len, 0};

  KKBezierPath *path = [[KKBezierPath alloc] init];
  unichar cmd = 0;
  float curX = 0, curY = 0;
  float startX = 0, startY = 0;
  float lastCX = 0, lastCY = 0;
  BOOL hasLastCubic = NO;
  BOOL hasLastQuad = NO;
  float lastQX = 0, lastQY = 0;
  BOOL lastWasClose = NO;

  while (sc.pos < len) {
    svgSkipWS(&sc);
    if (sc.pos >= len)
      break;

    unichar c = buf[sc.pos];
    if (svgIsCmd(c)) {
      cmd = c;
      sc.pos++;
      if (cmd == 'Z' || cmd == 'z') {
        path.closed = YES;
        lastWasClose = YES;
        curX = startX;
        curY = startY;
        hasLastCubic = NO;
        hasLastQuad = NO;
        continue;
      }
    }

    if (!cmd)
      break;

    BOOL rel = (cmd >= 'a' && cmd <= 'z');

    switch (cmd) {
    case 'M':
    case 'm': {
      float x = svgReadFloat(&sc);
      float y = svgReadFloat(&sc);
      if (rel) {
        x += curX;
        y += curY;
      }
      curX = x;
      curY = y;
      startX = x;
      startY = y;
      if (lastWasClose && path.count > 0)
        [path beginContour];
      lastWasClose = NO;
      [path insertAtIndex:path.count position:(simd_float2){x, y}];
      hasLastCubic = NO;
      hasLastQuad = NO;
      // Subsequent coordinates after M are treated as L
      cmd = rel ? 'l' : 'L';
      break;
    }
    case 'L':
    case 'l': {
      float x = svgReadFloat(&sc);
      float y = svgReadFloat(&sc);
      if (rel) {
        x += curX;
        y += curY;
      }
      curX = x;
      curY = y;
      [path insertAtIndex:path.count position:(simd_float2){x, y}];
      hasLastCubic = NO;
      hasLastQuad = NO;
      break;
    }
    case 'H':
    case 'h': {
      float x = svgReadFloat(&sc);
      if (rel)
        x += curX;
      curX = x;
      [path insertAtIndex:path.count position:(simd_float2){curX, curY}];
      hasLastCubic = NO;
      hasLastQuad = NO;
      break;
    }
    case 'V':
    case 'v': {
      float y = svgReadFloat(&sc);
      if (rel)
        y += curY;
      curY = y;
      [path insertAtIndex:path.count position:(simd_float2){curX, curY}];
      hasLastCubic = NO;
      hasLastQuad = NO;
      break;
    }
    case 'C':
    case 'c': {
      float x1 = svgReadFloat(&sc), y1 = svgReadFloat(&sc);
      float x2 = svgReadFloat(&sc), y2 = svgReadFloat(&sc);
      float x = svgReadFloat(&sc), y = svgReadFloat(&sc);
      if (rel) {
        x1 += curX;
        y1 += curY;
        x2 += curX;
        y2 += curY;
        x += curX;
        y += curY;
      }
      // Out handle on previous point (relative to that point)
      NSUInteger prevIdx = path.count - 1;
      KKBezierPoint prev = [path pointAtIndex:prevIdx];
      [path setOutHandle:(simd_float2){x1 - prev.x, y1 - prev.y}
                 atIndex:prevIdx];
      [path setType:KKBezierPointBezier atIndex:prevIdx];

      // New point with in-handle
      [path insertAtIndex:path.count position:(simd_float2){x, y}];
      NSUInteger newIdx = path.count - 1;
      [path setInHandle:(simd_float2){x2 - x, y2 - y} atIndex:newIdx];
      [path setType:KKBezierPointBezier atIndex:newIdx];

      lastCX = x2;
      lastCY = y2;
      hasLastCubic = YES;
      hasLastQuad = NO;
      curX = x;
      curY = y;
      break;
    }
    case 'S':
    case 's': {
      float x2 = svgReadFloat(&sc), y2 = svgReadFloat(&sc);
      float x = svgReadFloat(&sc), y = svgReadFloat(&sc);
      if (rel) {
        x2 += curX;
        y2 += curY;
        x += curX;
        y += curY;
      }
      // Reflected control point
      float x1 = hasLastCubic ? (2 * curX - lastCX) : curX;
      float y1 = hasLastCubic ? (2 * curY - lastCY) : curY;

      NSUInteger prevIdx = path.count - 1;
      KKBezierPoint prev = [path pointAtIndex:prevIdx];
      [path setOutHandle:(simd_float2){x1 - prev.x, y1 - prev.y}
                 atIndex:prevIdx];
      [path setType:KKBezierPointBezier atIndex:prevIdx];

      [path insertAtIndex:path.count position:(simd_float2){x, y}];
      NSUInteger newIdx = path.count - 1;
      [path setInHandle:(simd_float2){x2 - x, y2 - y} atIndex:newIdx];
      [path setType:KKBezierPointBezier atIndex:newIdx];

      lastCX = x2;
      lastCY = y2;
      hasLastCubic = YES;
      hasLastQuad = NO;
      curX = x;
      curY = y;
      break;
    }
    case 'Q':
    case 'q': {
      float qx = svgReadFloat(&sc), qy = svgReadFloat(&sc);
      float x = svgReadFloat(&sc), y = svgReadFloat(&sc);
      if (rel) {
        qx += curX;
        qy += curY;
        x += curX;
        y += curY;
      }
      // Convert quadratic to cubic: CP1 = P0 + 2/3*(Q - P0),
      // CP2 = P1 + 2/3*(Q - P1)
      float cp1x = curX + (2.0f / 3.0f) * (qx - curX);
      float cp1y = curY + (2.0f / 3.0f) * (qy - curY);
      float cp2x = x + (2.0f / 3.0f) * (qx - x);
      float cp2y = y + (2.0f / 3.0f) * (qy - y);

      NSUInteger prevIdx = path.count - 1;
      KKBezierPoint prev = [path pointAtIndex:prevIdx];
      [path setOutHandle:(simd_float2){cp1x - prev.x, cp1y - prev.y}
                 atIndex:prevIdx];
      [path setType:KKBezierPointBezier atIndex:prevIdx];

      [path insertAtIndex:path.count position:(simd_float2){x, y}];
      NSUInteger newIdx = path.count - 1;
      [path setInHandle:(simd_float2){cp2x - x, cp2y - y} atIndex:newIdx];
      [path setType:KKBezierPointBezier atIndex:newIdx];

      lastQX = qx;
      lastQY = qy;
      hasLastQuad = YES;
      hasLastCubic = NO;
      curX = x;
      curY = y;
      break;
    }
    case 'T':
    case 't': {
      float x = svgReadFloat(&sc), y = svgReadFloat(&sc);
      if (rel) {
        x += curX;
        y += curY;
      }
      float qx = hasLastQuad ? (2 * curX - lastQX) : curX;
      float qy = hasLastQuad ? (2 * curY - lastQY) : curY;

      float cp1x = curX + (2.0f / 3.0f) * (qx - curX);
      float cp1y = curY + (2.0f / 3.0f) * (qy - curY);
      float cp2x = x + (2.0f / 3.0f) * (qx - x);
      float cp2y = y + (2.0f / 3.0f) * (qy - y);

      NSUInteger prevIdx = path.count - 1;
      KKBezierPoint prev = [path pointAtIndex:prevIdx];
      [path setOutHandle:(simd_float2){cp1x - prev.x, cp1y - prev.y}
                 atIndex:prevIdx];
      [path setType:KKBezierPointBezier atIndex:prevIdx];

      [path insertAtIndex:path.count position:(simd_float2){x, y}];
      NSUInteger newIdx = path.count - 1;
      [path setInHandle:(simd_float2){cp2x - x, cp2y - y} atIndex:newIdx];
      [path setType:KKBezierPointBezier atIndex:newIdx];

      lastQX = qx;
      lastQY = qy;
      hasLastQuad = YES;
      hasLastCubic = NO;
      curX = x;
      curY = y;
      break;
    }
    case 'A':
    case 'a': {
      float rx = svgReadFloat(&sc), ry = svgReadFloat(&sc);
      float rotation = svgReadFloat(&sc);
      float largeArc = svgReadFloat(&sc);
      float sweep = svgReadFloat(&sc);
      float x = svgReadFloat(&sc), y = svgReadFloat(&sc);
      if (rel) {
        x += curX;
        y += curY;
      }
      [self approximateArcFrom:(simd_float2){curX, curY}
                            to:(simd_float2){x, y}
                            rx:rx
                            ry:ry
                      rotation:rotation * M_PI / 180.0f
                      largeArc:(largeArc != 0)
                         sweep:(sweep != 0)
                          path:path];
      curX = x;
      curY = y;
      hasLastCubic = NO;
      hasLastQuad = NO;
      break;
    }
    default:
      sc.pos++;
      break;
    }

    // Handle implicit repeated commands
    if (cmd != 'Z' && cmd != 'z' && svgHasMoreArgs(&sc)) {
      // Don't advance cmd — loop will re-enter with same command
      continue;
    }
  }

  free(buf);

  if (path.count > 0)
    return @[ path ];
  return @[];
}

+ (void)approximateArcFrom:(simd_float2)p1
                        to:(simd_float2)p2
                        rx:(float)rx
                        ry:(float)ry
                  rotation:(float)phi
                  largeArc:(BOOL)largeArc
                     sweep:(BOOL)sweepFlag
                      path:(KKBezierPath *)path {
  if (rx == 0 || ry == 0) {
    [path insertAtIndex:path.count position:p2];
    return;
  }
  rx = fabsf(rx);
  ry = fabsf(ry);

  float cosPhi = cosf(phi), sinPhi = sinf(phi);
  float dx2 = (p1.x - p2.x) / 2.0f, dy2 = (p1.y - p2.y) / 2.0f;
  float x1p = cosPhi * dx2 + sinPhi * dy2;
  float y1p = -sinPhi * dx2 + cosPhi * dy2;

  float x1p2 = x1p * x1p, y1p2 = y1p * y1p;
  float rx2 = rx * rx, ry2 = ry * ry;

  // Correct radii if too small
  float lambda = x1p2 / rx2 + y1p2 / ry2;
  if (lambda > 1.0f) {
    float sqrtL = sqrtf(lambda);
    rx *= sqrtL;
    ry *= sqrtL;
    rx2 = rx * rx;
    ry2 = ry * ry;
  }

  float num = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2;
  float den = rx2 * y1p2 + ry2 * x1p2;
  float sq = (den > 0) ? sqrtf(fmaxf(0, num / den)) : 0;
  if (largeArc == sweepFlag)
    sq = -sq;
  float cxp = sq * rx * y1p / ry;
  float cyp = -sq * ry * x1p / rx;

  float cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2.0f;
  float cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2.0f;

  float theta1 = atan2f((y1p - cyp) / ry, (x1p - cxp) / rx);
  float dtheta = atan2f((-y1p - cyp) / ry, (-x1p - cxp) / rx) - theta1;

  if (sweepFlag && dtheta < 0)
    dtheta += 2 * M_PI;
  else if (!sweepFlag && dtheta > 0)
    dtheta -= 2 * M_PI;

  int segments = (int)ceilf(fabsf(dtheta) / (M_PI / 2.0f));
  if (segments < 1)
    segments = 1;

  float segAngle = dtheta / segments;
  float alpha = sinf(segAngle) *
                (sqrtf(4 + 3 * tanf(segAngle / 2) * tanf(segAngle / 2)) - 1) /
                3.0f;

  float prevX = p1.x, prevY = p1.y;
  float angle = theta1;

  for (int i = 0; i < segments; i++) {
    float nextAngle = angle + segAngle;
    float cosA = cosf(angle), sinA = sinf(angle);
    float cosNA = cosf(nextAngle), sinNA = sinf(nextAngle);

    float ex = cosPhi * rx * cosNA - sinPhi * ry * sinNA + cx;
    float ey = sinPhi * rx * cosNA + cosPhi * ry * sinNA + cy;

    float dx1 = -rx * sinA, dy1 = ry * cosA;
    float cp1x = prevX + alpha * (cosPhi * dx1 - sinPhi * dy1);
    float cp1y = prevY + alpha * (sinPhi * dx1 + cosPhi * dy1);

    float dx2e = -rx * sinNA, dy2e = ry * cosNA;
    float cp2x = ex - alpha * (cosPhi * dx2e - sinPhi * dy2e);
    float cp2y = ey - alpha * (sinPhi * dx2e + cosPhi * dy2e);

    NSUInteger prevIdx = path.count - 1;
    KKBezierPoint prev = [path pointAtIndex:prevIdx];
    [path setOutHandle:(simd_float2){cp1x - prev.x, cp1y - prev.y}
               atIndex:prevIdx];
    [path setType:KKBezierPointBezier atIndex:prevIdx];

    [path insertAtIndex:path.count position:(simd_float2){ex, ey}];
    NSUInteger newIdx = path.count - 1;
    [path setInHandle:(simd_float2){cp2x - ex, cp2y - ey} atIndex:newIdx];
    [path setType:KKBezierPointBezier atIndex:newIdx];

    prevX = ex;
    prevY = ey;
    angle = nextAngle;
  }
}

@end

typedef struct {
  float a, b, c, d, tx, ty;
} KKSVGTransform;

static KKSVGTransform KKSVGTransformIdentity(void) {
  return (KKSVGTransform){1, 0, 0, 1, 0, 0};
}

static KKSVGTransform KKSVGTransformConcat(KKSVGTransform parent,
                                           KKSVGTransform child) {
  return (KKSVGTransform){
      parent.a * child.a + parent.c * child.b,
      parent.b * child.a + parent.d * child.b,
      parent.a * child.c + parent.c * child.d,
      parent.b * child.c + parent.d * child.d,
      parent.a * child.tx + parent.c * child.ty + parent.tx,
      parent.b * child.tx + parent.d * child.ty + parent.ty,
  };
}

static KKSVGTransform KKSVGParseTransform(NSString *str) {
  KKSVGTransform result = KKSVGTransformIdentity();
  if (!str)
    return result;
  NSScanner *sc = [NSScanner scannerWithString:str];
  sc.charactersToBeSkipped = [NSCharacterSet whitespaceAndNewlineCharacterSet];

  while (!sc.isAtEnd) {
    NSString *func = nil;
    [sc scanUpToString:@"(" intoString:&func];
    if (![sc scanString:@"(" intoString:nil])
      break;
    func = [func
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];

    NSString *argsStr = nil;
    [sc scanUpToString:@")" intoString:&argsStr];
    [sc scanString:@")" intoString:nil];

    NSMutableArray<NSNumber *> *args = [NSMutableArray array];
    if (argsStr) {
      NSScanner *aSc = [NSScanner scannerWithString:argsStr];
      aSc.charactersToBeSkipped =
          [NSCharacterSet characterSetWithCharactersInString:@" ,\t\r\n"];
      float v;
      while ([aSc scanFloat:&v])
        [args addObject:@(v)];
    }

    KKSVGTransform t = KKSVGTransformIdentity();
    if ([func isEqualToString:@"translate"]) {
      t.tx = args.count > 0 ? args[0].floatValue : 0;
      t.ty = args.count > 1 ? args[1].floatValue : 0;
    } else if ([func isEqualToString:@"scale"]) {
      t.a = args.count > 0 ? args[0].floatValue : 1;
      t.d = args.count > 1 ? args[1].floatValue : t.a;
    } else if ([func isEqualToString:@"rotate"]) {
      float angle = args.count > 0 ? args[0].floatValue * M_PI / 180.0f : 0;
      float cosA = cosf(angle), sinA = sinf(angle);
      if (args.count >= 3) {
        float cx = args[1].floatValue, cy = args[2].floatValue;
        t = (KKSVGTransform){cosA,
                             sinA,
                             -sinA,
                             cosA,
                             cx - cosA * cx + sinA * cy,
                             cy - sinA * cx - cosA * cy};
      } else {
        t = (KKSVGTransform){cosA, sinA, -sinA, cosA, 0, 0};
      }
    } else if ([func isEqualToString:@"matrix"] && args.count >= 6) {
      t = (KKSVGTransform){args[0].floatValue, args[1].floatValue,
                           args[2].floatValue, args[3].floatValue,
                           args[4].floatValue, args[5].floatValue};
    }
    result = KKSVGTransformConcat(result, t);
  }
  return result;
}

static void KKSVGApplyTransformToPath(KKBezierPath *path, KKSVGTransform t) {
  if (t.a == 1 && t.b == 0 && t.c == 0 && t.d == 1 && t.tx == 0 && t.ty == 0)
    return;
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    float nx = t.a * pt.x + t.c * pt.y + t.tx;
    float ny = t.b * pt.x + t.d * pt.y + t.ty;
    [path moveAtIndex:i to:(simd_float2){nx, ny}];
    if (pt.type == KKBezierPointBezier) {
      // Handles are relative offsets — transform direction only (no translate)
      float ihx = t.a * pt.inX + t.c * pt.inY;
      float ihy = t.b * pt.inX + t.d * pt.inY;
      float ohx = t.a * pt.outX + t.c * pt.outY;
      float ohy = t.b * pt.outX + t.d * pt.outY;
      [path setInHandle:(simd_float2){ihx, ihy} atIndex:i];
      [path setOutHandle:(simd_float2){ohx, ohy} atIndex:i];
    }
  }
}

@interface KKSVGParserDelegate : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<KKBezierPath *> *paths;
@property(nonatomic, strong) NSMutableArray<NSValue *> *transformStack;
@property(nonatomic, strong)
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *styleStack;
@property(nonatomic) float viewBoxWidth;
@property(nonatomic) float viewBoxHeight;
@property(nonatomic) float viewBoxMinX;
@property(nonatomic) float viewBoxMinY;
@property(nonatomic) BOOL hasViewBox;
@end

@implementation KKSVGParserDelegate

- (instancetype)init {
  self = [super init];
  _paths = [NSMutableArray array];
  _transformStack = [NSMutableArray array];
  _styleStack = [NSMutableArray array];
  return self;
}

- (KKSVGTransform)currentTransform {
  if (self.transformStack.count == 0)
    return KKSVGTransformIdentity();
  KKSVGTransform t;
  [self.transformStack.lastObject getValue:&t];
  return t;
}

- (void)pushTransform:(NSString *)transformStr {
  KKSVGTransform parent = [self currentTransform];
  KKSVGTransform local = KKSVGParseTransform(transformStr);
  KKSVGTransform combined = KKSVGTransformConcat(parent, local);
  [self.transformStack
      addObject:[NSValue valueWithBytes:&combined
                               objCType:@encode(KKSVGTransform)]];
}

- (NSDictionary<NSString *, NSString *> *)inheritedStyle {
  if (self.styleStack.count == 0)
    return @{};
  return self.styleStack.lastObject;
}

- (void)pushStyleAttrs:(NSDictionary<NSString *, NSString *> *)attrs {
  NSMutableDictionary *merged = [[self inheritedStyle] mutableCopy];
  NSArray *inheritableKeys = @[
    @"fill", @"stroke", @"stroke-width", @"opacity", @"fill-opacity",
    @"stroke-opacity"
  ];
  for (NSString *key in inheritableKeys) {
    NSString *val = attrs[key];
    if (val)
      merged[key] = val;
  }
  // Also check inline style
  NSString *cssStyle = attrs[@"style"];
  if (cssStyle) {
    for (NSString *decl in [cssStyle componentsSeparatedByString:@";"]) {
      NSArray *parts = [decl componentsSeparatedByString:@":"];
      if (parts.count == 2) {
        NSString *k = [parts[0]
            stringByTrimmingCharactersInSet:[NSCharacterSet
                                                whitespaceCharacterSet]];
        NSString *v = [parts[1]
            stringByTrimmingCharactersInSet:[NSCharacterSet
                                                whitespaceCharacterSet]];
        if ([inheritableKeys containsObject:k])
          merged[k] = v;
      }
    }
  }
  [self.styleStack addObject:[merged copy]];
}

- (NSDictionary<NSString *, NSString *> *)mergedAttrsWithInheritance:
    (NSDictionary<NSString *, NSString *> *)attrs {
  NSDictionary *inherited = [self inheritedStyle];
  if (inherited.count == 0)
    return attrs;
  NSMutableDictionary *merged = [inherited mutableCopy];
  [merged addEntriesFromDictionary:attrs];
  return merged;
}

- (void)parser:(NSXMLParser *)parser
    didStartElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName
         attributes:(NSDictionary<NSString *, NSString *> *)attrs {

  if ([elementName isEqualToString:@"svg"]) {
    NSString *vb = attrs[@"viewBox"];
    if (vb) {
      NSArray *parts =
          [vb componentsSeparatedByCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      NSMutableArray *nums = [NSMutableArray array];
      for (NSString *p in parts) {
        if (p.length > 0)
          [nums addObject:p];
      }
      // Also split by commas
      if (nums.count < 4) {
        nums = [NSMutableArray array];
        for (NSString *p in [vb componentsSeparatedByString:@","]) {
          NSString *trimmed =
              [p stringByTrimmingCharactersInSet:[NSCharacterSet
                                                     whitespaceCharacterSet]];
          if (trimmed.length > 0)
            [nums addObject:trimmed];
        }
      }
      if (nums.count >= 4) {
        self.viewBoxMinX = [nums[0] floatValue];
        self.viewBoxMinY = [nums[1] floatValue];
        self.viewBoxWidth = [nums[2] floatValue];
        self.viewBoxHeight = [nums[3] floatValue];
        self.hasViewBox = YES;
      }
    }
    if (!self.hasViewBox) {
      NSString *w = attrs[@"width"];
      NSString *h = attrs[@"height"];
      if (w && h) {
        self.viewBoxWidth = w.floatValue;
        self.viewBoxHeight = h.floatValue;
        self.hasViewBox = (self.viewBoxWidth > 0 && self.viewBoxHeight > 0);
      }
    }
    return;
  }

  if ([elementName isEqualToString:@"g"]) {
    [self pushTransform:attrs[@"transform"]];
    [self pushStyleAttrs:attrs];
    return;
  }

  // For non-group elements, compute effective transform (group stack + local)
  KKSVGTransform groupT = [self currentTransform];
  KKSVGTransform localT = KKSVGParseTransform(attrs[@"transform"]);
  KKSVGTransform effectiveT = KKSVGTransformConcat(groupT, localT);

  NSDictionary *mergedAttrs = [self mergedAttrsWithInheritance:attrs];
  KKSVGStyle style = KKSVGParseStyle(mergedAttrs);
  NSUInteger countBefore = self.paths.count;

  if ([elementName isEqualToString:@"path"]) {
    NSString *d = attrs[@"d"];
    NSArray<KKBezierPath *> *subpaths = [KKSVGPathParser parseD:d];
    for (KKBezierPath *p in subpaths) {
      KKSVGApplyStyle(p, style);
      [self.paths addObject:p];
    }
  } else if ([elementName isEqualToString:@"rect"]) {
    [self parseRect:attrs style:style];
  } else if ([elementName isEqualToString:@"circle"]) {
    [self parseCircle:attrs style:style];
  } else if ([elementName isEqualToString:@"ellipse"]) {
    [self parseEllipse:attrs style:style];
  } else if ([elementName isEqualToString:@"line"]) {
    [self parseLine:attrs style:style];
  } else if ([elementName isEqualToString:@"polygon"]) {
    [self parsePolygon:attrs style:style closed:YES];
  } else if ([elementName isEqualToString:@"polyline"]) {
    [self parsePolygon:attrs style:style closed:NO];
  }

  // Apply effective transform to any paths added by this element
  for (NSUInteger i = countBefore; i < self.paths.count; i++)
    KKSVGApplyTransformToPath(self.paths[i], effectiveT);
}

- (void)parser:(NSXMLParser *)parser
    didEndElement:(NSString *)elementName
     namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qName {
  if ([elementName isEqualToString:@"g"]) {
    if (self.transformStack.count > 0)
      [self.transformStack removeLastObject];
    if (self.styleStack.count > 0)
      [self.styleStack removeLastObject];
  }
}

- (void)parseRect:(NSDictionary<NSString *, NSString *> *)attrs
            style:(KKSVGStyle)style {
  float x = [attrs[@"x"] floatValue];
  float y = [attrs[@"y"] floatValue];
  float w = [attrs[@"width"] floatValue];
  float h = [attrs[@"height"] floatValue];
  if (w <= 0 || h <= 0)
    return;

  float rx = [attrs[@"rx"] floatValue];
  float ry = [attrs[@"ry"] floatValue];
  if (rx <= 0)
    rx = ry;
  if (ry <= 0)
    ry = rx;
  rx = fminf(rx, w / 2);
  ry = fminf(ry, h / 2);

  KKBezierPath *path = [[KKBezierPath alloc] init];
  path.closed = YES;

  if (rx > 0 && ry > 0) {
    // Rounded rect as bezier path — same arc constant as ellipse
    float kx = rx * kEllipseK, ky = ry * kEllipseK;
    NSUInteger i = 0;
    // Start at top edge after TL corner
    [path insertAtIndex:i position:(simd_float2){x + rx, y}];
    i++;
    // Top-right corner
    [path insertAtIndex:i position:(simd_float2){x + w - rx, y}];
    [path setOutHandle:(simd_float2){kx, 0} atIndex:i];
    [path setType:KKBezierPointBezier atIndex:i];
    i++;
    [path insertAtIndex:i position:(simd_float2){x + w, y + ry}];
    [path setInHandle:(simd_float2){0, -ky} atIndex:i];
    [path setType:KKBezierPointBezier atIndex:i];
    i++;
    // Bottom-right corner
    [path insertAtIndex:i position:(simd_float2){x + w, y + h - ry}];
    [path setOutHandle:(simd_float2){0, ky} atIndex:i];
    [path setType:KKBezierPointBezier atIndex:i];
    i++;
    [path insertAtIndex:i position:(simd_float2){x + w - rx, y + h}];
    [path setInHandle:(simd_float2){kx, 0} atIndex:i];
    [path setType:KKBezierPointBezier atIndex:i];
    i++;
    // Bottom-left corner
    [path insertAtIndex:i position:(simd_float2){x + rx, y + h}];
    [path setOutHandle:(simd_float2){-kx, 0} atIndex:i];
    [path setType:KKBezierPointBezier atIndex:i];
    i++;
    [path insertAtIndex:i position:(simd_float2){x, y + h - ry}];
    [path setInHandle:(simd_float2){0, ky} atIndex:i];
    [path setType:KKBezierPointBezier atIndex:i];
    i++;
    // Top-left corner
    [path insertAtIndex:i position:(simd_float2){x, y + ry}];
    [path setOutHandle:(simd_float2){0, -ky} atIndex:i];
    [path setType:KKBezierPointBezier atIndex:i];
    i++;
    // Close back to start — set in-handle on first point
    [path setInHandle:(simd_float2){-kx, 0} atIndex:0];
    [path setType:KKBezierPointBezier atIndex:0];
  } else {
    // Sharp rect
    [path insertAtIndex:0 position:(simd_float2){x, y}];
    [path insertAtIndex:1 position:(simd_float2){x + w, y}];
    [path insertAtIndex:2 position:(simd_float2){x + w, y + h}];
    [path insertAtIndex:3 position:(simd_float2){x, y + h}];
  }

  KKSVGApplyStyle(path, style);
  [self.paths addObject:path];
}

- (void)parseCircle:(NSDictionary<NSString *, NSString *> *)attrs
              style:(KKSVGStyle)style {
  float cx = [attrs[@"cx"] floatValue];
  float cy = [attrs[@"cy"] floatValue];
  float r = [attrs[@"r"] floatValue];
  if (r <= 0)
    return;
  [self addEllipseCx:cx cy:cy rx:r ry:r style:style];
}

- (void)parseEllipse:(NSDictionary<NSString *, NSString *> *)attrs
               style:(KKSVGStyle)style {
  float cx = [attrs[@"cx"] floatValue];
  float cy = [attrs[@"cy"] floatValue];
  float rx = [attrs[@"rx"] floatValue];
  float ry = [attrs[@"ry"] floatValue];
  if (rx <= 0 || ry <= 0)
    return;
  [self addEllipseCx:cx cy:cy rx:rx ry:ry style:style];
}

- (void)addEllipseCx:(float)cx
                  cy:(float)cy
                  rx:(float)rx
                  ry:(float)ry
               style:(KKSVGStyle)style {
  float kx = rx * kEllipseK, ky = ry * kEllipseK;
  KKBezierPath *path = [[KKBezierPath alloc] init];

  // Top
  [path insertAtIndex:0 position:(simd_float2){cx, cy - ry}];
  [path setOutHandle:(simd_float2){kx, 0} atIndex:0];
  [path setInHandle:(simd_float2){-kx, 0} atIndex:0];
  [path setType:KKBezierPointBezier atIndex:0];

  // Right
  [path insertAtIndex:1 position:(simd_float2){cx + rx, cy}];
  [path setOutHandle:(simd_float2){0, ky} atIndex:1];
  [path setInHandle:(simd_float2){0, -ky} atIndex:1];
  [path setType:KKBezierPointBezier atIndex:1];

  // Bottom
  [path insertAtIndex:2 position:(simd_float2){cx, cy + ry}];
  [path setOutHandle:(simd_float2){-kx, 0} atIndex:2];
  [path setInHandle:(simd_float2){kx, 0} atIndex:2];
  [path setType:KKBezierPointBezier atIndex:2];

  // Left
  [path insertAtIndex:3 position:(simd_float2){cx - rx, cy}];
  [path setOutHandle:(simd_float2){0, -ky} atIndex:3];
  [path setInHandle:(simd_float2){0, ky} atIndex:3];
  [path setType:KKBezierPointBezier atIndex:3];

  path.closed = YES;
  KKSVGApplyStyle(path, style);
  [self.paths addObject:path];
}

- (void)parseLine:(NSDictionary<NSString *, NSString *> *)attrs
            style:(KKSVGStyle)style {
  float x1 = [attrs[@"x1"] floatValue];
  float y1 = [attrs[@"y1"] floatValue];
  float x2 = [attrs[@"x2"] floatValue];
  float y2 = [attrs[@"y2"] floatValue];
  KKBezierPath *path = [[KKBezierPath alloc] init];
  [path insertAtIndex:0 position:(simd_float2){x1, y1}];
  [path insertAtIndex:1 position:(simd_float2){x2, y2}];
  path.closed = NO;
  path.isLine = YES;
  KKSVGApplyStyle(path, style);
  [self.paths addObject:path];
}

- (void)parsePolygon:(NSDictionary<NSString *, NSString *> *)attrs
               style:(KKSVGStyle)style
              closed:(BOOL)closed {
  NSString *points = attrs[@"points"];
  if (!points || points.length == 0)
    return;
  NSScanner *sc = [NSScanner scannerWithString:points];
  sc.charactersToBeSkipped =
      [NSCharacterSet characterSetWithCharactersInString:@" ,\t\r\n"];
  KKBezierPath *path = [[KKBezierPath alloc] init];
  NSUInteger idx = 0;
  while (!sc.isAtEnd) {
    float x = 0, y = 0;
    if (![sc scanFloat:&x])
      break;
    if (![sc scanFloat:&y])
      break;
    [path insertAtIndex:idx position:(simd_float2){x, y}];
    idx++;
  }
  if (path.count < 2)
    return;
  path.closed = closed;
  KKSVGApplyStyle(path, style);
  [self.paths addObject:path];
}

@end

@implementation KKSVGParser

+ (NSArray<KKBezierPath *> *)pathsFromSVGString:(NSString *)svgString
                                    canvasWidth:(float)canvasWidth
                                   canvasHeight:(float)canvasHeight {
  if (!svgString || svgString.length == 0)
    return @[];
  if (canvasWidth < 1)
    canvasWidth = 1;
  if (canvasHeight < 1)
    canvasHeight = 1;

  NSData *data = [svgString dataUsingEncoding:NSUTF8StringEncoding];
  NSXMLParser *xml = [[NSXMLParser alloc] initWithData:data];
  KKSVGParserDelegate *delegate = [[KKSVGParserDelegate alloc] init];
  xml.delegate = delegate;
  [xml parse];

  NSArray<KKBezierPath *> *paths = delegate.paths;
  if (paths.count == 0)
    return @[];

  // Compute bounding box of all paths in SVG space
  float bminX = HUGE_VALF, bminY = HUGE_VALF;
  float bmaxX = -HUGE_VALF, bmaxY = -HUGE_VALF;

  if (delegate.hasViewBox) {
    bminX = delegate.viewBoxMinX;
    bminY = delegate.viewBoxMinY;
    bmaxX = delegate.viewBoxMinX + delegate.viewBoxWidth;
    bmaxY = delegate.viewBoxMinY + delegate.viewBoxHeight;
  } else {
    for (KKBezierPath *p in paths) {
      for (NSUInteger i = 0; i < p.count; i++) {
        KKBezierPoint pt = [p pointAtIndex:i];
        if (pt.x < bminX)
          bminX = pt.x;
        if (pt.y < bminY)
          bminY = pt.y;
        if (pt.x > bmaxX)
          bmaxX = pt.x;
        if (pt.y > bmaxY)
          bmaxY = pt.y;
        if (pt.type == KKBezierPointBezier) {
          float ix = pt.x + pt.inX, iy = pt.y + pt.inY;
          float ox = pt.x + pt.outX, oy = pt.y + pt.outY;
          bminX = fminf(bminX, fminf(ix, ox));
          bminY = fminf(bminY, fminf(iy, oy));
          bmaxX = fmaxf(bmaxX, fmaxf(ix, ox));
          bmaxY = fmaxf(bmaxY, fmaxf(iy, oy));
        }
      }
    }
  }

  float svgW = bmaxX - bminX;
  float svgH = bmaxY - bminY;
  if (svgW < 0.001f || svgH < 0.001f)
    return paths;

  // Fit SVG into canvas pixel space with uniform scale (aspect-correct),
  // then convert to 0-1 object space by dividing by canvas dimensions.
  // This ensures a circle in SVG appears as a circle on screen.
  float pixScale = fminf(canvasWidth / svgW, canvasHeight / svgH);
  float fitW = svgW * pixScale; // fitted size in pixels
  float fitH = svgH * pixScale;
  // Center in canvas pixel space
  float pixOffX = (canvasWidth - fitW) * 0.5f;
  float pixOffY = (canvasHeight - fitH) * 0.5f;

  // Combined transform: SVG -> pixel -> object space (with Y flip)
  // pixel.x = (svg.x - bminX) * pixScale + pixOffX
  // object.x = pixel.x / canvasWidth
  // pixel.y = (svg.y - bminY) * pixScale + pixOffY
  // object.y = 1 - pixel.y / canvasHeight  (Y flip)
  float scaleX = pixScale / canvasWidth;
  float scaleY = pixScale / canvasHeight;
  float offX = -bminX * scaleX + pixOffX / canvasWidth;
  float offY = -bminY * scaleY + pixOffY / canvasHeight;

  for (KKBezierPath *p in paths) {
    for (NSUInteger i = 0; i < p.count; i++) {
      KKBezierPoint pt = [p pointAtIndex:i];
      float nx = pt.x * scaleX + offX;
      float ny = 1.0f - (pt.y * scaleY + offY); // flip Y
      [p moveAtIndex:i to:(simd_float2){nx, ny}];

      if (pt.type == KKBezierPointBezier) {
        // Handles are relative offsets — scale, flip Y
        [p setInHandle:(simd_float2){pt.inX * scaleX, -pt.inY * scaleY}
               atIndex:i];
        [p setOutHandle:(simd_float2){pt.outX * scaleX, -pt.outY * scaleY}
                atIndex:i];
      }
    }

    // Stroke width: scale by the smaller axis to stay proportional
    if (p.strokeEnabled && p.strokeWidth > 0) {
      p.strokeWidth = p.strokeWidth * fminf(scaleX, scaleY);
    }
  }

  return paths;
}

@end
