/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KKTimeline.h>

// SHADER RACK: one plugin instance hosting an ordered chain of shader
// templates ("entries"). Identity rides the existing `#slots` machinery
// (KKSlotInstances.h) rather than inventing a parallel one: the rack is
// registered as ONE reserved slot group (`kMirageRackGroupName`) on
// `KKTimeline.slotGroups`, and each entry is one instance of it, minted and
// ordered exactly like a `#slots` group's instances are.
//
// The one wrinkle `#slots` doesn't have: Mirage shipped for a long time as a
// single, unracked template. Every persisted project's lanes - the "Mirage"
// code lane, every uniform lane a template built - are BARE keys with no
// group prefix at all. Retrofitting the rack onto that history without a
// migration pass means the FIRST rack entry has to BE that legacy template:
// its keys stay bare forever. `kMirageRackSentinelEntryID` is that entry's
// id. It is never minted (no `KKTimelineStampSlotInstance` call produces it -
// mint continues to hand out 6-hex-char ids, and "0" is not shaped like one),
// it is always first when the registry is absent, and `MirageRackLaneKey` /
// `MirageRackParseLaneKey` special-case it to a no-op passthrough. Every
// OTHER entry is `~Rack#<id>.<bareKey>`, following `#slots` exactly.

NS_ASSUME_NONNULL_BEGIN

/// The rack's slot group name. Reserved, and DELIBERATELY unauthorable
/// through the `#slots` directive, so a shader author can never collide with
/// it by naming their own group "~Rack".
///
/// Verified against both halves of the directive, not assumed:
///
///  - `#slots`' own name validator (`MirageSlots.h`, `nameRe`) is
///    `^[A-Za-z0-9][A-Za-z0-9 ._-]*$` - it must START with a letter or digit.
///    `~` is in neither the first-character class nor the body class, so
///    `// #slots name="~Rack"` fails to parse with
///    `MirageSlotsDirectiveErrorName` before a group even exists. There is no
///    way to author this string as a `#slots` group name.
///  - `KKSlotParseLaneKey` (`KKSlotInstances.m`) places NO constraint on the
///    group-name half of a key - it is simply "everything before the first
///    `#`" - so a `~`-prefixed group name round-trips through
///    `KKSlotLaneKey`/`KKSlotParseLaneKey` exactly like any other string. The
///    parser does not reject it; the directive's author-facing validator is
///    what makes it unreachable from user input.
///
/// Both checks are exercised by the harness (`MirageRackModelTests.m`), not
/// just asserted here.
static NSString *const kMirageRackGroupName = @"~Rack";

/// The legacy/implicit first entry's id. Never minted by
/// `KKTimelineStampSlotInstance` (which hands out 6-hex-char ids), and never
/// written to the registry array itself - a project that predates the rack
/// has NO `~Rack` entry in `slotGroups` at all, and `MirageRackEntryIDs`
/// synthesizes `@[kMirageRackSentinelEntryID]` for that case. A project that
/// HAS been racked (the user added a second entry) gets the sentinel written
/// explicitly as the registry's first id, so ordering and removal work
/// uniformly across every entry including it.
static NSString *const kMirageRackSentinelEntryID = @"0";

/// The rack's entries, in display/render order.
/// `slotGroups[kMirageRackGroupName]` when the timeline has one and it isn't
/// empty; otherwise the single-entry answer every pre-rack project implies:
/// `@[kMirageRackSentinelEntryID]`.
///
/// Never writes. A timeline that has never been racked is not mutated just by
/// asking this question - the caller decides whether "add a real registry
/// entry for the sentinel" is worth doing (only once the user adds entry #2).
static inline NSArray<NSString *> *
MirageRackEntryIDs(KKTimeline *_Nullable timeline) {
  NSArray<NSString *> *ids =
      timeline ? KKTimelineSlotInstanceIDs(timeline, kMirageRackGroupName)
               : @[];
  return ids.count ? ids : @[ kMirageRackSentinelEntryID ];
}

/// Whether the transient render blob must retain explicit rack identity.
/// A lone sentinel is the legacy layout. A lone MINTED entry is different: it
/// is what remains after deleting entry 1, and its scoped code lane must not be
/// evaluated/encoded as the now-absent sentinel (which would seed Plasma).
static inline BOOL
MirageRackRequiresExplicitBlob(NSArray<NSString *> *entryIDs) {
  return entryIDs.count != 1 ||
         ![entryIDs.firstObject isEqualToString:kMirageRackSentinelEntryID];
}

/// One control's lane key for one rack entry: `bareKey` unchanged for the
/// sentinel (so every pre-rack project's lanes - and every link expression,
/// palette group, or OSC element key that names one - keep matching byte for
/// byte), `KKSlotLaneKey(kMirageRackGroupName, entryID, bareKey)` otherwise.
///
/// NEVER rewrite a sentinel key to a prefixed one, even internally: lane keys
/// are load-bearing well past the lane itself (link-bus expressions
/// `${uuid.layerID.label}`-style references, `visibleWhenKey`/
/// `maxControllerKey` gates, palette groups), and every one of those sites
/// resolves by exact string match.
static inline NSString *MirageRackLaneKey(NSString *entryID,
                                          NSString *bareKey) {
  if (!bareKey.length)
    return bareKey ?: @"";
  if (!entryID.length || [entryID isEqualToString:kMirageRackSentinelEntryID])
    return bareKey;
  return KKSlotLaneKey(kMirageRackGroupName, entryID, bareKey);
}

/// Inverse of `MirageRackLaneKey`. A key that IS shaped like
/// `~Rack#<id>.<rest>` yields that id and `<rest>` (which may itself contain
/// further `#`/`.` - a nested `#slots` key inside the entry - see the round-
/// trip note on `MirageRackScopedSlotGroupName`). Any other key, including
/// every bare pre-rack key, belongs to the sentinel and passes through
/// unchanged as `outBareKey`.
///
/// Always succeeds (returns YES) - unlike `KKSlotParseLaneKey`, "not a rack
/// key" is not an error here, it is the sentinel's normal shape. Out params
/// are optional.
static inline BOOL
MirageRackParseLaneKey(NSString *key, NSString *_Nullable *_Nullable outEntryID,
                       NSString *_Nullable *_Nullable outBareKey) {
  NSString *group = nil, *entryID = nil, *bareKey = nil;
  if (key.length && KKSlotParseLaneKey(key, &group, &entryID, &bareKey) &&
      [group isEqualToString:kMirageRackGroupName]) {
    if (outEntryID)
      *outEntryID = entryID;
    if (outBareKey)
      *outBareKey = bareKey;
    return YES;
  }
  if (outEntryID)
    *outEntryID = kMirageRackSentinelEntryID;
  if (outBareKey)
    *outBareKey = key ?: @"";
  return YES;
}

/// `entryID` if it names one, the sentinel otherwise. The "which entry am I
/// talking about" default, which is the same answer everywhere it is asked: an
/// empty/absent selection is the pre-selection state AND the only entry an
/// unracked project has, so a project that has never been racked resolves
/// exactly what it always did.
static inline NSString *
MirageRackEntryIDOrSentinel(NSString *_Nullable entryID) {
  return entryID.length ? entryID : (NSString *)kMirageRackSentinelEntryID;
}

/// A bare (shader-authored) key placed in `entryID`'s namespace, IDEMPOTENTLY:
/// a key that ALREADY names an entry is handed back untouched, so a call site
/// may hand over either half of the boundary without checking first (a snapshot
/// lane's `maxControllerKey` arrives pre-scoped, an expression's reference to a
/// sibling uniform arrives bare).
///
/// Distinct from `MirageRackLaneKey`, which is the unconditional composition:
/// scoping a `~Rack#a.uOrigin` key to entry `b` through that would produce
/// `~Rack#b.~Rack#a.uOrigin`. This is the guard both OSC runtimes need, so
/// it lives here rather than being spelled out twice
/// (`-[MirageOSC _scopedKey:]`, `-[MirageMiniViewerRenderer _oscScopedKey:]`).
static inline NSString *MirageRackScopedLaneKey(NSString *entryID,
                                                NSString *key) {
  if (!key.length)
    return key;
  NSString *owner = nil;
  MirageRackParseLaneKey(key, &owner, NULL);
  // Already another entry's: the key is at its destination already.
  if (![owner isEqualToString:kMirageRackSentinelEntryID])
    return key;
  return MirageRackLaneKey(MirageRackEntryIDOrSentinel(entryID), key);
}

/// The `slotGroups` registry key for a `#slots` group declared INSIDE one
/// rack entry's template: the bare group name for the sentinel (so a template
/// that predates the rack keeps registering its `#slots` groups exactly as it
/// always has), `~Rack#<id>.<groupName>` otherwise - so two entries running
/// the same template (two "Grade" instances, say, each with its own `#slots
/// name="Colours"` block) mint and track SEPARATE instance registries instead
/// of one shared one.
///
/// This is a registry key, not a lane key - it never goes through
/// `KKSlotParseLaneKey` itself, only `KKSlotLaneKey`'s composition half - so
/// it does not need to satisfy that parser's round-trip contract on its own.
/// It composes with `MirageRackLaneKey`/`MirageRackParseLaneKey` correctly
/// anyway: a lane inside the nested group gets key
/// `MirageRackLaneKey(entryID, KKSlotLaneKey(groupName, instanceID, control))`,
/// i.e. `~Rack#<entryID>.<groupName>#<instanceID>.<control>`, and
/// `MirageRackParseLaneKey` peels the OUTER `~Rack#<entryID>.` layer to
/// recover `<groupName>#<instanceID>.<control>` verbatim - because
/// `KKSlotParseLaneKey` matches the group name up to the FIRST `#` and the
/// control key as everything after the FIRST `.` following THAT `#`, and a
/// minted instance id never contains a `.`, so nothing after the outer id's
/// dot is mistaken for part of it.
static inline NSString *MirageRackScopedSlotGroupName(NSString *entryID,
                                                      NSString *groupName) {
  if (!groupName.length)
    return groupName ?: @"";
  if (!entryID.length || [entryID isEqualToString:kMirageRackSentinelEntryID])
    return groupName;
  return KKSlotLaneKey(kMirageRackGroupName, entryID, groupName);
}

/// The key of one entry's code lane: bare `kMirageCodeLaneLabel` for the
/// sentinel (matching every persisted project), `~Rack#<id>.Mirage`
/// otherwise. `codeLaneLabel` is passed in rather than hardcoded so this
/// header stays Foundation-only and doesn't need to import Mirage's
/// `Constants.h` (which pulls in FxPlug-adjacent declarations) - callers pass
/// `kMirageCodeLaneLabel`.
static inline NSString *MirageRackCodeLaneKey(NSString *entryID,
                                              NSString *codeLaneLabel) {
  return MirageRackLaneKey(entryID, codeLaneLabel);
}

/// The Enabled lane key for one entry: ALWAYS `~Rack#<id>.Enabled`, including
/// for the sentinel. Unlike the code/uniform lanes, this lane is new with the
/// rack - no persisted project has ever written to a bare "Enabled" key for
/// the legacy template - so there is no backward-compat reason to special-
/// case the sentinel, and prefixing it uniformly keeps every entry's Enabled
/// lane found the same way (`MirageRackParseLaneKey` on a real rack key)
/// instead of needing a second lookup path just for entry 0.
static inline NSString *MirageRackEnabledLaneKey(NSString *entryID) {
  return KKSlotLaneKey(kMirageRackGroupName,
                       entryID.length ? entryID : kMirageRackSentinelEntryID,
                       @"Enabled");
}

/// Absence-means-enabled default for a rack entry with no Enabled lane yet
/// (every entry, until the UI that writes one ships). Named rather than a
/// bare `YES` at call sites so "why is a missing lane enabled" has one place
/// to explain it: a rack entry that has never been touched should render
/// exactly like it did before the rack existed.
static const BOOL MirageRackEntryEnabledDefault = YES;

/// Whether `entryID` is switched on at clip fraction `frac`. A toggle lane
/// HOLDS its value until the next keypose, so the answer is the last keypose at
/// or before `frac` - the NEAREST one would flip the entry half an interval
/// early. An entry with no lane at all reads as
/// `MirageRackEntryEnabledDefault`.
///
/// The plain-lane form, shared by the strip's boxes and the mini viewer's
/// chain. The FCP render answers the same question through
/// `KKLinkResolvedLaneValue` (Plugin+RenderState.m), which is the one path an
/// Enabled lane driven by a link expression resolves on - it needs the link
/// bus, which this header deliberately does not pull in.
static inline BOOL
MirageRackEntryEnabledAtFraction(KKTimeline *_Nullable timeline,
                                 NSString *entryID, double frac) {
  NSString *key = MirageRackEnabledLaneKey(entryID);
  for (KKLane *lane in timeline.lanes) {
    if (![lane.key isEqualToString:key])
      continue;
    KKKeyPose *held = lane.keyposes.firstObject;
    for (KKKeyPose *kp in lane.keyposes)
      if (kp.time <= frac + 1e-9)
        held = kp;
    return held ? held.values.firstObject.doubleValue > 0.5
                : MirageRackEntryEnabledDefault;
  }
  return MirageRackEntryEnabledDefault;
}

/// What both viewers show of the chain for this editor-panel session and
/// nothing longer. Never persisted, never a lane and never an undo entry. Only
/// one is active at a time, on one entry, across the whole rack.
typedef NS_ENUM(NSInteger, MirageRackPreviewMode) {
  /// Every enabled entry, in order. What a session starts on.
  MirageRackPreviewModeOff = 0,
  /// The chain TRUNCATED after one entry: what the pipeline has done SO FAR.
  /// Skips still apply, so a disabled entry inside the truncation is still out.
  MirageRackPreviewModeUpToHere,
  /// ONE entry, fed the original clip: what that entry ALONE contributes.
  MirageRackPreviewModeSolo,
};

/// The shared mini/main render plan for the session-only rack preview.
/// `enabledEntryIDs` is the ordinary animated Enabled-lane answer at this
/// frame. Solo deliberately ignores it for its focused entry: Enabled asks
/// whether a shader belongs in the chain, while Solo asks what that shader
/// does by itself. A missing/stale focus safely falls back to the full enabled
/// chain.
static inline NSArray<NSString *> *MirageRackPreviewEntryPlan(
    NSArray<NSString *> *entryIDs, NSSet<NSString *> *enabledEntryIDs,
    MirageRackPreviewMode mode, NSString *_Nullable focusEntryID) {
  NSUInteger focusIndex =
      focusEntryID.length ? [entryIDs indexOfObject:focusEntryID] : NSNotFound;
  if (mode == MirageRackPreviewModeSolo && focusIndex != NSNotFound)
    return @[ entryIDs[focusIndex] ];

  NSUInteger limit = entryIDs.count;
  if (mode == MirageRackPreviewModeUpToHere && focusIndex != NSNotFound)
    limit = focusIndex + 1;

  NSMutableArray<NSString *> *plan = [NSMutableArray array];
  for (NSUInteger i = 0; i < limit; i++)
    if ([enabledEntryIDs containsObject:entryIDs[i]])
      [plan addObject:entryIDs[i]];
  return plan;
}

/// The effective viewer plan after diagnostic overlays are considered.
/// A selection matte describes the SELECTED entry's result, so entries after
/// it must not process that matte. Earlier enabled entries still run because
/// they are the selected shader's real input. A stale selection safely falls
/// back to the ordinary session preview plan.
static inline NSArray<NSString *> *MirageRackViewerEntryPlan(
    NSArray<NSString *> *entryIDs, NSSet<NSString *> *enabledEntryIDs,
    MirageRackPreviewMode mode, NSString *_Nullable focusEntryID,
    BOOL selectionMatteActive, NSString *_Nullable selectedEntryID) {
  if (selectionMatteActive && selectedEntryID.length &&
      [entryIDs containsObject:selectedEntryID])
    return MirageRackPreviewEntryPlan(entryIDs, enabledEntryIDs,
                                      MirageRackPreviewModeUpToHere,
                                      selectedEntryID);
  return MirageRackPreviewEntryPlan(entryIDs, enabledEntryIDs, mode,
                                    focusEntryID);
}

/// One entry's code lane, found by key (`MirageRackCodeLaneKey`) in timeline
/// order. nil if the entry has never had one stamped - a rack entry that
/// exists in the registry but whose lanes haven't been built yet.
static inline KKLane *_Nullable MirageRackCodeLaneForEntry(
    KKTimeline *_Nullable timeline, NSString *entryID,
    NSString *codeLaneLabel) {
  if (!timeline)
    return nil;
  NSString *key = MirageRackCodeLaneKey(entryID, codeLaneLabel);
  for (KKLane *lane in timeline.lanes)
    if ([lane.key isEqualToString:key])
      return lane;
  return nil;
}

/// Whether Original/Split have an incoming-frame comparison anywhere in the
/// rack. This is deliberately rack-wide: selecting a generator after one or
/// more filters does not turn the whole chain into a generator. `fallbackSource`
/// covers the legacy/fresh sentinel before its code lane has been persisted.
static inline BOOL MirageRackHasSourceMatching(
    KKTimeline *_Nullable timeline, NSString *codeLaneLabel,
    NSString *_Nullable fallbackSource,
    BOOL (^matches)(NSString *_Nullable source)) {
  if (!matches)
    return NO;
  NSArray<NSString *> *entryIDs = MirageRackEntryIDs(timeline);
  if (!entryIDs.count)
    return matches(fallbackSource);
  for (NSString *entryID in entryIDs) {
    KKLane *lane =
        MirageRackCodeLaneForEntry(timeline, entryID, codeLaneLabel);
    NSString *source = lane ? lane.codeString : nil;
    if (!lane && [entryID isEqualToString:kMirageRackSentinelEntryID])
      source = fallbackSource;
    if (source.length && matches(source))
      return YES;
  }
  return NO;
}

/// One entry's code as the section array `MirageSchemaDocument` and the AI
/// authoring path expect: `@{@"name": …, @"code": …}`, Image (`codeString`)
/// first, then `codeTabs` verbatim (they are already `@"name"`/`@"code"`
/// dictionaries - see `KKTimeline.h`'s `codeTabs` doc). Empty when the entry
/// has no code lane yet.
static inline NSArray<NSDictionary<NSString *, NSString *> *> *
MirageRackSectionsForEntry(KKTimeline *_Nullable timeline, NSString *entryID,
                           NSString *codeLaneLabel) {
  KKLane *lane = MirageRackCodeLaneForEntry(timeline, entryID, codeLaneLabel);
  if (!lane)
    return @[];
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *sections =
      [NSMutableArray arrayWithObject:@{
        @"name" : @"Image",
        @"code" : lane.codeString ?: @""
      }];
  if (lane.codeTabs.count)
    [sections addObjectsFromArray:lane.codeTabs];
  return sections;
}

/// `entryID`'s display name: the code lane's `codeSaveName` when the entry
/// has been named (a save-bar name survives exactly like any other
/// `codeSavable` value), else `fallbackName` - the caller's template-derived
/// guess (e.g. the template's catalog title), since a freshly-added entry
/// hasn't been named yet and still needs SOMETHING to show in a rack list.
static inline NSString *
MirageRackEntryDisplayName(KKTimeline *_Nullable timeline, NSString *entryID,
                           NSString *codeLaneLabel, NSString *fallbackName) {
  KKLane *lane = MirageRackCodeLaneForEntry(timeline, entryID, codeLaneLabel);
  NSString *saved = lane.codeSaveName;
  return saved.length ? saved : (fallbackName ?: @"");
}

/// Auto-suffixes a list of display names the way a rack list does: the first
/// occurrence of a name keeps it bare, every later occurrence of the SAME
/// name gets " <n>" for its own repeat count (`"Grade"`, `"Grade"`,
/// `"Selective"`, `"Grade"` -> `"Grade"`, `"Grade 2"`, `"Selective"`,
/// `"Grade 3"`). Order-preserving and positional - this is a display
/// transform over a snapshot of names, not an identity; nothing here reads or
/// writes a lane key.
static inline NSArray<NSString *> *
MirageRackDedupedDisplayNames(NSArray<NSString *> *orderedNames) {
  NSMutableDictionary<NSString *, NSNumber *> *seenCount =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *out =
      [NSMutableArray arrayWithCapacity:orderedNames.count];
  for (NSString *name in orderedNames) {
    NSString *key = name ?: @"";
    NSInteger count = seenCount[key].integerValue + 1;
    seenCount[key] = @(count);
    [out addObject:count == 1 ? key
                              : [NSString stringWithFormat:@"%@ %ld", key,
                                                           (long)count]];
  }
  return out;
}

/// Every entry's display name, deduped, in rack order: what the strip labels
/// its boxes with and what the link manifest names the chain by. One helper so
/// the two can never disagree about what an entry is called.
static inline NSArray<NSString *> *
MirageRackDisplayNames(KKTimeline *_Nullable timeline,
                       NSArray<NSString *> *entryIDs, NSString *codeLaneLabel,
                       NSString *fallbackName) {
  NSMutableArray<NSString *> *names =
      [NSMutableArray arrayWithCapacity:entryIDs.count];
  for (NSString *entryID in entryIDs)
    [names addObject:MirageRackEntryDisplayName(timeline, entryID,
                                                codeLaneLabel, fallbackName)];
  return MirageRackDedupedDisplayNames(names);
}

/// Write the rack's order back, replacing whatever `slotGroups` held for it and
/// leaving every other group alone. `entryIDs` is the whole registry, so this
/// is also how a removal and a reorder both land.
///
/// An EMPTY array is refused rather than written: the rack always has at least
/// one entry, and a `~Rack` group registered as empty reads as "racked" to the
/// Phase 2 gates while `MirageRackEntryIDs` synthesizes a sentinel that nothing
/// registered - the one state where the two disagree.
static inline BOOL MirageRackSetEntryIDs(KKTimeline *timeline,
                                         NSArray<NSString *> *entryIDs) {
  if (!timeline || !entryIDs.count)
    return NO;
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *groups =
      [(timeline.slotGroups ?: @{}) mutableCopy];
  if ([groups[kMirageRackGroupName] isEqualToArray:entryIDs])
    return NO;
  groups[kMirageRackGroupName] = [entryIDs copy];
  timeline.slotGroups = groups;
  return YES;
}

/// The first rack mutation on a project that predates the rack: write the
/// implicit entry into the registry explicitly, so ordering and removal treat
/// it like any other entry from here on.
///
/// Deliberately NOT called on read. A project the user never adds a second
/// shader to keeps an absent registry forever, which is what makes the whole
/// retrofit invisible to it.
static inline BOOL MirageRackRegisterSentinelIfNeeded(KKTimeline *timeline) {
  if (!timeline ||
      KKTimelineSlotInstanceIDs(timeline, kMirageRackGroupName).count > 0)
    return NO;
  return MirageRackSetEntryIDs(timeline, @[ kMirageRackSentinelEntryID ]);
}

/// `entryIDs` with `entryID` lifted out and re-inserted so it lands at
/// `toIndex` in the FINAL array (the index the drop line pointed at, counted
/// before the removal - the caller passes what the UI measured, and the shift
/// is applied here).
///
/// Pure: no timeline, no keys, no keyposes. Reordering the rack is a
/// permutation of this array and nothing else, which is the whole reason entry
/// identity is an opaque minted id rather than a position.
static inline NSArray<NSString *> *
MirageRackReorderedEntryIDs(NSArray<NSString *> *entryIDs, NSString *entryID,
                            NSInteger toIndex) {
  NSUInteger from = [entryIDs indexOfObject:entryID ?: @""];
  if (from == NSNotFound)
    return entryIDs;
  NSMutableArray<NSString *> *out = [entryIDs mutableCopy];
  [out removeObjectAtIndex:from];
  NSInteger target = toIndex > (NSInteger)from ? toIndex - 1 : toIndex;
  target = MAX((NSInteger)0, MIN(target, (NSInteger)out.count));
  [out insertObject:entryID atIndex:(NSUInteger)target];
  return out;
}

/// Whether `laneKey` is one of `entryID`'s lanes - the removal filter.
///
/// Goes through `MirageRackParseLaneKey`, so for the sentinel it answers YES
/// for every BARE key (which is exactly what the sentinel owns) and NO for
/// another entry's prefixed one, including that entry's `~Rack#<id>.Enabled`.
static inline BOOL MirageRackLaneKeyBelongsToEntry(NSString *laneKey,
                                                   NSString *entryID) {
  NSString *owner = nil;
  MirageRackParseLaneKey(laneKey ?: @"", &owner, NULL);
  return [owner
      isEqualToString:entryID.length ? entryID : kMirageRackSentinelEntryID];
}

/// Drop one entry: its registry slot, every lane that parses to it (its code
/// lane, its Enabled lane, every control the template built) and every `#slots`
/// registry group scoped to it (`MirageRackScopedSlotGroupName`), so two
/// entries running the same template don't leave one another's instance lists
/// behind.
///
/// Refuses to remove the LAST entry - a rack with no entries renders nothing
/// and has no code lane to edit, so "remove" would be "delete the effect".
/// Mutates in place; returns YES when the timeline changed.
static inline BOOL MirageRackRemoveEntry(KKTimeline *timeline,
                                         NSString *entryID) {
  if (!timeline || !entryID.length)
    return NO;
  NSArray<NSString *> *ids = MirageRackEntryIDs(timeline);
  if (![ids containsObject:entryID] || ids.count < 2)
    return NO;

  NSMutableArray<NSString *> *remaining = [ids mutableCopy];
  [remaining removeObject:entryID];
  MirageRackSetEntryIDs(timeline, remaining);

  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  for (KKLane *lane in timeline.lanes)
    if (!MirageRackLaneKeyBelongsToEntry(lane.key, entryID))
      [lanes addObject:lane];
  timeline.lanes = lanes;

  // The entry's nested `#slots` registries. Scoped group names are themselves
  // rack-prefixed, so the same parse identifies them - except for the sentinel,
  // whose nested groups are BARE names indistinguishable from another entry's
  // would-be groups. The sentinel's are the only bare ones there can be (every
  // other entry's are prefixed), so removing the sentinel takes every unscoped
  // group with it, which is precisely the set its lanes belonged to.
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *groups =
      [(timeline.slotGroups ?: @{}) mutableCopy];
  for (NSString *group in groups.allKeys) {
    if ([group isEqualToString:kMirageRackGroupName])
      continue;
    if (MirageRackLaneKeyBelongsToEntry(group, entryID))
      [groups removeObjectForKey:group];
  }
  timeline.slotGroups = groups;
  return YES;
}

NS_ASSUME_NONNULL_END
