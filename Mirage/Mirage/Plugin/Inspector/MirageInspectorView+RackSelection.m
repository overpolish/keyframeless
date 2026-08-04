/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Which entry of the shader chain the inspector is on. The selection is what
// every scoped surface derives from - the lane set, both dropdowns, the
// constants popover's rows, the Color panel, the on-screen controls - so moving
// it is a re-derive of all of them and a write of nothing but the selection
// itself.

#import "MirageInspectorView_Private.h"

#import "MirageInspectorChrome.h" // MirageFindMiniViewer
#import "MirageRack.h"

#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPluginInstanceState.h>
#import <KeyframelessKit/KKSlotInstances.h>

@implementation MirageInspectorView (RackSelection)

- (void)_guidePrepareDefaultRackSelection {
  if (_guideRackSelectionActive)
    return;
  _guideRackSelectionActive = YES;
  _guideSavedRackSelectionID = [self.selectedRackEntryID copy];
  [self _rackSelectEntry:kMirageRackSentinelEntryID persist:NO];
}

- (void)_guideRestoreRackSelection {
  if (!_guideRackSelectionActive)
    return;
  NSString *saved = _guideSavedRackSelectionID;
  _guideSavedRackSelectionID = nil;
  _guideRackSelectionActive = NO;
  [self _rackSelectEntry:(saved.length ? saved : kMirageRackSentinelEntryID)
                 persist:NO];
}

- (void)_rackSelectEntry:(NSString *)entryID persist:(BOOL)persist {
  if (!entryID.length)
    return;
  // A keypose popover edits ONE moment: an entry with no keypose there has
  // nothing to show, so selecting it would swap the editor for an empty one.
  // The kit names the entries that do (the same set Canvas grays its layer list
  // with), and everything outside it is inert for as long as the popover is up.
  // Only a USER click is refused - the internal moves (a removal's survivor, a
  // restore, an append) pass persist:NO and must always land.
  NSSet<NSString *> *editable =
      [self.basicLanesView openKeyposePopoverLayerKeys];
  if (persist && editable.count && ![editable containsObject:entryID])
    return;
  BOOL moved = ![entryID isEqualToString:self.selectedRackEntryID ?: @""];
  self.selectedRackEntryID = entryID;
  // Same process as the OSC and the AI author, so this is where they read which
  // entry the inspector is on. `Ensure` rather than the plain lookup: on a
  // never-touched instance the UUID may not have been minted yet, and a nil
  // state would silently drop the selection.
  KKPluginInstanceState *state = KKInstanceStateEnsureForAPI(_thumbAPIManager);
  state.selectedRackEntryID = entryID;
  if (!moved)
    return;
  [self rackSelectionDidChange];
  if (!persist)
    return;
  // A project with no registry has exactly one implicit entry, so there is no
  // selection to remember and a legacy project must see no new writes at all.
  if (!KKTimelineSlotInstanceIDs(self.basicLanesView.currentTimeline,
                                 kMirageRackGroupName)
           .count)
    return;
  if (self.onRackSelectionPersist)
    self.onRackSelectionPersist(entryID);
}

// Everything scoped to the selection, re-driven. Re-derivation only: the
// timeline goes back in unchanged and every lane keeps its full prefixed key,
// so the ONE param this costs is the selection itself (written by the caller,
// and only when the user asked for the move) - never a lane rewrite.
//
// The timeline it re-derives against is the lanes view's LIVE one, so a
// mutation that also moves the selection has to have landed its commit first
// whenever the new selection is an entry that did not exist before (append).
// A removal moves to a SURVIVOR, which the pre-mutation timeline already
// describes, so it keeps selecting first. Both orders are idempotent
// re-derives; only the append order is load-bearing.
- (void)rackSelectionDidChange {
  KKTimeline *timeline = self.basicLanesView.currentTimeline;
  if (!timeline)
    return;
  // The lane set is a function of the selection now: the editor's uncommitted
  // code belongs to the SELECTED entry (MirageBuildAvailableLanesForRack's
  // `overrideEntryID`), so a selection move re-derives it.
  if (self.availableLanesProvider) {
    NSArray<KKLane *> *lanes = self.availableLanesProvider(@"", timeline);
    if (lanes)
      [self applyAvailableLanes:lanes];
  }
  // The kit's keypose popovers and both dropdowns scope by activeLayerKey, so
  // the strip's selection IS the active layer while the instance is racked.
  // Unracked keeps nil - the lanes carry no layerKey to match it against.
  self.basicLanesView.activeLayerKey =
      KKTimelineSlotInstanceIDs(timeline, kMirageRackGroupName).count
          ? self.selectedRackEntryID
          : nil;
  // Re-drives the rows, and with them the open constants popover's un-opted
  // set - which is what the scope filter is read from.
  [self.basicLanesView applyTimeline:timeline];
  // The Color panel is derived from ONE entry's source: a selection move is the
  // same event to it as a recompile.
  [_colorPanelController setSelectedRackEntryID:self.selectedRackEntryID];
  // The OSC surfaces are the plugin's, not the view's: the viewer's controls
  // re-derive themselves off the per-instance selection on their next tick, but
  // the visibility CHECKLIST and the mini viewer's control sets are pushed, so
  // they need telling.
  if (self.onRackSelectionChanged)
    self.onRackSelectionChanged(self.selectedRackEntryID);
  // AFTER the push, so the repaint draws the new entry's handles rather than
  // the old ones one frame longer.
  [MirageFindMiniViewer(_rackView.window.contentView ?: _rackView)
      setNeedsDisplay:YES];
}

- (BOOL)rackShowsLaneInConstants:(KKLane *)lane {
  KKTimeline *timeline = self.basicLanesView.currentTimeline;
  // Unracked: one implicit entry owns every lane, so there is nothing to scope
  // and the popover must be byte-identical to what it always was.
  if (!KKTimelineSlotInstanceIDs(timeline, kMirageRackGroupName).count)
    return YES;
  NSString *selected = self.selectedRackEntryID.length
                           ? self.selectedRackEntryID
                           : MirageRackEntryIDs(timeline).firstObject;
  return MirageRackLaneKeyBelongsToEntry(lane.key, selected);
}

- (void)applyPersistedRackSelection:(NSString *)entryID {
  KKTimeline *live = self.basicLanesView.currentTimeline;
  // Absent or empty is the BASELINE, not "leave it alone": it is the state the
  // project was in before any selection was ever persisted, and the only way to
  // have more than one entry is an append - which always persists one. So the
  // baseline is the first entry, and undoing back past the first selection
  // returns there rather than sticking on the last click.
  NSString *restored =
      entryID.length ? entryID : MirageRackEntryIDs(live).firstObject;
  if (!restored.length) {
    _pendingRackSelectionID = nil;
    return;
  }
  if ([restored isEqualToString:self.selectedRackEntryID ?: @""]) {
    _pendingRackSelectionID = nil;
    return;
  }
  if (live && ![MirageRackEntryIDs(live) containsObject:restored]) {
    // Undo of an append reverts the UI-state blob and the timeline blob as two
    // parameter changes, and this one can arrive first. Hold the value rather
    // than dropping it: -refreshRack adopts it the moment the registry agrees.
    _pendingRackSelectionID = [restored copy];
    return;
  }
  _pendingRackSelectionID = nil;
  [self _rackSelectEntry:restored persist:NO];
  [self refreshRack];
}

@end
