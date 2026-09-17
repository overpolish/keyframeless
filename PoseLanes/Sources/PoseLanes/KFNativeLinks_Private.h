/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
#import "KFCreationDefaults.h"
#import "KFNativeEdits.h"

// Internals shared by the native link sources. The package's callers use
// KFNativeLinks.h and KFNativeEdits.h instead.

// Per-manager editing and observation state. Applying guards reentrancy, and
// the host callbacks queue the work their commit path applies later.
@interface KFNativeLinkState : NSObject
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,KFDefaultKeyTracker *> *defaultTrackers;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *defaultInsertions;
@property(nonatomic) BOOL applying;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NSArray *> *observed;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary *> *moves;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *copies;
// Properties whose key structure changed, so a matched pairing may be stale.
@property(nonatomic, strong) NSMutableSet<NSNumber *> *matchCandidates;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *colorSlots;
@end
KFNativeLinkState *KFState(id manager);

// The inspector cache every read and publish goes through.
id KFCache(id<PROAPIAccessing> manager, UInt32 parameter);
NSString *KFLink(id pose);
// The key a time resolves into, nil when the time is past the last key or the
// property holds no keys at all.
NSDictionary *KFTarget(NSArray *entries, CMTime time);
// Every key carrying this link identifier, across the whole lane table.
NSArray<NSDictionary *> *KFMembers(id<PROAPIAccessing> manager, NSString *link);
