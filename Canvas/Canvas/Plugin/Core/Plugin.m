/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "KKParamSync.h"
#import "LayerList_Private.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CanvasPlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  KKLogInfo(@"CanvasPlugin: initialized");
  self = [super initWithAPIManager:newApiManager];
  return self;
}

- (NSString *)kkSelectedGroupKey {
  // Mirror -selectedTransformablePath: the sequencer accent should track
  // the same "single transformable layer" predicate the OSC uses, so the
  // user's mental model matches. Groups are eligible — their lane is keyed
  // by layerID just like a path.
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  NSIndexSet *sel = uuid ? KKCanvasCurrentSelection(uuid) : nil;
  if (sel.count != 1)
    return nil;
  KKCanvasStore *store = KKLayerStateForUUID(uuid).store;
  NSArray<KKBezierPath *> *paths = store.snapshot.paths;
  NSUInteger idx = sel.firstIndex;
  if (idx >= paths.count)
    return nil;
  KKBezierPath *p = paths[idx];
  if (p.locked || !p.transformEnabled)
    return nil;
  return p.layerID;
}

- (void)kkHandleGroupSegmentClickedForKey:(NSString *)groupKey {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  if (!uuid || groupKey.length == 0)
    return;
  KKLayerInstanceState *lst = KKLayerStateForUUID(uuid);
  KKLayerActionTarget *actionTarget = lst.container.actionTarget;

  // Mirror LayerList+Selection.m's full flow: writing only the store /
  // instance state leaves the OSC's selectedPathIndices stale and the
  // inspector params pointing at the previous layer. To fully swap
  // selection we must (a) write back the *current* selection's edits to
  // the path blob, (b) update selection state, (c) sync inspector params
  // to the new layer, and (d) push the blob back so FxPlug schedules a
  // parameterChanged round-trip that the OSC picks up on its next draw.
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;

  // FxParameterRetrievalAPI_v6 / FxParameterSettingAPI_v5 only resolve
  // inside an action scope when invoked from a custom-view callback —
  // query them AFTER startAction.
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI) {
    [actionAPI endAction:self];
    return;
  }
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  NSMutableArray<KKBezierPath *> *paths = nil;
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    paths = [KKBezierPath pathsFromBlob:blob];
  }
  if (!paths.count) {
    [actionAPI endAction:self];
    return;
  }

  NSUInteger targetIdx = NSNotFound;
  for (NSUInteger i = 0; i < paths.count; i++) {
    if ([paths[i].layerID isEqualToString:groupKey]) {
      targetIdx = i;
      break;
    }
  }
  if (targetIdx == NSNotFound) {
    [actionAPI endAction:self];
    return;
  }

  NSIndexSet *oldSel = lst.uiSelection;
  [actionTarget _writeBackObjectParams:paramGetAPI
                               toPaths:paths
                             selection:oldSel];

  NSMutableIndexSet *newSel = [NSMutableIndexSet indexSetWithIndex:targetIdx];
  NSIndexSet *finalSel = [newSel copy];
  KKSetLayerSelection(uuid, finalSel);

  [actionTarget _syncObjectParamsForSelection:finalSel
                                        paths:paths
                                  paramSetAPI:paramSetAPI];

  // Persist the new active index. drawOSC's undo-detection compares the
  // in-memory selection against `kParamLastSelectedIndex` and snaps memory
  // back to the param value if they disagree — without this write the OSC
  // would treat our swap as an undo and revert on the next render tick.
  NSInteger primaryIdx = -1;
  for (NSUInteger i = finalSel.firstIndex; i != NSNotFound;
       i = [finalSel indexGreaterThanIndex:i]) {
    if (i < paths.count && !paths[i].isGroup) {
      primaryIdx = (NSInteger)i;
      break;
    }
  }
  KKSaveSelectedIndex(paramSetAPI, primaryIdx);

  NSData *newBlob = [KKBezierPath blobFromPaths:paths];
  [paramSetAPI
      setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                  toParameter:kParamPathData];
  [actionAPI endAction:self];

  // The blob write triggers an async parameterChanged → drawOSC round-trip
  // before the store sees the new selection. Push it through the store
  // immediately so the layer-list redraw + sequencer accent refresh fire
  // on this same tick — drawOSC will harmlessly re-apply the same value.
  [lst.store performBatch:^{
    [lst.store setPaths:paths];
    [lst.store setSelectedIndices:finalSel];
  }];
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES
  };

  return YES;
}

- (BOOL)forceShowAllParameters {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return NO;
  BOOL on = NO;
  [paramGetAPI getBoolValue:&on
              fromParameter:kParamForceShow
                     atTime:kCMTimeZero];
  return on;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  if (parameterID == kParamClosedPath || parameterID == kParamSketchFillStyle ||
      parameterID == kParamStrokeColorMode ||
      parameterID == kParamFillColorMode ||
      parameterID == kParamStrokeGradientType ||
      parameterID == kParamFillGradientType) {
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).visHash = 0;
  }

  // Toggling Closed Path needs to write the new value back into the blob
  // AND push paths into the store. The blob write makes the visibility sync
  // see the right state; the store push fires the layer-list observer which
  // is what actually invokes KKParamSyncApplyFromSnapshot. Without the store
  // push, visHash sits at 0 with no consumer until the user reselects.
  if (parameterID == kParamClosedPath) {
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;
    if (lst) {
      id<FxParameterRetrievalAPI_v6> getAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      BOOL isClosed = YES;
      [getAPI getBoolValue:&isClosed
             fromParameter:kParamClosedPath
                    atTime:time];
      KKModifySelectedPathProperty(self.apiManager, ^(KKBezierPath *p) {
        p.closed = isClosed;
      });
      NSString *str = nil;
      [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
      if (str.length > 0) {
        NSData *blob = [[NSData alloc] initWithBase64EncodedString:str
                                                           options:0];
        NSMutableArray<KKBezierPath *> *paths =
            [KKBezierPath pathsFromBlob:blob];
        [lst.store performBatch:^{
          [lst.store setPaths:paths];
        }];
      }
    }
  }

  BOOL isColorMode = (parameterID == kParamStrokeColorMode ||
                      parameterID == kParamFillColorMode);
  BOOL isGradType = (parameterID == kParamStrokeGradientType ||
                     parameterID == kParamFillGradientType);
  if (isColorMode || isGradType) {
    BOOL isStroke = (parameterID == kParamStrokeColorMode ||
                     parameterID == kParamStrokeGradientType);
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    int value = 0;
    [getAPI getIntValue:&value fromParameter:parameterID atTime:time];
    NSString *defaultJSON = KKDefaultGradientJSON();
    KKModifySelectedPathProperty(self.apiManager, ^(KKBezierPath *p) {
      if (isColorMode) {
        if (isStroke) {
          p.strokeColorMode = (uint8_t)value;
          if (value == 1 && p.strokeGradientJSON.length == 0)
            p.strokeGradientJSON = defaultJSON;
        } else {
          p.fillColorMode = (uint8_t)value;
          if (value == 1 && p.fillGradientJSON.length == 0)
            p.fillGradientJSON = defaultJSON;
        }
      } else {
        if (isStroke)
          p.strokeGradientType = (uint8_t)value;
        else
          p.fillGradientType = (uint8_t)value;
      }
    });
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid) {
      KKCanvasStore *store = KKLayerStateForUUID(uuid).store;
      [store performBatch:^{
        if (isColorMode) {
          if (isStroke)
            [store setStrokeColorMode:(uint8_t)value];
          else
            [store setFillColorMode:(uint8_t)value];
        } else {
          if (isStroke)
            [store setStrokeGradientType:(uint8_t)value];
          else
            [store setFillGradientType:(uint8_t)value];
        }
      }];
    }
  }

  if (parameterID == kParamForceShow) {
    // Invalidate the visibility hash so the sync engine re-applies flags
    // on the next drawOSC cycle with the updated forceShow state.
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid) {
      BOOL fs = NO;
      id<FxParameterRetrievalAPI_v6> fsGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      [fsGetAPI getBoolValue:&fs
               fromParameter:kParamForceShow
                      atTime:kCMTimeZero];
      KKCanvasStore *store = KKLayerStateForUUID(uuid).store;
      [store performBatch:^{
        [store setForceShow:fs];
      }];
    }
    // Touch the blob to trigger a drawOSC redraw.
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:self];
    NSString *str = nil;
    [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
    [setAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
    [actAPI endAction:self];
  }

  [self handleLinkedParameterChanged:parameterID atTime:time];
  [self updateTimingParameterVisibility];
  [self updateMotionBlurParameterVisibility];
  [self updateParameterVisibilityAtTime:time];

  [self kkPushParamToLane:parameterID];

  return YES;
}

@end
#pragma clang diagnostic pop
