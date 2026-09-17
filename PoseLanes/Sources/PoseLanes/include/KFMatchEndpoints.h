/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>

// Match In/Out pairs a property's first and last keyframes. The endpoint values
// mirror each other, and with three or more keys the first incoming transition
// (K1 to K2) and the final one (K[n-1] to Kn) share duration, available time
// and easing. Interior keys stay independent, and Added Motion is never paired:
// it belongs to the key that precedes a gap, which for the final gap is an
// interior key.
//
// The setting is lane-wide, so it lives in a hidden toggle per property instead
// of in the keyframed pose payload. Endpoints are then resolved positionally on
// every read and no insertion, deletion or move has to migrate stored state.

UInt32 KFMatchToggleForProperty(UInt32 parameter);
BOOL KFPropertyMatchEnabled(id<PROAPIAccessing> manager, UInt32 parameter);
// A property with no keyframes has no endpoints to pair, and a sole keyframe
// needs room for the endpoint that enabling creates.
BOOL KFPropertyMatchAvailable(id<PROAPIAccessing> manager, UInt32 parameter);

// Caller owns the host action and undo group. Enabling applies the pairing from
// the first endpoint, so the entrance the user authored defines the exit.
BOOL KFSetPropertyMatch(id<PROAPIAccessing> manager, UInt32 parameter,
                        BOOL enabled, NSError **error);
// Whether a value edit at this key mirrors onto the opposite endpoint. Value
// writes take the shared linked-pose path when it does, so one edit, one undo
// group and one cache publish still cover both keys.
BOOL KFMirrorsValueEdit(id<PROAPIAccessing> manager, UInt32 parameter,
                        CMTime target);
// Whether a Duration, Use available time or Easing edit at this key pairs with
// the opposite incoming transition, which needs three keys to be distinct.
BOOL KFMirrorsTimingEdit(id<PROAPIAccessing> manager, UInt32 parameter,
                         CMTime target);
// Re-applies the pairing for an already matched property, after the keys move.
BOOL KFApplyPropertyMatch(id<PROAPIAccessing> manager, UInt32 parameter,
                          NSError **error);
// The entries a matched property should hold, or nil when these already pair.
// Fewer than two keys pair with nothing, so a deleted endpoint leaves the
// setting alone rather than resurrecting its partner.
NSArray<NSDictionary *> *KFMatchedEntries(id<PROAPIAccessing> manager,
                                          UInt32 parameter,
                                          NSArray<NSDictionary *> *entries);
