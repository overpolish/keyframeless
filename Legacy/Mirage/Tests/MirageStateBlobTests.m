/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

#import "MirageRack.h"
#import "MirageStateBlob.h"

// The one symbol MirageStateBlob.m reaches outside its own file for: the chosen
// default an ABSENT code lane seeds. Defined here rather than dragging in the
// catalog, so the harness exercises the codec's branch on a value it can name.
NSString *const kMirageTestDefaultSource = @"// baked default\n";
NSString *const kMirageTestDefaultCommon = @"// default common\n";
NSString *const kMirageTestDefaultBufferB = @"// default buffer B\n";
NSString *MirageCustomDefaultShaderSource(void) {
  return kMirageTestDefaultSource;
}
NSDictionary<NSString *, NSString *> *MirageDefaultShaderSections(void) {
  return @{
    @"Image" : kMirageTestDefaultSource,
    @"Common" : kMirageTestDefaultCommon,
    @"Buffer B" : kMirageTestDefaultBufferB,
  };
}

static void KKRequire(BOOL condition, NSString *message) {
  if (condition)
    return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

static KKLane *MirageTestCodeLane(NSString *entryID, NSString *image,
                                  NSArray *tabs) {
  KKLane *lane = [KKLane laneWithKey:MirageRackCodeLaneKey(entryID, @"Mirage")
                               label:@"Mirage"];
  lane.codeString = image;
  lane.codeTabs = tabs;
  return lane;
}

static MiragePluginState MirageTestState(float time, int poolCount) {
  MiragePluginState s;
  memset(&s, 0, sizeof(s));
  s.common.time = time;
  s.common.speed = 1.0f;
  s.colorPoolCount = poolCount;
  for (int i = 0; i < poolCount && i < KK_SHADER_COLOR_POOL; i++)
    s.colorPool[i] = (vector_float4){(float)i, time, 0.25f, 1.0f};
  return s;
}

int main(void) {
  @autoreleasepool {
    KKMotionBlurState mb;
    memset(&mb, 0, sizeof(mb));
    mb.enabled = YES;
    mb.sampleCount = 2;

    // --- the sentinel-only rack emits the LEGACY layout, byte for byte -----
    //
    // The claim the whole phase rests on: a project that has never been racked
    // hands the render exactly the bytes it always did. Compared against the
    // pre-rack writer's own output, not against a transcription of it.
    KKTimeline *legacy = [KKTimeline timeline];
    legacy.lanes = @[ MirageTestCodeLane(
        kMirageRackSentinelEntryID, @"void mainImage(){}",
        @[ @{@"name" : @"Common", @"code" : @"float k = 1.0;"} ]) ];
    MiragePluginState states[2] = {MirageTestState(0.0f, 3),
                                   MirageTestState(0.5f, 3)};
    NSData *old = MirageStateBlobEncode(&mb, states, 2, legacy);

    MirageStateBlobEntry *only = [MirageStateBlobEntry new];
    only.entryID = kMirageRackSentinelEntryID;
    only.states = [NSData dataWithBytes:states length:sizeof(states)];
    only.enabled = [NSData dataWithBytes:(const uint8_t[]){1, 1} length:2];
    NSData *racked = MirageStateBlobEncodeRack(&mb, @[ only ], legacy);
    KKRequire([racked isEqualToData:old],
              @"a lone sentinel entry encodes the pre-rack bytes exactly");
    KKRequire(MirageStateBlobEntryCount(old) == 1,
              @"a legacy blob carries one entry");
    KKRequire([MirageStateBlobEntryIDAtIndex(old, 0)
                  isEqualToString:kMirageRackSentinelEntryID],
              @"a legacy blob's only entry is the sentinel");
    KKRequire(MirageStateBlobEntryEnabled(old, 0, 0),
              @"a legacy blob carries no flags and is enabled");

    // Deleting the sentinel from a two-entry rack leaves one MINTED entry.
    // It is still an explicit rack: its scoped source must survive rather than
    // being reinterpreted as the absent sentinel and seeded with Plasma.
    NSString *survivorID = @"c9d2e4";
    KKTimeline *survivorTimeline = [KKTimeline timeline];
    survivorTimeline.slotGroups = @{kMirageRackGroupName : @[ survivorID ]};
    survivorTimeline.lanes = @[
      MirageTestCodeLane(survivorID, @"SURVIVOR IMAGE", @[])
    ];
    MirageStateBlobEntry *survivor = [MirageStateBlobEntry new];
    survivor.entryID = survivorID;
    survivor.states = [NSData dataWithBytes:states length:sizeof(states)];
    survivor.enabled = [NSData dataWithBytes:(const uint8_t[]){1, 1} length:2];
    NSData *survivorBlob =
        MirageStateBlobEncodeRack(&mb, @[ survivor ], survivorTimeline);
    KKRequire([MirageStateBlobEntryIDAtIndex(survivorBlob, 0)
                  isEqualToString:survivorID],
              @"a lone minted survivor retains its rack identity");
    KKRequire([MirageStateBlobReadSectionsAtIndex(survivorBlob, 0)[@"Image"]
                  isEqualToString:@"SURVIVOR IMAGE"],
              @"a lone minted survivor renders its scoped code, not Plasma");

    // An ABSENT code lane seeds every pass of the chosen default, racked or
    // not. This is what lets Magic Move / Frame work as defaults, not only
    // single-pass generators such as Plasma.
    KKTimeline *bare = [KKTimeline timeline];
    NSDictionary *bareSections = MirageStateBlobReadSections(
        MirageStateBlobEncode(&mb, states, 2, bare));
    KKRequire([bareSections[@"Image"]
                  isEqualToString:kMirageTestDefaultSource],
              @"an absent code lane seeds the default Image pass");
    KKRequire([bareSections[@"Common"]
                  isEqualToString:kMirageTestDefaultCommon] &&
                  [bareSections[@"Buffer B"]
                      isEqualToString:kMirageTestDefaultBufferB],
              @"an absent code lane seeds the default's auxiliary passes");

    // ...but only for the SENTINEL. A later entry with no code lane has no
    // shader at all, and must not have a plasma seeded into the middle of
    // someone's chain.
    KKTimeline *halfRack = [KKTimeline timeline];
    halfRack.slotGroups =
        @{kMirageRackGroupName : @[ kMirageRackSentinelEntryID, @"c9d2e4" ]};
    MirageStateBlobEntry *seeded = [MirageStateBlobEntry new];
    seeded.entryID = kMirageRackSentinelEntryID;
    seeded.states = [NSData dataWithBytes:states length:sizeof(states)];
    MirageStateBlobEntry *laneless = [MirageStateBlobEntry new];
    laneless.entryID = @"c9d2e4";
    laneless.states = [NSData dataWithBytes:states length:sizeof(states)];
    NSData *half =
        MirageStateBlobEncodeRack(&mb, @[ seeded, laneless ], halfRack);
    KKRequire([MirageStateBlobReadSectionsAtIndex(half, 0)[@"Image"]
                  isEqualToString:kMirageTestDefaultSource],
              @"the sentinel still seeds the baked default inside a rack");
    KKRequire(MirageStateBlobReadSectionsAtIndex(half, 1).count == 0,
              @"a later entry with no code lane contributes no sections");

    // --- two entries, two sources, two pools ------------------------------
    NSString *entryB = @"7f3a01";
    KKTimeline *rack = [KKTimeline timeline];
    rack.slotGroups =
        @{kMirageRackGroupName : @[ kMirageRackSentinelEntryID, entryB ]};
    rack.lanes = @[
      MirageTestCodeLane(kMirageRackSentinelEntryID, @"IMAGE A",
                         @[ @{@"name" : @"Buffer A", @"code" : @"BUF A"} ]),
      MirageTestCodeLane(entryB, @"IMAGE B",
                         @[ @{@"name" : @"Common", @"code" : @"COMMON B"} ])
    ];

    MiragePluginState aStates[2] = {MirageTestState(1.0f, 4),
                                    MirageTestState(1.25f, 4)};
    MiragePluginState bStates[2] = {MirageTestState(9.0f, 7),
                                    MirageTestState(9.5f, 7)};
    MirageStateBlobEntry *a = [MirageStateBlobEntry new];
    a.entryID = kMirageRackSentinelEntryID;
    a.states = [NSData dataWithBytes:aStates length:sizeof(aStates)];
    a.enabled = [NSData dataWithBytes:(const uint8_t[]){1, 1} length:2];
    MirageStateBlobEntry *b = [MirageStateBlobEntry new];
    b.entryID = entryB;
    b.states = [NSData dataWithBytes:bStates length:sizeof(bStates)];
    // Sample 0 on, sample 1 off: the per-sample flag has to survive the trip
    // even though the chain's shape is decided at sample 0.
    b.enabled = [NSData dataWithBytes:(const uint8_t[]){1, 0} length:2];
    NSData *chain = MirageStateBlobEncodeRack(&mb, @[ a, b ], rack);

    KKRequire(MirageStateBlobEntryCount(chain) == 2, @"two entries encoded");
    KKRequire(
        [MirageStateBlobEntryIDAtIndex(chain, 0)
            isEqualToString:kMirageRackSentinelEntryID] &&
            [MirageStateBlobEntryIDAtIndex(chain, 1) isEqualToString:entryB],
        @"entry ids round-trip in render order");

    // Sections are per entry, and the unindexed reader still answers entry 0 -
    // which is what keeps every caller that predates the rack correct.
    NSDictionary *secA = MirageStateBlobReadSectionsAtIndex(chain, 0);
    NSDictionary *secB = MirageStateBlobReadSectionsAtIndex(chain, 1);
    KKRequire([secA[@"Image"] isEqualToString:@"IMAGE A"] &&
                  [secA[@"Buffer A"] isEqualToString:@"BUF A"] &&
                  secA[@"Common"] == nil,
              @"entry 0's sections are its own");
    KKRequire([secB[@"Image"] isEqualToString:@"IMAGE B"] &&
                  [secB[@"Common"] isEqualToString:@"COMMON B"] &&
                  secB[@"Buffer A"] == nil,
              @"entry 1's sections are its own");
    KKRequire([MirageStateBlobReadSections(chain)[@"Image"]
                  isEqualToString:@"IMAGE A"],
              @"the unindexed sections reader answers entry 0");

    // Headers + full sample sets, per entry.
    MirageStateBlobHeader hA = MirageStateBlobReadHeaderAtIndex(chain, 0);
    MirageStateBlobHeader hB = MirageStateBlobReadHeaderAtIndex(chain, 1);
    KKRequire(hA.sampleCount == 2 && hB.sampleCount == 2,
              @"both entries carry the frame's sample count");
    KKRequire(hA.mbState.enabled && hB.mbState.enabled &&
                  hA.mbState.sampleCount == 2,
              @"the motion-blur header rides every entry");
    KKRequire(hA.base.colorPoolCount == 4 && hB.base.colorPoolCount == 7,
              @"each entry keeps its OWN pool, not a shared one");
    KKRequire(hA.base.common.time == 1.0f && hB.base.common.time == 9.0f,
              @"each entry keeps its own base sample");

    MiragePluginState outA[2], outB[2];
    KKRequire(MirageStateBlobReadStatesAtIndex(chain, 0, outA, 2) &&
                  memcmp(outA, aStates, sizeof(aStates)) == 0,
              @"entry 0's samples round-trip byte for byte");
    KKRequire(MirageStateBlobReadStatesAtIndex(chain, 1, outB, 2) &&
                  memcmp(outB, bStates, sizeof(bStates)) == 0,
              @"entry 1's samples round-trip byte for byte");
    KKRequire(MirageStateBlobReadStates(chain, outA, 2) &&
                  memcmp(outA, aStates, sizeof(aStates)) == 0,
              @"the unindexed states reader answers entry 0");

    // Per-sample enabled flags, and the clamp past the last one.
    KKRequire(MirageStateBlobEntryEnabled(chain, 0, 0) &&
                  MirageStateBlobEntryEnabled(chain, 0, 1),
              @"entry 0 is enabled at every sample");
    KKRequire(MirageStateBlobEntryEnabled(chain, 1, 0) &&
                  !MirageStateBlobEntryEnabled(chain, 1, 1),
              @"entry 1's per-sample flags survive the trip");
    KKRequire(!MirageStateBlobEntryEnabled(chain, 1, 99),
              @"a sample past the end reads the last flag it has");
    KKRequire(MirageStateBlobEntryEnabled(chain, 7, 0),
              @"an entry that does not exist reads as enabled, not as junk");

    // --- truncation stays graceful ----------------------------------------
    for (NSUInteger cut = 1; cut < 64 && cut < chain.length; cut += 3) {
      NSData *short_ = [chain subdataWithRange:NSMakeRange(0, cut)];
      MirageStateBlobHeader h = MirageStateBlobReadHeaderAtIndex(short_, 1);
      KKRequire(h.sampleCount == 1,
                @"a truncated blob decodes as one default sample");
      (void)MirageStateBlobReadSectionsAtIndex(short_, 1);
      MiragePluginState junk[2];
      (void)MirageStateBlobReadStatesAtIndex(short_, 1, junk, 2);
    }
    MirageStateBlobHeader nilH = MirageStateBlobReadHeader(nil);
    KKRequire(nilH.sampleCount == 1 && !nilH.mbState.enabled,
              @"a nil blob decodes as motion blur off with one sample");

    // --- scale: what an 8-entry chain actually costs per frame -------------
    //
    // The blob is per FRAME and per entry and per motion-blur SAMPLE, and the
    // colour pool inside MiragePluginState is a FIXED array
    // (KK_SHADER_COLOR_POOL vec4s) whether a shader declares one swatch or
    // ninety. Measured rather than reasoned about, because "fixed pool x
    // entries x samples" is the one multiplication in the design that could
    // have been quietly quadratic.
    const NSInteger kScaleEntries = 8;
    NSString *body =
        [@"" stringByPaddingToLength:2400
                          withString:@"vec3 c = mix(a, b, t); // filler\n"
                     startingAtIndex:0];
    for (NSInteger samples = 1; samples <= 16; samples *= 4) {
      KKMotionBlurState smb;
      memset(&smb, 0, sizeof(smb));
      smb.enabled = samples > 1;
      smb.sampleCount = (int)samples;

      KKTimeline *big = [KKTimeline timeline];
      NSMutableArray<NSString *> *ids = [NSMutableArray array];
      NSMutableArray<KKLane *> *codeLanes = [NSMutableArray array];
      NSMutableArray<MirageStateBlobEntry *> *entries = [NSMutableArray array];
      for (NSInteger e = 0; e < kScaleEntries; e++) {
        NSString *eid = e == 0 ? (NSString *)kMirageRackSentinelEntryID
                               : [NSString stringWithFormat:@"e%05ld", (long)e];
        [ids addObject:eid];
        [codeLanes addObject:MirageTestCodeLane(
                                 eid, body,
                                 @[ @{@"name" : @"Common", @"code" : body} ])];
        MiragePluginState *ss =
            calloc((size_t)samples, sizeof(MiragePluginState));
        for (NSInteger s = 0; s < samples; s++)
          ss[s] = MirageTestState((float)s * 0.01f, KK_SHADER_COLOR_POOL);
        MirageStateBlobEntry *entry = [MirageStateBlobEntry new];
        entry.entryID = eid;
        entry.states = [NSData
            dataWithBytes:ss
                   length:(NSUInteger)samples * sizeof(MiragePluginState)];
        free(ss);
        uint8_t flags[16];
        memset(flags, 1, sizeof(flags));
        entry.enabled = [NSData dataWithBytes:flags length:(NSUInteger)samples];
        [entries addObject:entry];
      }
      big.slotGroups = @{kMirageRackGroupName : ids};
      big.lanes = codeLanes;

      NSData *blob = MirageStateBlobEncodeRack(&smb, entries, big);
      NSUInteger pools = (NSUInteger)kScaleEntries * (NSUInteger)samples *
                         sizeof(vector_float4) * KK_SHADER_COLOR_POOL;
      NSLog(@"SCALE: %ld entries x %ld samples -> %.1f KB blob (%.1f KB of it "
            @"fixed colour pool, %.1f KB source)",
            (long)kScaleEntries, (long)samples, blob.length / 1024.0,
            pools / 1024.0,
            (double)(kScaleEntries * 2 * (NSInteger)body.length) / 1024.0);
      KKRequire(blob.length < 4u * 1024u * 1024u,
                @"an 8-entry frame blob stays well under a megabyte-scale "
                @"budget - the fixed pool is not worth compressing until it "
                @"does not");
      KKRequire(MirageStateBlobEntryCount(blob) == kScaleEntries,
                @"...and still decodes every entry at that size");
    }

    NSLog(@"PASS: MirageStateBlobTests");
  }
  return 0;
}
