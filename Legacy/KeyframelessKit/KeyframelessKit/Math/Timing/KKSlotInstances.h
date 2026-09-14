/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// REPEATABLE LANE GROUPS ("slots").
//
// A host declares a group of controls once - a PROTOTYPE set of template lanes
// - and the user stamps INSTANCES of it at runtime. Mirage's `#slots` directive
// is the first consumer; Canvas's layers are the same shape and could adopt it.
//
// The rules the whole design falls out of:
//
//  * An instance's identity is a short opaque ID minted once, never reused, and
//    never re-derived from position. Lane keys embed it, so REORDERING OR
//    DELETING an instance can never move another instance's keyframes.
//  * Display numbering ("Layer 3") is DERIVED from the registry order at read
//    time, so it is free to change while the keys stay put.
//  * The registry lives on the timeline (KKTimeline.slotGroups) because the
//    lanes alone can't tell you that an instance exists but is currently empty,
//    nor what order the user put them in.

#pragma once

#import <Foundation/Foundation.h>

@class KKLane;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Separator between a group name and an instance ID inside a slot lane key.
///
/// `#` is safe: no lane key anywhere in the codebase contains one. Mirage mints
/// keys from GLSL uniform names (identifier characters only) and Canvas from
/// template names ("Stroke Width") optionally tagged with U+001F + a layer
/// UUID. It also reads naturally next to Mirage's `#slots` directive.
FOUNDATION_EXPORT NSString *const kKKSlotInstanceSeparator;

/// Separator between an instance ID and the control key within the instance.
FOUNDATION_EXPORT NSString *const kKKSlotControlSeparator;

/// Placeholder in a prototype lane's LABEL, substituted with the instance's
/// 1-based display number: `@"Ring {n} Colour"` -> `@"Ring 2 Colour"`.
FOUNDATION_EXPORT NSString *const kKKSlotLabelNumberToken;

/// `"<group>#<instanceID>.<controlKey>"` - THE key of one control of one
/// instance. Deterministic, so a rebuilt prototype set matches stored lanes.
FOUNDATION_EXPORT NSString *
KKSlotLaneKey(NSString *groupName, NSString *instanceID, NSString *controlKey);

/// Parses a key made by `KKSlotLaneKey`. Returns NO (leaving the out params
/// untouched) for any key that isn't slot-shaped - which is most keys, so this
/// doubles as the "is this a slot lane?" test. Out params are optional.
FOUNDATION_EXPORT BOOL KKSlotParseLaneKey(
    NSString *laneKey, NSString *_Nullable *_Nullable outGroupName,
    NSString *_Nullable *_Nullable outInstanceID,
    NSString *_Nullable *_Nullable outControlKey);

/// The instance IDs of `groupName`, in display order. Empty when the group has
/// no instances or the timeline predates the registry.
FOUNDATION_EXPORT NSArray<NSString *> *
KKTimelineSlotInstanceIDs(KKTimeline *timeline, NSString *groupName);

/// 1-based display number of an instance, or 0 when it isn't registered. This
/// is the ONLY place a number comes from - never a lane key, never a label.
FOUNDATION_EXPORT NSInteger KKTimelineSlotDisplayNumber(KKTimeline *timeline,
                                                        NSString *groupName,
                                                        NSString *instanceID);

/// The timeline's lanes belonging to one instance, in timeline order.
FOUNDATION_EXPORT NSArray<KKLane *> *KKTimelineSlotLanes(KKTimeline *timeline,
                                                         NSString *groupName,
                                                         NSString *instanceID);

/// A prototype label rendered for display number `n` (substitutes `{n}`). Use
/// it at any display site that wants the CURRENT number rather than the one
/// baked into the lane's stored label.
FOUNDATION_EXPORT NSString *KKSlotRenderedLabel(NSString *prototypeLabel,
                                                NSInteger n);

/// Appends one instance of `groupName` to `timeline`: mints an ID (unique
/// within the group), registers it last, and stamps one lane per prototype -
/// each a copy of the prototype with its key rewritten to `KKSlotLaneKey` and
/// its label rendered for the new display number. Prototype keyposes come
/// along, so a prototype carrying a default constant seeds the instance.
///
/// Mutates `timeline` in place (the caller owns the copy-before-edit dance the
/// rest of the timeline mutations use). Returns the new instance ID, or nil if
/// the arguments were empty.
FOUNDATION_EXPORT NSString *_Nullable KKTimelineStampSlotInstance(
    KKTimeline *timeline, NSString *groupName, NSArray<KKLane *> *prototypes);

/// Removes one instance: its lanes and its registry entry, and nothing else.
/// Every other instance keeps its ID, its lane keys and its keyframes; only
/// their DISPLAY numbers shift, because the order list got shorter.
///
/// Stored labels of the survivors are now stale by exactly that shift. Callers
/// that rebuild lanes from prototypes each session (Mirage does) need do
/// nothing; anyone else calls `KKTimelineRestampSlotLabels` after.
///
/// Mutates in place. Returns YES when something was removed.
FOUNDATION_EXPORT BOOL KKTimelineRemoveSlotInstance(KKTimeline *timeline,
                                                    NSString *groupName,
                                                    NSString *instanceID);

/// Re-renders every instance lane's LABEL from the prototypes at the instance's
/// current display number. Idempotent; call after a removal or a reorder if the
/// host relies on stored labels. Keys, keyposes and every other lane field are
/// untouched.
FOUNDATION_EXPORT void
KKTimelineRestampSlotLabels(KKTimeline *timeline, NSString *groupName,
                            NSArray<KKLane *> *prototypes);

/// A fingerprint of the timeline's slot registry: every group and the instance
/// IDs it holds, in registry order.
///
/// Deliberately the IDs and not just a count. A remove-then-add is the same
/// count and a different set of lane keys, and it is the KEYS a host's
/// templates have to match. Group names are sorted so the dictionary's own
/// order cannot make an unchanged registry look changed; the IDs inside a group
/// are NOT, since their order is the display order and moving one is a real
/// change.
FOUNDATION_EXPORT NSString *KKSlotRegistrySignature(KKTimeline *timeline);

/// A signature back into groups and their ordered instance IDs.
FOUNDATION_EXPORT NSDictionary<NSString *, NSArray<NSString *> *> *
KKSlotSignatureParse(NSString *signature);

/// The first instance ID `now` lists that `was` did not, and its group.
///
/// Which is to say: what an externally-arriving registry change ADDED. An undo
/// of a removal is the case this exists for - the instance is back, and it is
/// the one the user was working on a moment ago, so it is the one a panel
/// should be talking about. A removal adds nothing and answers nil, which
/// leaves any neighbour fallback that already handles it alone.
///
/// FIRST rather than all of them: a selection is one handle. Groups are walked
/// in signature order, which is sorted, so a change that adds several - a
/// preset swapping the whole registry - lands somewhere deterministic instead
/// of wherever a dictionary happened to enumerate.
FOUNDATION_EXPORT NSString *_Nullable KKSlotFirstAddedInstance(
    NSString *_Nullable was, NSString *_Nullable now,
    NSString *_Nullable *_Nullable outGroup);

/// Brings `groupName` up to exactly `count` instances, stamping missing ones
/// and removing trailing extras. Idempotent, and the load-time entry point: a
/// legacy blob (no registry) or a fresh apply gets the template's declared
/// default instance count, while a blob that already has instances is left
/// alone. Returns YES when the timeline changed.
FOUNDATION_EXPORT BOOL KKTimelineEnsureSlotCount(KKTimeline *timeline,
                                                 NSString *groupName,
                                                 NSInteger count,
                                                 NSArray<KKLane *> *prototypes);

NS_ASSUME_NONNULL_END
