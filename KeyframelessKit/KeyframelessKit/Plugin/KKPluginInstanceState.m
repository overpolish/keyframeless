/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPluginInstanceState.h"
#import "KKConstants.h"
#import <FxPlug/FxPlugSDK.h>
#import <objc/runtime.h>

@implementation KKTimingViewRefs
- (BOOL)isAlive {
  return _seqView != nil;
}
@end

@implementation KKPluginInstanceState

- (instancetype)init {
  self = [super init];
  if (self) {
    _pendingPlayheadFraction = -1;
    _pendingPlayheadDuration = -1;
  }
  return self;
}

@end

static const char kKKInstanceUUIDAssocKey;

NSString *KKInstanceUUIDForAPI(id<PROAPIAccessing> api) {
  if (!api)
    return nil;
  NSString *cached = objc_getAssociatedObject(api, &kKKInstanceUUIDAssocKey);
  if (cached.length)
    return cached;

  id<FxParameterRetrievalAPI_v6> getAPI =
      [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;

  NSString *uuid = nil;
  [getAPI getStringParameterValue:&uuid fromParameter:kKKParamInstanceID];
  if (!uuid.length)
    return nil;
  objc_setAssociatedObject(api, &kKKInstanceUUIDAssocKey, uuid,
                           OBJC_ASSOCIATION_COPY_NONATOMIC);
  return uuid;
}

/// Immutable static map. Replaced atomically via mutableCopy + copy — see
/// project_fxplug_static_mutability.md for why NSMutableDictionary statics
/// are unsafe in XPC.
static NSDictionary<NSString *, KKPluginInstanceState *> *sInstanceStates;

KKPluginInstanceState *KKInstanceStateForUUID(NSString *uuid) {
  if (!uuid.length)
    return nil;
  KKPluginInstanceState *state = sInstanceStates[uuid];
  if (state)
    return state;
  state = [[KKPluginInstanceState alloc] init];
  NSMutableDictionary *mut = sInstanceStates ? [sInstanceStates mutableCopy]
                                             : [NSMutableDictionary dictionary];
  mut[uuid] = state;
  sInstanceStates = [mut copy];
  return state;
}

KKPluginInstanceState *KKInstanceStateForAPI(id<PROAPIAccessing> api) {
  NSString *uuid = KKInstanceUUIDForAPI(api);
  return uuid ? KKInstanceStateForUUID(uuid) : nil;
}

KKPluginInstanceState *KKInstanceStateEnsureForAPI(id<PROAPIAccessing> api) {
  NSString *uuid = KKInstanceUUIDForAPI(api);
  if (!uuid.length) {
    uuid = [[NSUUID UUID] UUIDString];
    id<FxParameterSettingAPI_v5> setAPI =
        [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setStringParameterValue:uuid toParameter:kKKParamInstanceID];
    // Re-read so the association cache is populated.
    uuid = KKInstanceUUIDForAPI(api);
  }
  KKPluginInstanceState *state = uuid ? KKInstanceStateForUUID(uuid) : nil;
  if (!state)
    return nil;
  // Duplicate-UUID detection: FCP copy/paste/cut clones `kKKParamInstanceID`
  // along with the rest of the params, so two distinct plugin instances can
  // both resolve to the same state and clobber each other's view refs. If
  // this state is already owned by a different api, mint a fresh UUID for
  // the new instance and rebind to a new state entry.
  void *apiPtr = (__bridge void *)api;
  if (state.ownerAPIPointer && state.ownerAPIPointer != apiPtr) {
    NSString *newUUID = [[NSUUID UUID] UUIDString];
    id<FxParameterSettingAPI_v5> setAPI =
        [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setStringParameterValue:newUUID toParameter:kKKParamInstanceID];
    objc_setAssociatedObject(api, &kKKInstanceUUIDAssocKey, newUUID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    state = KKInstanceStateForUUID(newUUID);
  }
  state.ownerAPIPointer = apiPtr;
  return state;
}

NSArray<KKPluginInstanceState *> *KKAllInstanceStates(void) {
  return sInstanceStates.allValues ?: @[];
}
