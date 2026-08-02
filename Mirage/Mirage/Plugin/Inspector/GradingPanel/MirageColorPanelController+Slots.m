/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageColorPanelController.h"

#import <KeyframelessKit/KKFloatingPanel.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

#import "MirageColorPanelController_Internal.h"
#import "MirageColorSurfaceProps.h"
#import "MirageLocalized.h"
#import "MirageSlotSurface.h"
#import "MirageSurfaceCircleView.h"
#import "MirageSurfaceResponse.h"
#import "Plugin_Private.h" // +shaderSourceFromTimeline: / slot prototypes

@implementation MirageColorPanelController (Slots)

// Every grammar lookup the panel makes goes through one of these four, so the
// crossing from "what the source declares" to "what this project has" happens
// in one place rather than at eleven call sites - eight of which would have
// looked correct while quietly addressing a prototype no lane answers to.

- (NSDictionary<NSString *, NSValue *> *)_responsesForRing:(NSUInteger)ringIndex
                                                    source:(NSString *)source {
  return MirageSlotExpandResponses(
      MirageSurfaceResponsesForRing(source, [self _ringAtIndex:ringIndex]),
      source, [self _entryScopedRegistry]);
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)
    _pucksForRing:(NSUInteger)ringIndex
           source:(NSString *)source {
  return MirageSlotExpandPucks(
      MirageSurfacePucksForRing(source, [self _ringAtIndex:ringIndex]), source,
      [self _entryScopedRegistry]);
}

- (NSDictionary<NSString *, NSNumber *> *)_picksInSource:(NSString *)source {
  return MirageSlotExpandPicks(MirageSurfacePicksForSource(source), source,
                               [self _entryScopedRegistry]);
}

- (NSDictionary<NSString *, NSString *> *)_puckNamesInSource:
    (NSString *)source {
  return MirageSlotExpandPuckNames(MirageSurfacePuckNamesForSource(source),
                                   source, [self _entryScopedRegistry]);
}

/// Whether this shader declares two circles, which is the only case where a
/// handle has to say which one it is on.
- (BOOL)_filtersByRing:(NSString *)source {
  return MirageColorSurfaceRingsForSource(source).count > 1;
}

/// The group the "+" would add to: one that puts a handle on the ring
/// click-to-pick answers to, and is not already full.
///
/// Bound to that ring rather than to "any ring" because adding an instance
/// selects its new handle, and selecting a handle on a circle the gesture does
/// not answer to would arm a pick nothing could receive.
- (NSString *)_addableSlotGroupInSource:(NSString *)source {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline)
    return nil;
  NSUInteger ringIndex = [self _pickRingIndex];
  for (NSString *group in MirageSlotGroupsWithPuckOnRing(
           source, [self _ringAtIndex:ringIndex],
           [self _filtersByRing:source])) {
    NSInteger max = 0, min = 0;
    MirageSlotGroupLimits(source, group, &max, &min);
    // The registry is keyed per rack entry, so two links running the same
    // template count their instances separately
    // (MirageRackScopedSlotGroupName). The group NAME stays the shader's - it
    // is what the source declared and what every expansion above speaks.
    if ((NSInteger)KKTimelineSlotInstanceIDs(timeline,
                                             [self _scopedSlotGroup:group])
            .count < max)
      return group;
  }
  return nil;
}

/// The expanded puck entry the user last touched on the pick ring, or nil when
/// that handle is not a slot instance.
- (NSDictionary<NSString *, NSString *> *)_activeSlotPuckInSource:
    (NSString *)source {
  NSUInteger ringIndex = [self _pickRingIndex];
  if (ringIndex >= _circles.count)
    return nil;
  NSArray<NSDictionary<NSString *, NSString *> *> *pucks =
      [self _pucksForRing:ringIndex source:source];
  NSUInteger active = _circles[ringIndex].activePuck;
  if (active >= pucks.count)
    return nil;
  return pucks[active][@"instance"].length ? pucks[active] : nil;
}

/// Move the selection to the handle belonging to `instanceID`, so the instance
/// the user just added (or the survivor of one they removed) is the one the
/// panel is talking about.
- (void)_selectSlotPuckForInstance:(NSString *)instanceID
                            source:(NSString *)source {
  NSUInteger ringIndex = [self _pickRingIndex];
  if (ringIndex >= _circles.count)
    return;
  NSArray<NSDictionary<NSString *, NSString *> *> *pucks =
      [self _pucksForRing:ringIndex source:source];
  for (NSUInteger i = 0; i < pucks.count; i++) {
    if (![pucks[i][@"instance"] isEqualToString:instanceID ?: @""])
      continue;
    _circles[ringIndex].activePuck = i;
    [_circles[ringIndex] setNeedsDisplay:YES];
    return;
  }
  // The instance is gone (a removal) and nothing replaced it at that index:
  // fall back to the first handle rather than leaving the selection pointing
  // past the end, which draws no active puck at all.
  if (_circles[ringIndex].activePuck >= pucks.count)
    _circles[ringIndex].activePuck = 0;
}

/// Re-derive the inspector's lane TEMPLATES from the source it already has.
///
/// The rows are gated on a template existing (`hidesLanesWithoutTemplate`), and
/// a stamped instance's lanes are new keys - so without this the instance is in
/// the timeline, in the render, and invisible in the inspector until the panel
/// is reopened. Routed through the lanes view's code-commit block because that
/// is the one path that re-runs the catalog and swaps the rows live; the source
/// has not changed, only how many instances it stands for.
- (void)_reloadLaneTemplatesForSource:(NSString *)source {
  void (^commit)(NSString *) = _lanesView.onCodeCommitted;
  if (commit)
    commit(source);
}

// One instance more.
//
// The whole gesture is "+ then click": the new colour is added, its handle
// becomes the one the panel is talking about, and the picker is armed - so the
// next click in the preview aims THIS instance at whatever it landed on. Adding
// a slot that then has to be found and selected before it can be used would be
// three gestures for the one thing the user meant.
- (void)_addSlotInstance:(id)sender {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline)
    return;
  NSString *source = [self _entrySource:timeline];
  NSString *group = [self _addableSlotGroupInSource:source];
  if (!group.length)
    return;
  NSArray<KKLane *> *prototypes =
      [MiragePlugin slotPrototypeLanesForShaderSource:source group:group];
  if (!prototypes.count) {
    KKLogWarn(@"[Slots] \"%@\" declares no controls to stamp", group);
    return;
  }
  // A drag whose mouse-up went astray would otherwise still be open, and FCP's
  // channel lock raises on a group opened inside one that never closed.
  [self _endPuckDragReason:@"a slot instance was added"];
  KKTimeline *updated = [timeline copy];
  NSString *scoped = [self _scopedSlotGroup:group];
  NSString *instanceID =
      KKTimelineStampSlotInstance(updated, scoped, prototypes);
  if (!instanceID.length)
    return;
  KKLogInfo(@"[Slots] adding \"%@\" instance %@ (%lu now)", scoped, instanceID,
            (unsigned long)KKTimelineSlotInstanceIDs(updated, scoped).count);
  [self _beginWriteGroup:@"add slot instance"];
  if (self.onTimelineMutated)
    self.onTimelineMutated(updated);
  [self _endWriteGroup:@"add slot instance"];
  [self _reloadLaneTemplatesForSource:source];
  [self _refreshPuck];
  [self _selectSlotPuckForInstance:instanceID source:source];
  [self _refreshPuck];
  // Arm through the ordinary path, and only from disarmed, so this composes
  // with the other two picks instead of becoming a fourth armed state: whatever
  // was armed is dropped first, exactly as pressing the button would.
  [self _disarmPicking];
  [self _togglePickFromClip:sender];
}

// One instance fewer: the handle the user last touched.
//
// Its lanes and its registry entry go, and nothing else does. Every other
// instance keeps its ID and its keyframes - only the numbers they are DISPLAYED
// under shift, which is the whole reason the keys are not derived from
// position.
- (void)_removeSlotInstance:(id)sender {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline)
    return;
  NSString *source = [self _entrySource:timeline];
  NSDictionary<NSString *, NSString *> *entry =
      [self _activeSlotPuckInSource:source];
  NSString *group = entry[@"group"], *instanceID = entry[@"instance"];
  if (!group.length || !instanceID.length)
    return;
  NSInteger max = 0, min = 0;
  MirageSlotGroupLimits(source, group, &max, &min);
  NSString *scoped = [self _scopedSlotGroup:group];
  NSArray<NSString *> *ids = KKTimelineSlotInstanceIDs(timeline, scoped);
  if ((NSInteger)ids.count <= min)
    return;
  // Where the selection lands: the instance before this one, or the one after
  // it when the first is being removed. Never "none", since an unselected
  // circle has nothing to read out and no handle to pick with.
  NSUInteger doomed = [ids indexOfObject:instanceID];
  NSString *survivor = nil;
  if (doomed != NSNotFound && ids.count > 1)
    survivor = doomed > 0 ? ids[doomed - 1] : ids[1];
  [self _endPuckDragReason:@"a slot instance was removed"];
  KKTimeline *updated = [timeline copy];
  NSArray<KKLane *> *prototypes =
      [MiragePlugin slotPrototypeLanesForShaderSource:source group:group];
  if (!KKTimelineRemoveSlotInstance(updated, scoped, instanceID))
    return;
  // The survivors' stored labels are now numbered one too high. The catalog
  // re-renders them from the prototypes on the next build, but the timeline is
  // what the inspector draws in the meantime.
  KKTimelineRestampSlotLabels(updated, scoped, prototypes);
  KKLogInfo(@"[Slots] removing \"%@\" instance %@ (%lu left)", scoped,
            instanceID,
            (unsigned long)KKTimelineSlotInstanceIDs(updated, scoped).count);
  [self _disarmPicking];
  [self _beginWriteGroup:@"remove slot instance"];
  if (self.onTimelineMutated)
    self.onTimelineMutated(updated);
  [self _endWriteGroup:@"remove slot instance"];
  [self _reloadLaneTemplatesForSource:source];
  [self _refreshPuck];
  [self _selectSlotPuckForInstance:survivor source:source];
  [self _refreshPuck];
}

/// Show the pair for what this shader and this project can actually do: "+"
/// while the group has room, "-" while the selected handle is an instance the
/// group can spare. Both are absent - not disabled - for a shader with no
/// repeatable group at all, which is every shader written before `#slots`.
- (void)_refreshSlotButtonsIn:(KKTimeline *)timeline source:(NSString *)source {
  NSString *addable = timeline ? [self _addableSlotGroupInSource:source] : nil;
  _addSlotButton.hidden = !addable.length;
  if (addable.length)
    _addSlotButton.toolTip = [NSString
        stringWithFormat:RLoc(@"Add another %@ and aim it at a color in the "
                              @"preview.",
                              @"Tooltip for the Color panel's add-instance "
                              @"button. %@ is the group's name, like Colour."),
                         addable];

  NSDictionary<NSString *, NSString *> *active =
      timeline ? [self _activeSlotPuckInSource:source] : nil;
  BOOL removable = NO;
  if (active[@"group"].length) {
    NSInteger max = 0, min = 0;
    MirageSlotGroupLimits(source, active[@"group"], &max, &min);
    removable = (NSInteger)KKTimelineSlotInstanceIDs(
                    timeline, [self _scopedSlotGroup:active[@"group"]])
                    .count > min;
  }
  _removeSlotButton.hidden = !removable;
  if (removable)
    _removeSlotButton.toolTip = [NSString
        stringWithFormat:RLoc(@"Remove %@.",
                              @"Tooltip for the Color panel's remove-instance "
                              @"button. %@ is the handle's name, like "
                              @"Colour 3."),
                         active[@"name"] ?: @""];
}

@end
