/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

#import "MirageLaneCatalog.h"
#import "MirageRack.h"

static void KKRequire(BOOL condition, NSString *message) {
  if (condition)
    return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

// Every field of a lane that names something: its own identity, its display
// name, its grouping, and the keys it points at. What "the rack changed
// nothing" has to mean for a project that has never been racked.
static NSString *KKLaneFingerprint(KKLane *lane) {
  return [NSString
      stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@|%@|%@|%@", lane.key ?: @"",
                       lane.label ?: @"", lane.groupKey ?: @"",
                       lane.categoryKey ?: @"", lane.categorySymbol ?: @"",
                       lane.paletteGroup ?: @"", lane.visibleWhenKey ?: @"",
                       lane.maxControllerKey ?: @"", lane.layerKey ?: @"",
                       lane.layerLabel ?: @""];
}

static NSArray<NSString *> *KKFingerprints(NSArray<KKLane *> *lanes) {
  NSMutableArray<NSString *> *out =
      [NSMutableArray arrayWithCapacity:lanes.count];
  for (KKLane *lane in lanes)
    [out addObject:KKLaneFingerprint(lane)];
  return out;
}

static KKLane *KKLaneWithKey(NSArray<KKLane *> *lanes, NSString *key) {
  for (KKLane *lane in lanes)
    if ([lane.key isEqualToString:key])
      return lane;
  return nil;
}

static KKTimeline *KKTimelineWithCode(NSString *entryID, NSString *source,
                                      KKTimeline *into) {
  KKTimeline *tl = into ?: [KKTimeline timeline];
  KKLane *code =
      [KKLane laneWithKey:MirageRackCodeLaneKey(entryID, kMirageCodeLaneLabel)
                    label:@"Shader"];
  code.valueType = KKLaneValueTypeCode;
  code.codeString = source;
  tl.lanes = [tl.lanes arrayByAddingObject:code];
  return tl;
}

static NSString *const kSlotlessSource =
    @"// #template generator\n"
    @"// #speed\n"
    @"// #float label=\"Amount\" min=0 max=100 default=50\n"
    @"uniform float uAmount;\n"
    @"// #color label=\"Tint\"\n"
    @"uniform vec4 uTint;\n"
    @"void mainImage(out vec4 o, in vec2 c) { o = uTint * uAmount; }\n";

static NSString *const kSlotsSource =
    @"// #template generator\n"
    @"// #slots name=\"Colours\" max=4 min=1 default=2\n"
    @"// #color label=\"Colour {n}\"\n"
    @"uniform vec4 uSlotColor;\n"
    @"// #float label=\"Weight {n}\" min=0 max=1 default=0.5\n"
    @"uniform float uSlotWeight;\n"
    @"// #slots-end\n"
    @"// #float label=\"Amount\" min=0 max=100 default=50\n"
    @"uniform float uAmount;\n"
    @"void mainImage(out vec4 o, in vec2 c) { o = uSlotColor * uSlotWeight; "
    @"}\n";

// The same block, asking for one inspector group PER INSTANCE (`group={"Colour
// {n}", "{n}.circle"}`) alongside a control that asks for a SHARED one. Both
// answers have to come out of one block, since that is what a template gets to
// choose per control.
static NSString *const kSlotsGroupedSource =
    @"// #template generator\n"
    @"// #slots name=\"Colours\" max=4 min=1 default=2\n"
    @"// #float label=\"Weight {n}\" group={\"Colour {n}\", \"{n}.circle\"} "
    @"min=0 max=1 default=0.5\n"
    @"uniform float uSlotWeight;\n"
    @"// #float label=\"Bias {n}\" group={\"Shared\", \"dial\"} min=0 max=1 "
    @"default=0.25\n"
    @"uniform float uSlotBias;\n"
    @"// #slots-end\n"
    @"void mainImage(out vec4 o, in vec2 c) { o = vec4(uSlotWeight[0] * "
    @"uSlotBias[0]); }\n";

static NSArray<NSString *> *KKCategoriesForKeySuffix(NSArray<KKLane *> *lanes,
                                                     NSString *suffix) {
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (KKLane *lane in lanes)
    if ([lane.key hasSuffix:suffix])
      [out addObject:lane.categoryKey ?: @""];
  return out;
}

// A build with no rack registry has to be the build that shipped: same lanes,
// same order, same every naming field.
static void KKAssertLegacyIdentity(NSString *source, NSString *what) {
  // Both builds run against the SAME registry (a copy each, so neither sees
  // the other's writes): a `#slots` group mints fresh random ids on first
  // sight, and two independently minted timelines would differ for a reason
  // that has nothing to do with the rack.
  KKTimeline *seed =
      KKTimelineWithCode(kMirageRackSentinelEntryID, source, nil);
  (void)MirageBuildAvailableLanesForSourceStamped(source, nil, seed);
  KKTimeline *legacy = [seed copy];
  KKTimeline *racked = [seed copy];
  NSArray<KKLane *> *before =
      MirageBuildAvailableLanesForSourceStamped(source, nil, legacy);
  NSArray<KKLane *> *after =
      MirageBuildAvailableLanesForRack(racked, nil, nil, nil);
  KKRequire(before.count == after.count,
            [NSString stringWithFormat:@"%@: same lane count (%lu vs %lu)",
                                       what, (unsigned long)before.count,
                                       (unsigned long)after.count]);
  KKRequire(
      [KKFingerprints(before) isEqualToArray:KKFingerprints(after)],
      [NSString
          stringWithFormat:@"%@: identical lanes in identical order", what]);
  KKRequire(
      before.count > 0,
      [NSString stringWithFormat:@"%@: the comparison isn't vacuous", what]);
  // The registry the stamping pass writes has to be the bare one too, or a
  // legacy project's persisted instance lanes stop matching their template.
  KKRequire([legacy.slotGroups ?: @{} isEqual:racked.slotGroups ?: @{}],
            [NSString stringWithFormat:@"%@: identical slot registry", what]);
  for (NSString *group in racked.slotGroups)
    KKRequire(
        ![group hasPrefix:kMirageRackGroupName],
        [NSString stringWithFormat:@"%@: no rack-scoped registry key", what]);
}

int main(void) {
  @autoreleasepool {
    // --- (a) a slotless template, unracked --------------------------------
    KKAssertLegacyIdentity(kSlotlessSource, @"slotless legacy");

    // --- (b) a `#slots` template with registered instances, unracked ------
    //
    // Minted first (a build against a fresh timeline brings the group up to
    // its declared default), so the comparison is against a project that HAS
    // instances rather than one that is about to get them.
    KKTimeline *minted =
        KKTimelineWithCode(kMirageRackSentinelEntryID, kSlotsSource, nil);
    (void)MirageBuildAvailableLanesForSourceStamped(kSlotsSource, nil, minted);
    KKRequire(KKTimelineSlotInstanceIDs(minted, @"Colours").count == 2,
              @"the slots group minted its declared default count");
    KKAssertLegacyIdentity(kSlotsSource, @"slots legacy");

    // A legacy project gains NO new lane: no Enabled, no layer level.
    NSArray<KKLane *> *legacyLanes = MirageBuildAvailableLanesForRack(
        KKTimelineWithCode(kMirageRackSentinelEntryID, kSlotsSource, nil), nil,
        nil, nil);
    for (KKLane *lane in legacyLanes) {
      KKRequire(!lane.layerKey.length,
                @"an unracked project's lanes carry no layerKey");
      KKRequire(![lane.key hasPrefix:kMirageRackGroupName],
                @"an unracked project's lanes carry no rack prefix");
    }

    // --- explicit-source override ----------------------------------------
    KKTimeline *stored =
        KKTimelineWithCode(kMirageRackSentinelEntryID, kSlotlessSource, nil);
    NSArray<KKLane *> *overridden =
        MirageBuildAvailableLanesForRack(stored, nil, kSlotsSource, nil);
    KKRequire(KKLaneWithKey(overridden, @"uAmount") != nil,
              @"mid-edit source builds its own lanes");
    KKRequire(KKTimelineSlotInstanceIDs(stored, @"Colours").count == 2,
              @"mid-edit source stamps its slots group like the stored one");

    // --- (c) a two-entry rack ---------------------------------------------
    NSString *second = @"7f3a01";
    KKTimeline *rack =
        KKTimelineWithCode(kMirageRackSentinelEntryID, kSlotsSource, nil);
    rack = KKTimelineWithCode(second, kSlotsSource, rack);
    rack.slotGroups =
        @{kMirageRackGroupName : @[ kMirageRackSentinelEntryID, second ]};
    NSArray<KKLane *> *rackLanes =
        MirageBuildAvailableLanesForRack(rack, nil, nil, nil);

    NSMutableArray<NSString *> *entry2Bare = [NSMutableArray array];
    NSMutableArray<NSString *> *sentinelKeys = [NSMutableArray array];
    NSUInteger enabledCount = 0;
    for (KKLane *lane in rackLanes) {
      NSString *entryID = nil, *bare = nil;
      MirageRackParseLaneKey(lane.key, &entryID, &bare);
      if ([lane.key isEqualToString:MirageRackEnabledLaneKey(entryID)]) {
        enabledCount++;
        KKRequire(lane.animatable && lane.isToggle,
                  @"the Enabled lane is an animatable toggle");
        KKRequire(lane.keyposes.firstObject.values.firstObject.doubleValue ==
                      (MirageRackEntryEnabledDefault ? 1.0 : 0.0),
                  @"the Enabled lane defaults to enabled");
        KKRequire([lane.key hasPrefix:kMirageRackGroupName],
                  @"every Enabled lane is prefixed, sentinel included");
        continue;
      }
      KKRequire([lane.layerKey isEqualToString:entryID],
                @"a racked lane's layerKey is its entry");
      if ([entryID isEqualToString:second]) {
        [entry2Bare addObject:bare];
        KKRequire(![lane.categoryKey hasPrefix:kMirageRackGroupName],
                  @"entry 2's categories are BARE - a category is a group name "
                  @"the user reads, and the kit scopes its collapse identity "
                  @"by layer already");
      } else {
        [sentinelKeys addObject:lane.key];
        KKRequire(![lane.key hasPrefix:kMirageRackGroupName],
                  @"the sentinel's lanes stay bare");
        KKRequire(![lane.categoryKey hasPrefix:kMirageRackGroupName],
                  @"the sentinel's categories stay bare");
      }
    }
    KKRequire(enabledCount == 2, @"one Enabled lane per entry");

    // The constants popover's scope predicate (the block Mirage installs as
    // `constantsLaneFilter`): it must PARTITION the built set - every lane
    // belongs to exactly one entry, and the two halves add back up to the
    // whole. A lane that answered to both entries would show twice; one that
    // answered to neither would be unreachable from the popover with no way
    // for the user to find it.
    NSUInteger ofSentinel = 0, ofSecond = 0;
    for (KKLane *lane in rackLanes) {
      BOOL a =
          MirageRackLaneKeyBelongsToEntry(lane.key, kMirageRackSentinelEntryID);
      BOOL b = MirageRackLaneKeyBelongsToEntry(lane.key, second);
      KKRequire(a != b, @"every lane belongs to exactly one entry");
      ofSentinel += a ? 1 : 0;
      ofSecond += b ? 1 : 0;
    }
    KKRequire(ofSentinel + ofSecond == rackLanes.count,
              @"the two scopes cover the whole lane set");
    KKRequire(ofSentinel > 1 && ofSecond > 1, @"the partition isn't vacuous");

    // ...and nothing the user READS carries the rack's scope. The keys do (that
    // is what makes selection undo-free), but the category header, the layer
    // header and the row label are names, and a "~Rack#7f3a01.Options" pill is
    // the bug this asserts against.
    for (KKLane *lane in rackLanes) {
      KKRequire(![(lane.categoryKey ?: @"") hasPrefix:kMirageRackGroupName],
                @"no category shows the rack scope");
      KKRequire(![(lane.layerLabel ?: @"") hasPrefix:kMirageRackGroupName],
                @"no layer name shows the rack scope");
      KKRequire(![(lane.label ?: @"") hasPrefix:kMirageRackGroupName],
                @"no row label shows the rack scope");
    }

    // Slot instances are per entry, not shared: the same template in two
    // entries mints two registries with two different id sets.
    NSArray<NSString *> *sentinelSlots =
        KKTimelineSlotInstanceIDs(rack, @"Colours");
    NSArray<NSString *> *entry2Slots = KKTimelineSlotInstanceIDs(
        rack, MirageRackScopedSlotGroupName(second, @"Colours"));
    KKRequire(sentinelSlots.count == 2 && entry2Slots.count == 2,
              @"both entries minted their own slot instances");
    KKRequire(![sentinelSlots isEqualToArray:entry2Slots],
              @"the two entries' slot instance ids are distinct");

    // What each entry would have been called unracked: the same source built
    // against a timeline holding that entry's OWN instance ids, so the only
    // thing left to differ is the rack prefix - which the sentinel doesn't
    // have, and which entry 2's keys were just parsed back out of.
    NSArray<NSString *> * (^soloKeysForSlots)(NSArray<NSString *> *) =
        ^NSArray<NSString *> *(NSArray<NSString *> *instanceIDs) {
      KKTimeline *solo =
          KKTimelineWithCode(kMirageRackSentinelEntryID, kSlotsSource, nil);
      solo.slotGroups = @{@"Colours" : instanceIDs};
      NSMutableArray<NSString *> *keys = [NSMutableArray array];
      for (KKLane *lane in MirageBuildAvailableLanesForSourceStamped(
               kSlotsSource, nil, solo))
        [keys addObject:lane.key];
      return keys;
    };
    KKRequire([sentinelKeys isEqualToArray:soloKeysForSlots(sentinelSlots)],
              @"the sentinel entry's keys are the unracked build's, in order");
    KKRequire([entry2Bare isEqualToArray:soloKeysForSlots(entry2Slots)],
              @"entry 2's keys parse back to the unracked build's, in order");
    for (NSString *bare in entry2Bare)
      KKRequire(![bare hasPrefix:kMirageRackGroupName],
                @"a nested slot key survives the outer rack peel intact");

    // Display names: two entries running the same unnamed template are told
    // apart in the layer strip.
    NSMutableSet<NSString *> *labels = [NSMutableSet set];
    for (KKLane *lane in rackLanes)
      if (lane.layerLabel.length)
        [labels addObject:lane.layerLabel];
    KKRequire(labels.count == 2, @"each entry gets its own display name");

    // --- link-manifest attribution ----------------------------------------
    //
    // What the link manifest publishes is this build, with each lane's label
    // qualified by its OWN entry ("CRT: Scanlines"). Three entries running the
    // SAME template is the case that catches a mis-attribution: the bare keys
    // repeat, so the only thing telling the three copies of "Amount" apart is
    // the entry each is stamped with. Two properties carry the manifest:
    // one lane per key (a duplicated lane set publishes the same param several
    // times over and attributes the first copy of ALL of them to the first
    // entry), and unique qualified names (duplicates get respelled by their raw
    // key downstream in KKLinkKeySpelledParamNames, which is how `~Rack#<id>.
    // Enabled` would reach the picker).
    NSArray<NSString *> *namedIDs =
        @[ kMirageRackSentinelEntryID, @"c0ffee", @"beef01" ];
    NSArray<NSString *> *namedLabels = @[ @"Dynamic Grid", @"CRT", @"Glitch" ];
    KKTimeline *named = nil;
    for (NSUInteger i = 0; i < namedIDs.count; i++) {
      named = KKTimelineWithCode(namedIDs[i], kSlotlessSource, named);
      named.lanes.lastObject.codeSaveName = namedLabels[i];
    }
    named.slotGroups = @{kMirageRackGroupName : namedIDs};
    NSArray<KKLane *> *manifestLanes =
        MirageBuildAvailableLanesForRack(named, nil, nil, nil);
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];
    NSMutableSet<NSString *> *seenDisplays = [NSMutableSet set];
    NSUInteger enabledRows = 0;
    for (KKLane *lane in manifestLanes) {
      NSString *entryID = nil;
      MirageRackParseLaneKey(lane.key, &entryID, NULL);
      NSString *expected = namedLabels[[namedIDs indexOfObject:entryID]];
      KKRequire(
          [lane.layerLabel isEqualToString:expected],
          [NSString
              stringWithFormat:@"%@ is attributed to the entry its key names "
                               @"(%@, not %@)",
                               lane.key, expected, lane.layerLabel]);
      KKRequire(![seenKeys containsObject:lane.key],
                [NSString stringWithFormat:@"one lane per key (%@)", lane.key]);
      [seenKeys addObject:lane.key];
      NSString *display =
          [NSString stringWithFormat:@"%@: %@", lane.layerLabel, lane.label];
      KKRequire(
          ![seenDisplays containsObject:display],
          [NSString stringWithFormat:@"qualified param names are unique (%@)",
                                     display]);
      [seenDisplays addObject:display];
      if ([lane.key isEqualToString:MirageRackEnabledLaneKey(entryID)]) {
        enabledRows++;
        KKRequire(
            [display isEqualToString:[NSString
                                         stringWithFormat:@"%@: %@", expected,
                                                          MirageRackEnabledLane(
                                                              entryID)
                                                              .label]],
            @"an Enabled row reads as its entry's, not as a raw key");
      }
    }
    KKRequire(enabledRows == namedIDs.count,
              @"every entry publishes exactly one Enabled row");

    // --- (d) a `{n}` inspector group, unracked then racked -----------------
    //
    // `group={"Colour {n}"}` asks for one header per instance; a `group=` with
    // no `{n}` in the same block asks for one header for all of them. Both
    // have to hold at once, and the shared one is the shape every block
    // written before this had - so it is also the regression test that nothing
    // changed for them.
    KKAssertLegacyIdentity(kSlotsGroupedSource, @"grouped slots legacy");
    KKTimeline *grouped =
        KKTimelineWithCode(kMirageRackSentinelEntryID, kSlotsGroupedSource,
                           nil);
    NSArray<KKLane *> *groupedLanes =
        MirageBuildAvailableLanesForSourceStamped(kSlotsGroupedSource, nil,
                                                  grouped);
    NSArray<NSString *> *weightIDs =
        KKTimelineSlotInstanceIDs(grouped, @"Colours");
    KKRequire(weightIDs.count == 2, @"the grouped block minted its default");
    NSArray<NSString *> *weightCats =
        KKCategoriesForKeySuffix(groupedLanes, @".uSlotWeight");
    NSArray<NSString *> *biasCats =
        KKCategoriesForKeySuffix(groupedLanes, @".uSlotBias");
    KKRequire([weightCats isEqualToArray:(@[ @"Colour 1", @"Colour 2" ])],
              @"a `{n}` group is stamped per instance, numbered from 1");
    KKRequire([biasCats isEqualToArray:(@[ @"Shared", @"Shared" ])],
              @"a group without `{n}` stays shared across instances");
    for (KKLane *lane in groupedLanes) {
      KKRequire(!MirageSlotsHasPlaceholder(lane.categoryKey),
                @"no stamped lane reaches the inspector with a literal `{n}` "
                @"category");
      KKRequire(!MirageSlotsHasPlaceholder(lane.categorySymbol),
                @"...nor with a literal `{n}` category icon");
    }
    // The icon is numbered with the header, which is what `{n}.circle` is for.
    for (KKLane *lane in groupedLanes) {
      if (![lane.key hasSuffix:@".uSlotWeight"])
        continue;
      NSString *n = [lane.categoryKey substringFromIndex:
                                          lane.categoryKey.length - 1];
      KKRequire([lane.categorySymbol
                    isEqualToString:[n stringByAppendingString:@".circle"]],
                @"a `{n}` group icon is numbered with its header");
    }
    // Per-instance categories are grouping, not ordering: each instance's
    // header owns a contiguous run, so the inspector reads Colour 1 then
    // Colour 2 rather than interleaving the two.
    NSMutableArray<NSString *> *catRuns = [NSMutableArray array];
    for (KKLane *lane in groupedLanes)
      if (!catRuns.count || ![catRuns.lastObject isEqualToString:
                                                     lane.categoryKey ?: @""])
        [catRuns addObject:lane.categoryKey ?: @""];
    NSCountedSet *runCounts = [NSCountedSet setWithArray:catRuns];
    for (NSString *cat in runCounts)
      KKRequire([runCounts countForObject:cat] == 1,
                [NSString stringWithFormat:@"category %@ is one contiguous run",
                                           cat]);

    // Racked: the registry is scoped per entry, the CATEGORY is not - it is a
    // name the user reads, and two entries running the same template are meant
    // to both say "Colour 1". Their collapse identities stay separate because
    // the kit scopes a category's collapse key by the owning layer, and the
    // layer is the entry.
    KKTimeline *groupedRack =
        KKTimelineWithCode(kMirageRackSentinelEntryID, kSlotsGroupedSource,
                           nil);
    groupedRack =
        KKTimelineWithCode(second, kSlotsGroupedSource, groupedRack);
    groupedRack.slotGroups =
        @{kMirageRackGroupName : @[ kMirageRackSentinelEntryID, second ]};
    NSArray<KKLane *> *groupedRackLanes =
        MirageBuildAvailableLanesForRack(groupedRack, nil, nil, nil);
    NSMutableSet<NSString *> *sentinelWeightCats = [NSMutableSet set];
    NSMutableSet<NSString *> *secondWeightCats = [NSMutableSet set];
    for (KKLane *lane in groupedRackLanes) {
      KKRequire(!MirageSlotsHasPlaceholder(lane.categoryKey),
                @"a racked `{n}` group is substituted too");
      KKRequire(![(lane.categoryKey ?: @"") hasPrefix:kMirageRackGroupName],
                @"a per-instance category is never rack-scoped");
      NSString *entryID = nil, *bare = nil;
      MirageRackParseLaneKey(lane.key, &entryID, &bare);
      if (![bare hasSuffix:@".uSlotWeight"])
        continue;
      [([entryID isEqualToString:second] ? secondWeightCats
                                         : sentinelWeightCats)
          addObject:lane.categoryKey ?: @""];
    }
    NSSet<NSString *> *bothCats =
        [NSSet setWithArray:(@[ @"Colour 1", @"Colour 2" ])];
    KKRequire([sentinelWeightCats isEqualToSet:bothCats] &&
                  [secondWeightCats isEqualToSet:bothCats],
              @"both entries head their instances with the same read-aloud "
              @"category, distinguished by their layer rather than by it");
    KKRequire(![KKTimelineSlotInstanceIDs(groupedRack, @"Colours")
                  isEqualToArray:KKTimelineSlotInstanceIDs(
                                     groupedRack, MirageRackScopedSlotGroupName(
                                                      second, @"Colours"))],
              @"...while their registries stay separate");

    // --- scale: the lane build at a full chain -----------------------------
    //
    // Every rack change re-derives the WHOLE lane set (there is no per-entry
    // incremental build, deliberately - the set is a pure function of the
    // timeline), and each entry re-parses its own source. So the cost is
    // linear in entries times parse, and this is what that costs at the
    // biggest chain the strip offers. CPU only: no FCP, no render, no view.
    const NSInteger kScaleEntries = 8;
    KKTimeline *chain =
        KKTimelineWithCode(kMirageRackSentinelEntryID, kSlotsSource, nil);
    NSMutableArray<NSString *> *chainIDs =
        [NSMutableArray arrayWithObject:kMirageRackSentinelEntryID];
    for (NSInteger e = 1; e < kScaleEntries; e++) {
      NSString *eid = [NSString stringWithFormat:@"e%05ld", (long)e];
      [chainIDs addObject:eid];
      chain = KKTimelineWithCode(eid, kSlotsSource, chain);
    }
    chain.slotGroups = @{kMirageRackGroupName : chainIDs};
    // Warm: the first build mints every entry's slot instances, and minting is
    // a one-off the steady state never pays.
    NSUInteger builtCount =
        MirageBuildAvailableLanesForRack(chain, nil, nil, nil).count;
    const NSInteger kScaleRuns = 20;
    NSDate *t0 = [NSDate date];
    for (NSInteger r = 0; r < kScaleRuns; r++)
      (void)MirageBuildAvailableLanesForRack(chain, nil, nil, nil);
    double ms = -[t0 timeIntervalSinceNow] * 1000.0 / (double)kScaleRuns;
    NSLog(@"SCALE: MirageBuildAvailableLanesForRack over %ld slotted entries "
          @"-> %lu lanes in %.2f ms/build",
          (long)kScaleEntries, (unsigned long)builtCount, ms);
    KKRequire(builtCount > (NSUInteger)kScaleEntries,
              @"the timed build is a real one");

    NSLog(@"all Mirage rack lane tests passed");
    return 0;
  }
}
