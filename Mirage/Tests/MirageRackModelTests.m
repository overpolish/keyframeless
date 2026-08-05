/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KKTimeline.h>

#import "MirageRack.h"

static void KKRequire(BOOL condition, NSString *message) {
  if (condition)
    return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

int main(void) {
  @autoreleasepool {
    // --- ~Rack charset: provably unauthorable through #slots -------------
    //
    // The `#slots` name validator (MirageSlots.h) is
    // `^[A-Za-z0-9][A-Za-z0-9 ._-]*$` - `~` cannot start (or appear in) an
    // authored group name, so a shader author can never collide with the
    // reserved rack group. Pin that regex's shape here (rather than trusting
    // the header comment) so a future edit to the validator that widens the
    // charset trips this test.
    NSRegularExpression *slotsNameRe = [NSRegularExpression
        regularExpressionWithPattern:@"^[A-Za-z0-9][A-Za-z0-9 ._-]*$"
                             options:0
                               error:nil];
    KKRequire(
        ![slotsNameRe
            firstMatchInString:kMirageRackGroupName
                       options:0
                         range:NSMakeRange(0, kMirageRackGroupName.length)],
        @"~Rack is rejected by the #slots name validator");
    // And confirm the OTHER half: KKSlotParseLaneKey places no constraint on
    // the group-name character set at all, so `~Rack` is not merely
    // "unauthored", it is parseable - the reservation is enforced entirely by
    // the directive's validator, not by an accidental parser gap.
    NSString *g = nil, *i = nil, *c = nil;
    NSString *rackKey =
        KKSlotLaneKey(kMirageRackGroupName, @"a1b2c3", @"Mirage");
    KKRequire([rackKey isEqualToString:@"~Rack#a1b2c3.Mirage"],
              @"~Rack composes through KKSlotLaneKey untouched");
    KKRequire(KKSlotParseLaneKey(rackKey, &g, &i, &c) &&
                  [g isEqualToString:kMirageRackGroupName] &&
                  [i isEqualToString:@"a1b2c3"] &&
                  [c isEqualToString:@"Mirage"],
              @"KKSlotParseLaneKey round-trips the ~Rack group name");

    // --- MirageRackEntryIDs -----------------------------------------------
    KKTimeline *tl = [KKTimeline timeline];
    KKRequire(
        [MirageRackEntryIDs(tl) isEqualToArray:@[ kMirageRackSentinelEntryID ]],
        @"absent registry -> [sentinel]");
    KKRequire([kMirageRackSentinelEntryID isEqualToString:@"0"],
              @"sentinel id is the documented literal");

    tl.slotGroups = @{kMirageRackGroupName : @[ @"0", @"7f3a01", @"c9d2e4" ]};
    KKRequire(
        [MirageRackEntryIDs(tl) isEqualToArray:@[ @"0", @"7f3a01", @"c9d2e4" ]],
        @"present registry order preserved");

    tl.slotGroups = @{kMirageRackGroupName : @[]};
    KKRequire(
        [MirageRackEntryIDs(tl) isEqualToArray:@[ kMirageRackSentinelEntryID ]],
        @"an emptied-but-registered group still answers [sentinel]");

    // --- MirageRackLaneKey / MirageRackParseLaneKey: sentinel passthrough -
    KKRequire([MirageRackLaneKey(kMirageRackSentinelEntryID, @"Mirage")
                  isEqualToString:@"Mirage"],
              @"sentinel entry keeps a bare key on the way out");
    NSString *entryID = nil, *bareKey = nil;
    KKRequire(MirageRackParseLaneKey(@"Mirage", &entryID, &bareKey) &&
                  [entryID isEqualToString:kMirageRackSentinelEntryID] &&
                  [bareKey isEqualToString:@"Mirage"],
              @"a bare pre-rack key parses back to sentinel + itself");
    KKRequire(MirageRackParseLaneKey(@"Origin", &entryID, &bareKey) &&
                  [entryID isEqualToString:kMirageRackSentinelEntryID] &&
                  [bareKey isEqualToString:@"Origin"],
              @"parse of a plain, unrelated key -> sentinel + itself");

    // --- prefix round-trip: plain key ---------------------------------
    NSString *plainKey = MirageRackLaneKey(@"7f3a01", @"uColor");
    KKRequire([plainKey isEqualToString:@"~Rack#7f3a01.uColor"],
              @"non-sentinel entry mints a prefixed key");
    entryID = nil;
    bareKey = nil;
    KKRequire(MirageRackParseLaneKey(plainKey, &entryID, &bareKey) &&
                  [entryID isEqualToString:@"7f3a01"] &&
                  [bareKey isEqualToString:@"uColor"],
              @"plain prefixed key round-trips");

    // --- prefix round-trip: NESTED slot key ----------------------------
    //
    // A control belonging to a #slots instance living INSIDE a rack entry:
    // `Colours#d4e5f6.uColor` is itself slot-shaped. It must survive being
    // wrapped in a rack prefix and pulled back out whole - not partially
    // reparsed - because MirageRackParseLaneKey only peels the OUTER layer.
    NSString *nestedBare = @"Colours#d4e5f6.uColor";
    NSString *nestedKey = MirageRackLaneKey(@"a1b2c3", nestedBare);
    KKRequire([nestedKey isEqualToString:@"~Rack#a1b2c3.Colours#d4e5f6.uColor"],
              @"nested slot key composes as documented");
    entryID = nil;
    bareKey = nil;
    KKRequire(MirageRackParseLaneKey(nestedKey, &entryID, &bareKey) &&
                  [entryID isEqualToString:@"a1b2c3"] &&
                  [bareKey isEqualToString:nestedBare],
              @"nested slot key round-trips whole, not partially reparsed");
    // And the recovered bareKey is itself still a valid, independently
    // parseable slot key - confirming MirageRackScopedSlotGroupName's claim
    // that peeling the rack layer leaves the inner #slots key untouched.
    NSString *ig = nil, *ii = nil, *ic = nil;
    KKRequire(KKSlotParseLaneKey(bareKey, &ig, &ii, &ic) &&
                  [ig isEqualToString:@"Colours"] &&
                  [ii isEqualToString:@"d4e5f6"] &&
                  [ic isEqualToString:@"uColor"],
              @"the recovered inner key still parses as its own #slots key");

    // --- MirageRackScopedSlotGroupName -----------------------------------
    KKRequire(
        [MirageRackScopedSlotGroupName(kMirageRackSentinelEntryID, @"Colours")
            isEqualToString:@"Colours"],
        @"sentinel's nested #slots group stays bare");
    KKRequire([MirageRackScopedSlotGroupName(@"a1b2c3", @"Colours")
                  isEqualToString:@"~Rack#a1b2c3.Colours"],
              @"a minted entry's nested #slots group is scoped to it");
    KKRequire(![MirageRackScopedSlotGroupName(@"a1b2c3", @"Colours")
                  isEqualToString:MirageRackScopedSlotGroupName(@"7f3a01",
                                                                @"Colours")],
              @"two entries running the same template get separate registries");

    // A `{n}` inspector group ("Colour 2" once stamped) is a NAME the user
    // reads, never a key. It must not compose with either namespace: the
    // registry is keyed off the block's `name=`, so the two live side by side
    // without meeting.
    KKRequire(![MirageRackScopedSlotGroupName(@"a1b2c3", @"Colours")
                  isEqualToString:@"Colour 2"],
              @"a per-instance category is not a registry key");
    entryID = nil;
    bareKey = nil;
    MirageRackParseLaneKey(@"Colour 2", &entryID, &bareKey);
    KKRequire([entryID isEqualToString:kMirageRackSentinelEntryID] &&
                  [bareKey isEqualToString:@"Colour 2"],
              @"...and reads back as an unscoped string, whole");

    // --- MirageRackEnabledLaneKey: always prefixed, sentinel included -----
    KKRequire([MirageRackEnabledLaneKey(kMirageRackSentinelEntryID)
                  isEqualToString:@"~Rack#0.Enabled"],
              @"sentinel's Enabled lane is prefixed too - no bare-key compat "
              @"constraint applies to a lane that never existed before");
    KKRequire([MirageRackEnabledLaneKey(@"7f3a01")
                  isEqualToString:@"~Rack#7f3a01.Enabled"],
              @"a minted entry's Enabled lane is prefixed");
    KKRequire(MirageRackEntryEnabledDefault == YES,
              @"absent Enabled lane means enabled");

    // --- MirageRackEntryEnabledAtFraction: the HELD keypose ----------------
    KKTimeline *enabledTL = [KKTimeline timeline];
    KKLane *enabledLane =
        [KKLane laneWithKey:MirageRackEnabledLaneKey(@"7f3a01")
                      label:@"Enabled"];
    [enabledLane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @1.0 ]]];
    [enabledLane insertKeypose:[KKKeyPose keyposeAtTime:0.5 values:@[ @0.0 ]]];
    enabledTL.lanes = @[ enabledLane ];
    KKRequire(MirageRackEntryEnabledAtFraction(enabledTL, @"7f3a01", 0.0),
              @"on at the first keypose");
    KKRequire(MirageRackEntryEnabledAtFraction(enabledTL, @"7f3a01", 0.49),
              @"a toggle HOLDS its value up to the next keypose - the nearest "
              @"keypose would have flipped it half an interval early");
    KKRequire(!MirageRackEntryEnabledAtFraction(enabledTL, @"7f3a01", 0.5),
              @"off from the cut itself");
    KKRequire(!MirageRackEntryEnabledAtFraction(enabledTL, @"7f3a01", 1.0),
              @"and stays off to the end");
    KKRequire(MirageRackEntryEnabledAtFraction(enabledTL, @"0", 0.75),
              @"an entry with no lane of its own is enabled, whatever another "
              @"entry's lane says at that instant");

    // --- MirageRackPreviewEntryPlan: shared mini/main viewer shape --------
    NSArray<NSString *> *previewEntries = @[ @"0", @"aaa", @"bbb", @"ccc" ];
    NSSet<NSString *> *previewEnabled =
        [NSSet setWithArray:@[ @"0", @"bbb", @"ccc" ]];
    KKRequire([MirageRackPreviewEntryPlan(previewEntries, previewEnabled,
                                          MirageRackPreviewModeOff, nil)
                  isEqualToArray:(@[ @"0", @"bbb", @"ccc" ])],
              @"preview off renders the complete enabled chain");
    KKRequire([MirageRackPreviewEntryPlan(previewEntries, previewEnabled,
                                          MirageRackPreviewModeUpToHere, @"bbb")
                  isEqualToArray:(@[ @"0", @"bbb" ])],
              @"up-to-here truncates after the focused entry and still skips "
              @"disabled entries before it");
    KKRequire([MirageRackPreviewEntryPlan(previewEntries, previewEnabled,
                                          MirageRackPreviewModeSolo, @"aaa")
                  isEqualToArray:@[ @"aaa" ]],
              @"solo renders its focused entry even when that entry is "
              @"disabled in the ordinary chain");
    KKRequire([MirageRackPreviewEntryPlan(
                  previewEntries, previewEnabled, MirageRackPreviewModeUpToHere,
                  @"gone") isEqualToArray:(@[ @"0", @"bbb", @"ccc" ])],
              @"a stale preview focus falls back to the complete chain");

    KKRequire([MirageRackViewerEntryPlan(
                  previewEntries, previewEnabled, MirageRackPreviewModeOff, nil,
                  YES, @"bbb") isEqualToArray:(@[ @"0", @"bbb" ])],
              @"selection matte stops after the selected entry");
    KKRequire([MirageRackViewerEntryPlan(previewEntries, previewEnabled,
                                         MirageRackPreviewModeSolo, @"ccc", NO,
                                         @"bbb") isEqualToArray:@[ @"ccc" ]],
              @"inactive matte leaves the explicit rack preview unchanged");
    KKRequire([MirageRackViewerEntryPlan(
                  previewEntries, previewEnabled, MirageRackPreviewModeOff, nil,
                  YES, @"gone") isEqualToArray:(@[ @"0", @"bbb", @"ccc" ])],
              @"a stale matte selection falls back to the complete chain");

    // --- MirageRackDedupedDisplayNames -------------------------------------
    NSArray<NSString *> *names = MirageRackDedupedDisplayNames(
        @[ @"Grade", @"Grade", @"Selective", @"Grade" ]);
    KKRequire([names isEqualToArray:(@[
                       @"Grade", @"Grade 2", @"Selective", @"Grade 3"
                     ])],
              @"name dedup auto-suffixes repeats, independently per name");

    NSArray<NSString *> *singletons =
        MirageRackDedupedDisplayNames(@[ @"Grade", @"Selective" ]);
    KKRequire([singletons isEqualToArray:(@[ @"Grade", @"Selective" ])],
              @"no repeats -> no suffixes at all");

    KKRequire([MirageRackDedupedDisplayNames(@[]) isEqualToArray:@[]],
              @"empty input -> empty output");

    // --- MirageRackCodeLaneForEntry / MirageRackSectionsForEntry -----------
    KKLane *sentinelCode = [KKLane laneWithKey:@"Mirage" label:@"Mirage"];
    sentinelCode.valueType = KKLaneValueTypeCode;
    sentinelCode.codeString = @"void mainImage() {}";
    sentinelCode.codeSaveName = @"My Grade";

    KKLane *rackedCode = [KKLane laneWithKey:@"~Rack#7f3a01.Mirage"
                                       label:@"Mirage"];
    rackedCode.valueType = KKLaneValueTypeCode;
    rackedCode.codeString = @"void mainImage() {}";
    rackedCode.codeTabs = @[ @{@"name" : @"Common", @"code" : @"float x;"} ];

    tl.lanes = @[ sentinelCode, rackedCode ];

    KKLane *foundSentinel =
        MirageRackCodeLaneForEntry(tl, kMirageRackSentinelEntryID, @"Mirage");
    KKRequire(foundSentinel == sentinelCode,
              @"sentinel code lane found by bare key");
    KKLane *foundRacked = MirageRackCodeLaneForEntry(tl, @"7f3a01", @"Mirage");
    KKRequire(foundRacked == rackedCode,
              @"racked entry's code lane found by prefixed key");
    KKRequire(MirageRackCodeLaneForEntry(tl, @"nosuch", @"Mirage") == nil,
              @"an unregistered entry has no code lane");

    NSArray<NSDictionary<NSString *, NSString *> *> *rackedSections =
        MirageRackSectionsForEntry(tl, @"7f3a01", @"Mirage");
    KKRequire(rackedSections.count == 2 &&
                  [rackedSections[0][@"name"] isEqualToString:@"Image"] &&
                  [rackedSections[1][@"name"] isEqualToString:@"Common"],
              @"sections are Image first, then codeTabs verbatim");

    KKRequire(
        [MirageRackEntryDisplayName(tl, kMirageRackSentinelEntryID, @"Mirage",
                                    @"Custom") isEqualToString:@"My Grade"],
        @"a named code lane's codeSaveName wins over the fallback");
    KKRequire([MirageRackEntryDisplayName(tl, @"7f3a01", @"Mirage", @"Custom")
                  isEqualToString:@"Custom"],
              @"an unnamed code lane falls back to the caller's name");
    KKRequire([MirageRackEntryDisplayName(tl, @"nosuch", @"Mirage", @"Fallback")
                  isEqualToString:@"Fallback"],
              @"a missing code lane also falls back");

    // --- MirageRackDisplayNames: what the strip AND the link manifest name
    // the chain by, so the two can never disagree ---------------------------
    KKLane *secondCode = [KKLane laneWithKey:@"~Rack#9c02aa.Mirage"
                                       label:@"Mirage"];
    secondCode.valueType = KKLaneValueTypeCode;
    secondCode.codeSaveName = @"My Grade";
    tl.lanes = [tl.lanes arrayByAddingObject:secondCode];

    NSArray<NSString *> *chainNames = MirageRackDisplayNames(
        tl, (@[ kMirageRackSentinelEntryID, @"7f3a01", @"9c02aa" ]), @"Mirage",
        @"Shader");
    KKRequire([chainNames
                  isEqualToArray:(@[ @"My Grade", @"Shader", @"My Grade 2" ])],
              @"chain names resolve per entry, fall back per entry, and dedupe "
              @"across the whole chain in rack order");
    KKRequire([[chainNames componentsJoinedByString:@" > "]
                  isEqualToString:@"My Grade > Shader > My Grade 2"],
              @"the manifest's display name is that list joined in rack order");
    KKRequire(
        [MirageRackDisplayNames(tl, @[ kMirageRackSentinelEntryID ], @"Mirage",
                                @"Shader") isEqualToArray:@[ @"My Grade" ]],
        @"an unracked project's one name is left bare, suffix and all");

    // --- MirageRackReorderedEntryIDs: pure permutation --------------------
    NSArray<NSString *> *order = @[ @"0", @"aaa", @"bbb", @"ccc" ];
    KKRequire([MirageRackReorderedEntryIDs(order, @"ccc", 1)
                  isEqualToArray:(@[ @"0", @"ccc", @"aaa", @"bbb" ])],
              @"dragging the last entry up lands before the named slot");
    KKRequire([MirageRackReorderedEntryIDs(order, @"0", 3)
                  isEqualToArray:(@[ @"aaa", @"bbb", @"0", @"ccc" ])],
              @"dragging down shifts by one for the lifted row");
    KKRequire(
        [MirageRackReorderedEntryIDs(order, @"aaa", 1) isEqualToArray:order],
        @"a drop on its own slot is a no-op");
    KKRequire(
        [MirageRackReorderedEntryIDs(order, @"aaa", 2) isEqualToArray:order],
        @"a drop just after itself is a no-op too");
    KKRequire([MirageRackReorderedEntryIDs(order, @"aaa", 99)
                  isEqualToArray:(@[ @"0", @"bbb", @"ccc", @"aaa" ])],
              @"an out-of-range target clamps to the end");
    KKRequire(
        [MirageRackReorderedEntryIDs(order, @"nosuch", 0) isEqualToArray:order],
        @"an unknown id leaves the order alone");

    // --- MirageRackLaneKeyBelongsToEntry: the removal filter ---------------
    KKRequire(
        MirageRackLaneKeyBelongsToEntry(@"Origin", kMirageRackSentinelEntryID),
        @"a bare key belongs to the sentinel");
    KKRequire(!MirageRackLaneKeyBelongsToEntry(@"~Rack#7f3a01.uColor",
                                               kMirageRackSentinelEntryID),
              @"a prefixed key does NOT belong to the sentinel");
    KKRequire(
        MirageRackLaneKeyBelongsToEntry(@"~Rack#7f3a01.uColor", @"7f3a01"),
        @"a prefixed key belongs to the entry that prefixes it");
    KKRequire(!MirageRackLaneKeyBelongsToEntry(@"~Rack#0.Enabled", @"7f3a01"),
              @"one entry's Enabled lane is not another's");
    KKRequire(
        MirageRackLaneKeyBelongsToEntry(@"~Rack#0.Enabled",
                                        kMirageRackSentinelEntryID),
        @"the sentinel's Enabled lane IS prefixed, and still parses to it");

    // --- registry writes ---------------------------------------------------
    KKTimeline *legacy = [KKTimeline timeline];
    KKRequire(MirageRackRegisterSentinelIfNeeded(legacy),
              @"a never-racked project registers the sentinel on first write");
    KKRequire([legacy.slotGroups[kMirageRackGroupName]
                  isEqualToArray:@[ kMirageRackSentinelEntryID ]],
              @"...and registers exactly the sentinel");
    KKRequire(!MirageRackRegisterSentinelIfNeeded(legacy),
              @"registering twice is a no-op");
    KKRequire(!MirageRackSetEntryIDs(legacy, @[]),
              @"an empty registry is refused, never written");

    // --- MirageRackRemoveEntry --------------------------------------------
    KKTimeline *rack = [KKTimeline timeline];
    rack.slotGroups = @{
      kMirageRackGroupName : @[ @"0", @"7f3a01" ],
      @"Colours" : @[ @"d4e5f6" ],              // the sentinel's nested group
      @"~Rack#7f3a01.Colours" : @[ @"a9b8c7" ], // entry 7f3a01's
    };
    rack.lanes = @[
      [KKLane laneWithKey:@"Mirage" label:@"Mirage"],
      [KKLane laneWithKey:@"Colours#d4e5f6.uColor" label:@"Colour"],
      [KKLane laneWithKey:@"~Rack#0.Enabled" label:@"Enabled"],
      [KKLane laneWithKey:@"~Rack#7f3a01.Mirage" label:@"Mirage"],
      [KKLane laneWithKey:@"~Rack#7f3a01.Enabled" label:@"Enabled"],
      [KKLane laneWithKey:@"~Rack#7f3a01.Colours#a9b8c7.uColor"
                    label:@"Colour"],
    ];
    KKRequire(MirageRackRemoveEntry(rack, @"7f3a01"), @"removing entry 2");
    KKRequire([MirageRackEntryIDs(rack) isEqualToArray:@[ @"0" ]],
              @"the registry keeps the sentinel rather than being deleted, so "
              @"the project stays racked");
    KKRequire(rack.lanes.count == 3,
              @"every lane of the removed entry went, and only those");
    for (KKLane *lane in rack.lanes)
      KKRequire(
          MirageRackLaneKeyBelongsToEntry(lane.key, kMirageRackSentinelEntryID),
          @"...every survivor belongs to the sentinel");
    KKRequire(rack.slotGroups[@"~Rack#7f3a01.Colours"] == nil,
              @"the removed entry's nested #slots registry went with it");
    KKRequire([rack.slotGroups[@"Colours"] isEqualToArray:@[ @"d4e5f6" ]],
              @"the sentinel's own nested registry is untouched");
    KKRequire(!MirageRackRemoveEntry(rack, @"0"),
              @"the last entry can't be removed - a rack always renders "
              @"something");
    KKRequire(!MirageRackRemoveEntry(rack, @"nosuch"),
              @"removing an unregistered id changes nothing");

    NSLog(@"all MirageRack model tests passed");
    return 0;
  }
}
