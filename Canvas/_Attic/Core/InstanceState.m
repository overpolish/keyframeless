/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "LayerList_Private.h"
#import <objc/runtime.h>

@implementation KKLayerInstanceState
@end

static NSDictionary<NSString *, KKLayerInstanceState *> *sLayerStates;
static const char kKKLayerUUIDAssocKey;

NSString *KKLayerUUIDForAPI(id<PROAPIAccessing> api) {
  NSString *cached = objc_getAssociatedObject(api, &kKKLayerUUIDAssocKey);
  if (cached)
    return cached;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *uuid = nil;
  [paramGetAPI getStringParameterValue:&uuid fromParameter:kParamInstanceID];
  if (uuid.length > 0)
    objc_setAssociatedObject(api, &kKKLayerUUIDAssocKey, uuid,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
  return uuid;
}

void KKBindUUIDToAPI(id<PROAPIAccessing> api, NSString *uuid) {
  objc_setAssociatedObject(api, &kKKLayerUUIDAssocKey, uuid,
                           OBJC_ASSOCIATION_COPY_NONATOMIC);
}

KKLayerInstanceState *KKLayerStateForUUID(NSString *uuid) {
  if (!uuid)
    return nil;
  KKLayerInstanceState *state = sLayerStates[uuid];
  if (!state) {
    state = [[KKLayerInstanceState alloc] init];
    state.store = [[KKCanvasStore alloc] initWithUUID:uuid];
    NSMutableDictionary *mut = sLayerStates ? [sLayerStates mutableCopy]
                                            : [NSMutableDictionary dictionary];
    mut[uuid] = state;
    sLayerStates = [mut copy];
  }
  return state;
}
