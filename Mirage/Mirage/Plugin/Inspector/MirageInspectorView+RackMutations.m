/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The four things the user can do to the shader chain.
//
// Every mutation has the same shape, and it is the shape the `#slots` panel
// established (MirageColorPanelController+Slots.m): copy the timeline, change
// exactly one thing in the copy, hand it to `onTimelineMutated` ONCE. That one
// call is one `kkInParamAction` scope, which is one FCP undo entry - so an add
// / remove / reorder / enable is a single Cmd-Z, and no intermediate state is
// ever persisted.

#import "MirageInspectorView_Private.h"

#import "Constants.h"
#import "MirageLaneCatalog.h" // MirageRackEnabledLane
#import "MirageLocalCatalog.h"
#import "MirageOSCSnapshot.h"
#import "MirageRack.h"

#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSlotInstances.h>

@implementation MirageInspectorView (RackMutations)

// One entry more. On a project that predates the rack this is also the moment
// the implicit first entry becomes an explicit registry entry - both go in the
// SAME timeline copy, so the pair is one undo entry and there is no in-between
// state where the sentinel is registered but the new shader isn't.
//
// "+" does NOT ask which template. It adds a link running the DEFAULT shader,
// selected, so the click produces a box on screen with a picture in it. Picking
// a template is a separate verb, and it now has a home: the browser writes
// whatever the strip has SELECTED, so "add, then pick" is two obvious steps
// while "pick, then get an add you can't see yet" was one confusing one. The
// source view is the "+" itself, unused now that nothing is anchored to it.
- (void)_rackAddFromView:(NSView *)sourceView {
  (void)sourceView;
  KKTimeline *current = self.basicLanesView.currentTimeline;
  if (!current)
    return;
  KKTimeline *updated = [current copy];
  MirageRackRegisterSentinelIfNeeded(updated);

  NSString *newID = KKTimelineStampSlotInstance(
      updated, kMirageRackGroupName, @[ [self _rackDefaultCodeLanePrototype] ]);
  if (!newID.length) {
    KKLogWarn(@"[Rack] append minted no entry id - nothing added");
    return;
  }
  KKLogInfo(@"[Rack] appended default shader as entry %@ (%lu now)", newID,
            (unsigned long)MirageRackEntryIDs(updated).count);
  // Commit BEFORE selecting, unlike every other mutation here. A selection is
  // re-derived against the lanes view's LIVE timeline, and until the commit
  // lands that timeline's registry has never heard of this entry - so the
  // derive returns no template for it, the constants popover's rack-scoped row
  // set comes back EMPTY, and an empty row set is what
  // -[_KKStaticValuesPopoverView updateUnoptedLanes:] closes the popover on.
  // "+" therefore dismissed the very popover it was appending into. Committed
  // first, the entry exists before anything asks what it owns.
  KKLogDebug(@"[Rack] append: commit before select so entry %@ has lanes to "
             @"scope the constants rows to",
             newID);
  // The selection rides INSIDE the commit's action scope, so the chain and the
  // entry the user lands on are one undo entry - Cmd-Z takes back the append
  // and puts them back on the entry they were editing, in one step. The
  // in-memory move still happens after the commit, for the reason above.
  [self commitRackTimeline:updated selecting:newID];
  [self _rackSelectEntry:newID persist:NO];
}

// What a freshly appended entry is stamped with: ONLY the code lane. Every
// control the shader declares is derived from that code on the next lane build,
// seeded at its declared default - stamping them here would freeze today's
// defaults into the project.
- (KKLane *)_rackDefaultCodeLanePrototype {
  KKLane *prototype = [KKLane laneWithKey:kMirageCodeLaneLabel
                                    label:kMirageCodeLaneLabel];
  prototype.valueType = KKLaneValueTypeCode;
  prototype.codeString = MirageCustomDefaultShaderSource();
  // A code lane is a text field, not a curve. `laneWithKey:` hands back an
  // ENABLED lane (the kit's default) and "enabled" means ANIMATED - a stamped
  // one therefore landed in the Animated section, with a row in the sequencer
  // it can never be keyframed on. The seeding path spells both of these out for
  // the sentinel's code lane (KKTimelineLanesView -_timelineSeededFrom:); a
  // stamped instance skips that path entirely, so it has to say so itself.
  prototype.animatable = NO;
  prototype.enabled = NO;
  return prototype;
}

- (void)_rackRemoveEntry:(NSString *)entryID {
  KKTimeline *current = self.basicLanesView.currentTimeline;
  if (!current || !entryID.length)
    return;
  NSArray<NSString *> *ids = MirageRackEntryIDs(current);
  NSUInteger doomed = [ids indexOfObject:entryID];
  if (doomed == NSNotFound || ids.count < 2)
    return;
  KKTimeline *updated = [current copy];
  if (!MirageRackRemoveEntry(updated, entryID))
    return;
  // Where the selection lands: the entry before this one, or the one after it
  // when the first is going. Never "none" - the rack always has a row.
  NSString *survivor = doomed > 0 ? ids[doomed - 1] : ids[1];
  [self _rackSelectEntry:survivor persist:NO];
  KKLogInfo(@"[Rack] removed entry %@ (%lu left)", entryID,
            (unsigned long)MirageRackEntryIDs(updated).count);
  // Folded into the commit for the same reason the append's is: undoing a
  // removal brings the entry back AND puts the user back on it, once.
  [self commitRackTimeline:updated selecting:survivor];
}

// Registry permutation and NOTHING else: no key is rewritten, no keypose moves.
// That is the whole reason an entry's identity is a minted id - a chain reorder
// can't touch a single value the user has set.
- (void)_rackMoveEntry:(NSString *)entryID toIndex:(NSInteger)index {
  KKTimeline *current = self.basicLanesView.currentTimeline;
  if (!current || !entryID.length)
    return;
  KKTimeline *updated = [current copy];
  // A project still on the implicit sentinel has one entry and nothing to
  // reorder, but registering first keeps the write shape identical either way.
  MirageRackRegisterSentinelIfNeeded(updated);
  NSArray<NSString *> *reordered =
      MirageRackReorderedEntryIDs(MirageRackEntryIDs(updated), entryID, index);
  if (!MirageRackSetEntryIDs(updated, reordered))
    return;
  KKLogInfo(@"[Rack] moved entry %@ to %ld -> %@", entryID, (long)index,
            [reordered componentsJoinedByString:@","]);
  [self commitRackTimeline:updated];
}

// Enabling is a KEYPOSE write, not a flag: switching a shader out part-way
// through a clip is a cut, and a cut is a keyframe. The keypose nearest the
// playhead is the one edited (the shared "which keypose does this interaction
// mean" rule); an entry whose lane doesn't exist yet gets the template's,
// seeded at the value being asked for.
- (void)_rackSetEntry:(NSString *)entryID enabled:(BOOL)enabled {
  KKTimeline *current = self.basicLanesView.currentTimeline;
  if (!current || !entryID.length)
    return;
  KKTimeline *updated = [current copy];
  MirageRackRegisterSentinelIfNeeded(updated);
  NSString *key = MirageRackEnabledLaneKey(entryID);
  NSArray<NSNumber *> *values = @[ @(enabled ? 1.0 : 0.0) ];
  NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
  BOOL found = NO;
  for (NSUInteger i = 0; i < lanes.count; i++) {
    if (![lanes[i].key isEqualToString:key])
      continue;
    lanes[i] = KKLaneBySettingValuesNearestFraction(
        lanes[i], [self playheadFractionForRack], values);
    found = YES;
    break;
  }
  if (!found) {
    KKLane *lane = MirageRackEnabledLane(entryID);
    lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
    [lanes addObject:lane];
  }
  updated.lanes = lanes;
  KKLogInfo(@"[Rack] entry %@ %@", entryID, enabled ? @"enabled" : @"disabled");
  [self commitRackTimeline:updated];
}

// The one write path. `onTimelineMutated` opens a single action scope (timeline
// blob + render nudge), which FCP records as one undo entry; the lane set is
// re-derived first because a rack change moves what the rows ARE - a new
// entry's controls, a removed entry's rows - and the filter that decides which
// rows show runs inside -applyTimeline:.
- (void)commitRackTimeline:(KKTimeline *)updated {
  [self commitRackTimeline:updated selecting:nil];
}

- (void)commitRackTimeline:(KKTimeline *)updated
                 selecting:(NSString *)selectEntryID {
  MirageSetTimelineSnapshot(updated);
  if (self.availableLanesProvider) {
    NSArray<KKLane *> *lanes = self.availableLanesProvider(@"", updated);
    if (lanes)
      [self applyAvailableLanes:lanes];
  }
  // A mutation that moves the selection writes BOTH in one action scope; the
  // plain hook (which the kit installs) is for the ones that don't.
  if (selectEntryID.length && self.onRackTimelineMutatedSelecting)
    self.onRackTimelineMutatedSelecting(updated, selectEntryID);
  else if (self.onTimelineMutated)
    self.onTimelineMutated(updated);
  [self applyTimeline:updated];
  [self refreshRack];
}

@end
