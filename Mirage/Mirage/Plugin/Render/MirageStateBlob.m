/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageStateBlob.h"

#import "Constants.h"
#import "MirageDirectiveCommon.h" // MirageCommonDefault
#import "MirageLocalCatalog.h"
#import "MirageRack.h"            // the sentinel + per-entry code lane keys

// Bytes before the state samples: the sample count + the motion-blur header.
static const NSUInteger kMirageBlobStatesOffset =
    sizeof(uint32_t) + sizeof(KKMotionBlurState);

// The rack wrapper's first word. Chosen far outside any plausible sample count
// (motion blur asks for a handful), so the leading uint32 alone separates the
// two layouts: a legacy blob opens with that count and can never be this.
static const uint32_t kMirageBlobRackMagic = 0x4B434152; // 'RACK'
static const uint32_t kMirageBlobRackVersion = 1;

static void MirageAppendLenString(NSMutableData *data, NSString *s) {
  NSData *b = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
  uint32_t n = (uint32_t)b.length;
  [data appendBytes:&n length:sizeof(n)];
  [data appendData:b];
}

static void MirageAppendLenData(NSMutableData *data, NSData *bytes) {
  uint32_t n = (uint32_t)bytes.length;
  [data appendBytes:&n length:sizeof(n)];
  if (n)
    [data appendData:bytes];
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
// falls to passthrough and the chosen template only appears after the user
// nudges a param.
//
// `entryID` selects WHICH code lane: the sentinel's key is the bare
// `kMirageCodeLaneLabel` every pre-rack project persisted, so the sentinel path
// through here is byte for byte what it was before the rack existed.
//
// That seed is the SENTINEL's alone. A later rack entry can only exist because
// the registry naming it was persisted, so a missing code lane there is not
// "not written yet", it is an entry with no shader - which renders as
// passthrough (the chain flowing through it), never as a default dropped into
// the middle of someone's chain.
static void MirageAppendCodeSections(NSMutableData *data, KKTimeline *timeline,
                                     NSString *entryID) {
  KKLane *shaderLane =
      MirageRackCodeLaneForEntry(timeline, entryID, kMirageCodeLaneLabel);

  if (shaderLane.codeString.length)
    MirageAppendSection(data, @"Image", shaderLane.codeString);
  else if (!shaderLane && [entryID isEqualToString:kMirageRackSentinelEntryID]) {
    NSDictionary<NSString *, NSString *> *sections =
        MirageDefaultShaderSections();
    for (NSString *name in
         @[ @"Image", @"Common", @"Buffer A", @"Buffer B", @"Buffer C",
            @"Buffer D" ]) {
      NSString *code = sections[name];
      if (code.length)
        MirageAppendSection(data, name, code);
    }
  }

  for (NSDictionary *t in shaderLane.codeTabs) {
    NSString *n =
        [t[@"name"] isKindOfClass:[NSString class]] ? t[@"name"] : nil;
    NSString *c =
        [t[@"code"] isKindOfClass:[NSString class]] ? t[@"code"] : nil;
    if (n.length && c.length)
      MirageAppendSection(data, n, c);
  }
}

// The legacy body, which is ALSO one rack entry's record payload:
// [uint32 sampleCount][KKMotionBlurState][MiragePluginState x n][sections].
// One writer for both, so "the sentinel-only rack emits the pre-rack layout" is
// true by construction rather than by two implementations kept in step.
static void MirageAppendBody(NSMutableData *data,
                             const KKMotionBlurState *mbState,
                             const MiragePluginState *states, uint32_t n,
                             KKTimeline *timeline, NSString *entryID) {
  [data appendBytes:&n length:sizeof(n)];
  [data appendBytes:mbState length:sizeof(KKMotionBlurState)];
  [data appendBytes:states length:n * sizeof(MiragePluginState)];
  MirageAppendCodeSections(data, timeline, entryID);
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

// `body` bounds the walk: for a legacy blob that is the whole data, for a rack
// entry it is that entry's record payload, so the sections tail stops at the
// record's end instead of eating the next entry.
static NSDictionary<NSString *, NSString *> *
MirageParseSections(NSData *data, NSUInteger off, NSUInteger end) {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  const uint8_t *bytes = (const uint8_t *)data.bytes;
  NSUInteger p = off, len = MIN(end, data.length);
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

// One entry's slices of the blob. `valid` NO means the index does not exist or
// the bytes are truncated - every reader then answers its graceful default.
typedef struct MirageBlobRecord {
  NSRange entryID;
  NSRange enabled;
  NSRange body;
  BOOL valid;
} MirageBlobRecord;

static MirageBlobRecord MirageBlobRecordAtIndex(NSData *data, NSInteger index) {
  MirageBlobRecord r;
  memset(&r, 0, sizeof(r));
  NSUInteger len = data.length;
  if (!len || index < 0)
    return r;
  const uint8_t *b = (const uint8_t *)data.bytes;
  uint32_t first = 0;
  if (len >= sizeof(first))
    memcpy(&first, b, sizeof(first));
  if (first != kMirageBlobRackMagic) {
    // Legacy layout: one entry, the whole blob is its body.
    if (index != 0)
      return r;
    r.body = NSMakeRange(0, len);
    r.valid = YES;
    return r;
  }
  if (len < 12)
    return r;
  uint32_t version = 0, count = 0;
  memcpy(&version, b + 4, sizeof(version));
  memcpy(&count, b + 8, sizeof(count));
  if (version != kMirageBlobRackVersion || index >= (NSInteger)count)
    return r;
  NSUInteger p = 12;
  for (uint32_t i = 0; i < count; i++) {
    if (p + 4 > len)
      return r;
    uint32_t recLen = 0;
    memcpy(&recLen, b + p, sizeof(recLen));
    p += 4;
    if (p + recLen > len)
      return r;
    NSUInteger recEnd = p + recLen;
    if ((NSInteger)i != index) {
      p = recEnd;
      continue;
    }
    NSUInteger q = p;
    uint32_t idLen = 0, enLen = 0;
    if (q + 4 > recEnd)
      return r;
    memcpy(&idLen, b + q, sizeof(idLen));
    q += 4;
    if (q + idLen > recEnd)
      return r;
    r.entryID = NSMakeRange(q, idLen);
    q += idLen;
    if (q + 4 > recEnd)
      return r;
    memcpy(&enLen, b + q, sizeof(enLen));
    q += 4;
    if (q + enLen > recEnd)
      return r;
    r.enabled = NSMakeRange(q, enLen);
    q += enLen;
    r.body = NSMakeRange(q, recEnd - q);
    r.valid = YES;
    return r;
  }
  return r;
}

static MirageStateBlobHeader MirageBlobHeaderInBody(NSData *data,
                                                    NSRange body) {
  MirageStateBlobHeader h;
  memset(&h, 0, sizeof(h)); // mbState zeroed = disabled
  h.sampleCount = 1;
  h.base.common = MirageCommonDefault();
  if (body.length < kMirageBlobStatesOffset + sizeof(MiragePluginState))
    return h;
  const uint8_t *bytes = (const uint8_t *)data.bytes + body.location;
  uint32_t n;
  memcpy(&n, bytes, sizeof(n));
  memcpy(&h.mbState, bytes + sizeof(n), sizeof(KKMotionBlurState));
  memcpy(&h.base, bytes + kMirageBlobStatesOffset, sizeof(MiragePluginState));
  h.sampleCount = MAX((NSInteger)n, 1);
  return h;
}

NSData *MirageStateBlobEncode(const KKMotionBlurState *mbState,
                              const MiragePluginState *states,
                              NSInteger sampleCount, KKTimeline *timeline) {
  uint32_t n = (uint32_t)MAX(sampleCount, 1);
  NSMutableData *data = [NSMutableData
      dataWithCapacity:kMirageBlobStatesOffset + n * sizeof(MiragePluginState)];
  MirageAppendBody(data, mbState, states, n, timeline,
                   kMirageRackSentinelEntryID);
  return data;
}

@implementation MirageStateBlobEntry
@end

NSData *MirageStateBlobEncodeRack(const KKMotionBlurState *mbState,
                                  NSArray<MirageStateBlobEntry *> *entries,
                                  KKTimeline *timeline) {
  // A rack of exactly the implicit first entry IS a pre-rack project, so it
  // takes the pre-rack writer and produces the pre-rack bytes. Nothing
  // downstream can tell the two apart, which is the point.
  if (entries.count == 1 &&
      [entries[0].entryID isEqualToString:kMirageRackSentinelEntryID]) {
    MirageStateBlobEntry *e = entries[0];
    NSInteger n = (NSInteger)(e.states.length / sizeof(MiragePluginState));
    if (n >= 1)
      return MirageStateBlobEncode(
          mbState, (const MiragePluginState *)e.states.bytes, n, timeline);
  }
  NSMutableData *data = [NSMutableData data];
  uint32_t magic = kMirageBlobRackMagic, version = kMirageBlobRackVersion,
           count = (uint32_t)entries.count;
  [data appendBytes:&magic length:sizeof(magic)];
  [data appendBytes:&version length:sizeof(version)];
  [data appendBytes:&count length:sizeof(count)];
  for (MirageStateBlobEntry *e in entries) {
    NSMutableData *rec = [NSMutableData data];
    MirageAppendLenString(rec, e.entryID);
    MirageAppendLenData(rec, e.enabled ?: [NSData data]);
    NSInteger n = (NSInteger)(e.states.length / sizeof(MiragePluginState));
    // An entry with no samples still has to occupy its slot (render order is
    // positional), so it contributes one zeroed sample rather than vanishing.
    MiragePluginState zero;
    memset(&zero, 0, sizeof(zero));
    zero.common = MirageCommonDefault();
    MirageAppendBody(rec, mbState,
                     n >= 1 ? (const MiragePluginState *)e.states.bytes : &zero,
                     (uint32_t)MAX(n, (NSInteger)1), timeline, e.entryID);
    uint32_t recLen = (uint32_t)rec.length;
    [data appendBytes:&recLen length:sizeof(recLen)];
    [data appendData:rec];
  }
  return data;
}

MirageStateBlobHeader MirageStateBlobReadHeader(NSData *data) {
  return MirageStateBlobReadHeaderAtIndex(data, 0);
}

BOOL MirageStateBlobReadStates(NSData *data, MiragePluginState *outStates,
                               NSInteger count) {
  return MirageStateBlobReadStatesAtIndex(data, 0, outStates, count);
}

NSDictionary<NSString *, NSString *> *
MirageStateBlobReadSections(NSData *data) {
  return MirageStateBlobReadSectionsAtIndex(data, 0);
}

NSInteger MirageStateBlobEntryCount(NSData *data) {
  NSUInteger len = data.length;
  if (len < 12)
    return 1;
  const uint8_t *b = (const uint8_t *)data.bytes;
  uint32_t first = 0, version = 0, count = 0;
  memcpy(&first, b, sizeof(first));
  if (first != kMirageBlobRackMagic)
    return 1;
  memcpy(&version, b + 4, sizeof(version));
  memcpy(&count, b + 8, sizeof(count));
  if (version != kMirageBlobRackVersion)
    return 1;
  return MAX((NSInteger)count, (NSInteger)1);
}

NSString *MirageStateBlobEntryIDAtIndex(NSData *data, NSInteger index) {
  MirageBlobRecord r = MirageBlobRecordAtIndex(data, index);
  if (!r.valid || r.entryID.length == 0)
    return kMirageRackSentinelEntryID;
  NSString *s = [[NSString alloc]
      initWithBytes:(const uint8_t *)data.bytes + r.entryID.location
             length:r.entryID.length
           encoding:NSUTF8StringEncoding];
  return MirageRackEntryIDOrSentinel(s);
}

BOOL MirageStateBlobEntryEnabled(NSData *data, NSInteger index,
                                 NSInteger sampleIndex) {
  MirageBlobRecord r = MirageBlobRecordAtIndex(data, index);
  if (!r.valid || r.enabled.length == 0)
    return MirageRackEntryEnabledDefault;
  NSInteger i = sampleIndex < 0 ? 0 : sampleIndex;
  if (i >= (NSInteger)r.enabled.length)
    i = (NSInteger)r.enabled.length - 1;
  const uint8_t *b = (const uint8_t *)data.bytes + r.enabled.location;
  return b[i] != 0;
}

MirageStateBlobHeader MirageStateBlobReadHeaderAtIndex(NSData *data,
                                                       NSInteger index) {
  MirageBlobRecord r = MirageBlobRecordAtIndex(data, index);
  if (!r.valid) {
    MirageStateBlobHeader h;
    memset(&h, 0, sizeof(h));
    h.sampleCount = 1;
    h.base.common = MirageCommonDefault();
    return h;
  }
  return MirageBlobHeaderInBody(data, r.body);
}

BOOL MirageStateBlobReadStatesAtIndex(NSData *data, NSInteger index,
                                      MiragePluginState *outStates,
                                      NSInteger count) {
  if (count < 1)
    return NO;
  MirageBlobRecord r = MirageBlobRecordAtIndex(data, index);
  if (!r.valid)
    return NO;
  NSUInteger need =
      kMirageBlobStatesOffset + (NSUInteger)count * sizeof(MiragePluginState);
  if (r.body.length < need)
    return NO;
  [data getBytes:outStates
           range:NSMakeRange(r.body.location + kMirageBlobStatesOffset,
                             (NSUInteger)count * sizeof(MiragePluginState))];
  return YES;
}

NSDictionary<NSString *, NSString *> *
MirageStateBlobReadSectionsAtIndex(NSData *data, NSInteger index) {
  MirageBlobRecord r = MirageBlobRecordAtIndex(data, index);
  if (!r.valid)
    return @{};
  MirageStateBlobHeader h = MirageBlobHeaderInBody(data, r.body);
  NSUInteger off = r.body.location + kMirageBlobStatesOffset +
                   (NSUInteger)h.sampleCount * sizeof(MiragePluginState);
  NSUInteger end = r.body.location + r.body.length;
  if (off >= end)
    return @{};
  return MirageParseSections(data, off, end);
}
