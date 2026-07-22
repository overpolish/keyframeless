/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageStateBlob.h"

#import "Constants.h" // MirageCustomDefaultShaderSource

static void MirageAppendLenString(NSMutableData *data, NSString *s) {
  NSData *b = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
  uint32_t n = (uint32_t)b.length;
  [data appendBytes:&n length:sizeof(n)];
  [data appendData:b];
}

static void MirageAppendSection(NSMutableData *data, NSString *name,
                                NSString *code) {
  MirageAppendLenString(data, name);
  MirageAppendLenString(data, code);
}

void MirageAppendCodeSections(NSMutableData *data, KKTimeline *timeline) {
  KKLane *shaderLane = nil;
  for (KKLane *lane in timeline.lanes)
    if ([lane.label isEqualToString:@"Mirage"]) {
      shaderLane = lane;
      break;
    }

  if (shaderLane.codeString.length)
    MirageAppendSection(data, @"Image", shaderLane.codeString);
  else if (!shaderLane)
    MirageAppendSection(data, @"Image", MirageCustomDefaultShaderSource());

  for (NSDictionary *t in shaderLane.codeTabs) {
    NSString *n =
        [t[@"name"] isKindOfClass:[NSString class]] ? t[@"name"] : nil;
    NSString *c =
        [t[@"code"] isKindOfClass:[NSString class]] ? t[@"code"] : nil;
    if (n.length && c.length)
      MirageAppendSection(data, n, c);
  }
}

// One [uint32 len][UTF8 bytes] field at `*p`, advancing it. nil (and leaves
// `*p` unusable) when the field would overrun `len` - the caller stops.
static NSString *MirageReadLenString(const uint8_t *bytes, NSUInteger *p,
                                     NSUInteger len) {
  if (*p + 4 > len)
    return nil;
  uint32_t n;
  memcpy(&n, bytes + *p, 4);
  *p += 4;
  if (*p + n > len)
    return nil;
  NSString *s = [[NSString alloc] initWithBytes:bytes + *p
                                         length:n
                                       encoding:NSUTF8StringEncoding];
  *p += n;
  return s ?: @"";
}

NSDictionary<NSString *, NSString *> *MirageParseSections(NSData *data,
                                                          NSUInteger off) {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger p = off, len = data.length;
  while (p < len) {
    NSString *name = MirageReadLenString(bytes, &p, len);
    if (!name)
      break;
    NSString *code = MirageReadLenString(bytes, &p, len);
    if (!code)
      break;
    if (name.length)
      out[name] = code;
  }
  return out;
}
