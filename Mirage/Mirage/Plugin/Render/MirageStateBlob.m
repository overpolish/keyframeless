/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageStateBlob.h"

#import "Constants.h"        // MirageCustomDefaultShaderSource
#import "MirageDirectives.h" // MirageCommonDefault

// Bytes before the state samples: the sample count + the motion-blur header.
static const NSUInteger kMirageBlobStatesOffset =
    sizeof(uint32_t) + sizeof(KKMotionBlurState);

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

// A present-but-empty codeString means the user explicitly cleared it =>
// passthrough, so nothing is written. An ABSENT code lane is different: the
// timeline blob simply hasn't been persisted yet (a fresh instance writes it
// only on the first param change / UI edit), and the editor already shows the
// catalog default, so seed that same default here - otherwise the first render
// falls to passthrough and the plasma only appears after the user nudges a
// param.
static void MirageAppendCodeSections(NSMutableData *data,
                                     KKTimeline *timeline) {
  KKLane *shaderLane = nil;
  for (KKLane *lane in timeline.lanes)
    if ([lane.key isEqualToString:kMirageCodeLaneLabel]) {
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

static NSDictionary<NSString *, NSString *> *MirageParseSections(NSData *data,
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

NSData *MirageStateBlobEncode(const KKMotionBlurState *mbState,
                              const MiragePluginState *states,
                              NSInteger sampleCount, KKTimeline *timeline) {
  uint32_t n = (uint32_t)MAX(sampleCount, 1);
  NSMutableData *data = [NSMutableData
      dataWithCapacity:kMirageBlobStatesOffset + n * sizeof(MiragePluginState)];
  [data appendBytes:&n length:sizeof(n)];
  [data appendBytes:mbState length:sizeof(KKMotionBlurState)];
  [data appendBytes:states length:n * sizeof(MiragePluginState)];
  MirageAppendCodeSections(data, timeline);
  return data;
}

MirageStateBlobHeader MirageStateBlobReadHeader(NSData *data) {
  MirageStateBlobHeader h;
  memset(&h, 0, sizeof(h)); // mbState zeroed = disabled
  h.sampleCount = 1;
  h.base.common = MirageCommonDefault();
  if (data.length < kMirageBlobStatesOffset + sizeof(MiragePluginState))
    return h;
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  uint32_t n;
  memcpy(&n, bytes, sizeof(n));
  memcpy(&h.mbState, bytes + sizeof(n), sizeof(KKMotionBlurState));
  memcpy(&h.base, bytes + kMirageBlobStatesOffset, sizeof(MiragePluginState));
  h.sampleCount = MAX((NSInteger)n, 1);
  return h;
}

BOOL MirageStateBlobReadStates(NSData *data, MiragePluginState *outStates,
                               NSInteger count) {
  if (count < 1)
    return NO;
  NSUInteger need =
      kMirageBlobStatesOffset + (NSUInteger)count * sizeof(MiragePluginState);
  if (data.length < need)
    return NO;
  [data getBytes:outStates
           range:NSMakeRange(kMirageBlobStatesOffset,
                             (NSUInteger)count * sizeof(MiragePluginState))];
  return YES;
}

NSDictionary<NSString *, NSString *> *MirageStateBlobReadSections(NSData *data) {
  MirageStateBlobHeader h = MirageStateBlobReadHeader(data);
  NSUInteger off = kMirageBlobStatesOffset +
                   (NSUInteger)h.sampleCount * sizeof(MiragePluginState);
  if (data.length <= off)
    return @{};
  return MirageParseSections(data, off);
}
