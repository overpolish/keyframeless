/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CapStyleView.h"
#import "Constants.h"
#import "FillStyleView.h"
#import "JoinStyleView.h"
#import "KKParamSync.h"
#import "LayerList_Private.h"
#import "MarkerStyleView.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"
#import "StrokeStyleView.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@interface CanvasPlugin (ParameterChangedHandlers)
- (void)_handleSelectionIndexEcho;
- (void)_handleCanvasSelectionEcho;
- (void)_handleCollapsedGroupsEcho;
- (void)_handlePathDataEcho;
- (void)_handleGroupHeaderExpandedEcho:(UInt32)parameterID;
- (void)_handleGroupHeaderEnabledEcho:(UInt32)parameterID atTime:(CMTime)time;
- (void)_handleCycleStyleEcho:(UInt32)parameterID;
- (void)_pushVisibilityFlagsForBoolEcho;
- (void)_handleColorOrGradientModeChanged:(UInt32)parameterID
                                   atTime:(CMTime)time;
- (void)_handleForceShowChanged;
@end

@implementation CanvasPlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  KKLogInfo(@"CanvasPlugin: initialized");
  self = [super initWithAPIManager:newApiManager];
  return self;
}

- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kParamPathData ||
      parameterID == kParamStrokeGradientData ||
      parameterID == kParamFillGradientData ||
      parameterID == kParamExpandedStroke ||
      parameterID == kParamExpandedFill ||
      parameterID == kParamExpandedSketch ||
      parameterID == kParamExpandedTransform)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [super classesForCustomParameterID:parameterID];
}

- (NSString *)kkSelectedGroupKey {
  // Mirror -selectedTransformablePath: the sequencer accent should track
  // the same "single transformable layer" predicate the OSC uses, so the
  // user's mental model matches. Groups are eligible - their lane is keyed
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
  // inside an action scope when invoked from a custom-view callback -
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
  NSString *str = KKCanvasReadPathData(paramGetAPI);
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
  // back to the param value if they disagree - without this write the OSC
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
  KKCanvasWritePathData([newBlob base64EncodedStringWithOptions:0],
                        paramSetAPI);
  [actionAPI endAction:self];

  // The blob write triggers an async parameterChanged → drawOSC round-trip
  // before the store sees the new selection. Push it through the store
  // immediately so the layer-list redraw + sequencer accent refresh fire
  // on this same tick - drawOSC will harmlessly re-apply the same value.
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
  switch (parameterID) {
  case kParamLastSelectedIndex:
    [self _handleSelectionIndexEcho];
    break;
  case kParamCanvasSelection:
    [self _handleCanvasSelectionEcho];
    break;
  case kParamCollapsedGroups:
    [self _handleCollapsedGroupsEcho];
    break;
  case kParamPathData:
    [self _handlePathDataEcho];
    break;
  case kKKParamMultiStageData:
    // Same pattern as path-data echo - kit helper handles the
    // suppression-flag dance so subsequent writes don't clobber the revert.
    [KKPlugin multiStageRefreshFromParamForAPI:self.apiManager];
    break;
  case kParamExpandedStroke:
  case kParamExpandedFill:
  case kParamExpandedSketch:
  case kParamExpandedTransform:
    [self _handleGroupHeaderExpandedEcho:parameterID];
    [self _pushVisibilityFlagsForBoolEcho];
    break;
  case kParamStrokeEnabled:
  case kParamFillEnabled:
  case kParamSketchEnabled:
  case kParamTransformEnabled:
    [self _handleGroupHeaderEnabledEcho:parameterID atTime:time];
    [self _pushVisibilityFlagsForBoolEcho];
    break;
  case kParamStrokeStyle:
  case kParamLineCap:
  case kParamLineJoin:
  case kParamStartMarker:
  case kParamEndMarker:
  case kParamSketchFillStyle:
    [self _handleCycleStyleEcho:parameterID];
    [self _pushVisibilityFlagsForBoolEcho];
    break;
  default:
    break;
  }

  if (parameterID == kParamClosedPath || parameterID == kParamSketchFillStyle ||
      parameterID == kParamStrokeColorMode ||
      parameterID == kParamFillColorMode ||
      parameterID == kParamStrokeGradientType ||
      parameterID == kParamFillGradientType) {
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).visHash = 0;
  }

  // Closed Path used to be written into the path blob from here via
  // KKModifySelectedPathProperty, but that opens a fresh action scope
  // - producing a second undo entry on top of FCP's own bool entry,
  // and re-firing on every cmd-Z echo (the handler reads the reverted
  // bool, mutates the path, writes the blob in a new scope → endless
  // oscillation, "closed-path never undoes"). Render-tick
  // KKParamsToSelectedPaths already reads kParamClosedPath and applies
  // it to the selected path each frame, and end-width pill visibility
  // is driven by the visibility refresh switch above. So no blob write
  // is needed here - the bool param alone is the source of truth.

  if (parameterID == kParamStrokeColorMode ||
      parameterID == kParamFillColorMode ||
      parameterID == kParamStrokeGradientType ||
      parameterID == kParamFillGradientType)
    [self _handleColorOrGradientModeChanged:parameterID atTime:time];

  if (parameterID == kParamForceShow)
    [self _handleForceShowChanged];

  // Visibility refresh helpers write setParameterFlags into FCP's
  // current undo transaction. Running them on every parameterChanged
  // tick - including cmd-Z echoes for the path / selection / lanes
  // blobs - layers phantom flag writes onto the host undo stack and
  // produces "2 cmd-Z per edit" in FCP. Motion's transaction model is
  // unaffected. Gate by paramID, mirroring Glow/MagicMove/Rounded.
  if (parameterID == kParamForceShow || parameterID == kKKParamTimingExpanded)
    [self updateTimingParameterVisibility];
  [self updateMotionBlurParameterVisibility];

  switch (parameterID) {
  case kParamPathData:
  case kParamPathDataMirror:
  case kParamLastSelectedIndex:
  case kKKParamMultiStageData:
    // Pure undo-echo handlers above already did the work. Skip the
    // linked/lane-push tail so FCP's undo transaction stays clean.
    break;
  case kParamStrokeColorMode:
  case kParamFillColorMode:
  case kParamStrokeGradientType:
  case kParamFillGradientType:
  case kParamForceShow:
  case kKKParamTimingExpanded:
  case kKKParamMotionBlurExpanded:
  case kParamExpandedStroke:
  case kParamExpandedFill:
  case kParamExpandedSketch:
  case kParamExpandedTransform:
  case kParamClosedPath:
    [self updateParameterVisibilityAtTime:time];
    break;
  default: {
    [self handleLinkedParameterChanged:parameterID atTime:time];
    // FCP suppresses recursive parameterChanged echoes, so the linked
    // partner's setFloatValue: above does NOT trigger this callback
    // for the partner ID. Mirror its value into the path blob via the
    // same per-edit hook the partner would have got, otherwise cmd-
    // drag of one slider only persists the dragged param's value.
    UInt32 linkedPartner = [self linkedPartnerWrittenForLastChange];
    if (linkedPartner != 0)
      [self kkPushParamToLane:linkedPartner];
    [self kkPushParamToLane:parameterID];
    break;
  }
  }

  return YES;
}

#pragma mark - parameterChanged: handlers

// Host cmd-Z reverts kParamLastSelectedIndex but does NOT update the
// in-memory KKCanvasCurrentSelection map (which is mutated only by
// explicit OSC/layer-list selection sites). Render-tick
// KKParamsToSelectedPaths reads from that map and writes inspector
// values to it - so without a synchronous update here, the host's
// reverted stroke (or any inspector value) gets smeared into the
// *previously*-selected path before the map catches up. Mirror to
// the store too so observers (layer list / sequencer) flip on the
// same tick.
- (void)_handleSelectionIndexEcho {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSInteger newIdx = KKReadSelectedIndex(getAPI);
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  // Only sync the store when the param holds a real path index. -1 means
  // "no path selected" - which can mean either nothing selected OR a
  // group-only selection (group indices aren't representable here as
  // groups have their own ID space). Overwriting the store with an empty
  // index set in the group case wipes the just-set group selection,
  // causing the visibility refresh observer to fire twice (empty → group)
  // and produce two extra undo entries on top of the actual mutation.
  if (!uuid || newIdx < 0)
    return;
  KKLayerInstanceState *lst = KKLayerStateForUUID(uuid);
  // Skip when the in-memory selection already contains newIdx - that's
  // our own write echoing back (kParamLastSelectedIndex carries only
  // the primary path index, so during a multi-select it equals the
  // first selected index; pushing [newIdx] here would collapse
  // [0,1] → [0]). Use KKCanvasCurrentSelection (sync-updated) rather
  // than the store snapshot, so we see writes from the
  // kParamCanvasSelection echo handler that may have just run for the
  // same cmd-Z (its store push goes through performBatch, which is
  // async - by the time we check the snapshot here, it's still stale).
  NSIndexSet *current = KKCanvasCurrentSelection(uuid);
  if ([current containsIndex:(NSUInteger)newIdx])
    return;
  NSIndexSet *newSel = [NSIndexSet indexSetWithIndex:(NSUInteger)newIdx];
  KKCanvasUpdateSelection(uuid, newSel);
  if (lst) {
    [lst.store performBatch:^{
      [lst.store setSelectedIndices:newSel];
    }];
  }
}

// Selection-state echo: cmd-Z reverts kParamCanvasSelection alongside
// the path blob. Re-read it here, parse against the (now post-revert)
// store paths, and push to the store. This is what restores group
// selection on cmd-Z - kParamLastSelectedIndex above can only carry a
// path index, so it can't represent group selection on its own.
- (void)_handleCanvasSelectionEcho {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;
  if (!lst)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [getAPI getStringParameterValue:&str fromParameter:kParamCanvasSelection];
  KKCanvasStoreSnapshot *snap = [lst.store snapshot];
  NSIndexSet *parsed = KKParseCanvasSelection(str, snap.paths ?: @[]);
  // Skip if the store already matches - avoids redundant observer fires
  // when this is just our own write echoing back.
  if ([parsed isEqualToIndexSet:snap.selectedIndices])
    return;
  KKCanvasUpdateSelection(uuid, parsed);
  [lst.store performBatch:^{
    [lst.store setSelectedIndices:parsed];
  }];
}

// CollapsedGroups echo: fires on project load (FCP replays saved param
// values) and on cmd-Z. Rehydrate the in-memory collapsed set + store so
// the disclosure state survives reboot and reverts cleanly.
- (void)_handleCollapsedGroupsEcho {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;
  if (!lst)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [getAPI getStringParameterValue:&str fromParameter:kParamCollapsedGroups];
  NSMutableSet<NSString *> *set = [NSMutableSet set];
  if (str.length > 0) {
    for (NSString *s in [str componentsSeparatedByString:@","]) {
      if (s.length > 0)
        [set addObject:s];
    }
  }
  NSSet<NSString *> *parsed = [set copy];
  if ([parsed isEqualToSet:lst.collapsedGroupIDs ?: [NSSet set]])
    return;
  lst.collapsedGroupIDs = parsed;
  [lst.store performBatch:^{
    [lst.store setCollapsedGroupIDs:parsed];
  }];
}

// Host cmd-Z reverts the KKDataBlob outside our action scopes, so the
// native-string mirror trails by one revision. Refresh it from the
// (post-undo) blob so render and OSC see the reverted paths, and push
// parsed paths into KKCanvasStore so the layer list / sequencer / OSC
// observers redraw against reverted state. Without this push, undo
// looks like "nothing happened" - params revert but the UI keeps
// showing post-edit state.
- (void)_handlePathDataEcho {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = KKReadCustomParamString(getAPI, kParamPathData);
  [setAPI setStringParameterValue:str ?: @"" toParameter:kParamPathDataMirror];
  [actAPI endAction:self];

  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;
  if (!lst)
    return;
  // Push parsed paths to store regardless of length - an empty blob
  // (e.g. cmd-Z reverting the very first draw) must propagate to
  // observers so the sequencer/layer-list redraws against the empty
  // state. Skipping the empty case left the sequencer lane stale.
  NSMutableArray<KKBezierPath *> *paths = nil;
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    paths = [KKBezierPath pathsFromBlob:blob];
  }
  if (!paths)
    paths = [NSMutableArray array];
  [lst.store performBatch:^{
    [lst.store setPaths:paths];
    // Recompute selected-path derived properties (cycle styles, open/closed,
    // etc.) so the snapshot the async observer receives carries up-to-date
    // values.  Without this, syncStyleViews reads stale selectedStrokeStyle /
    // selectedFillStyle from the snapshot and briefly resets the pill UI to the
    // previous value before the next render tick corrects it (1-frame flash).
    [lst.store syncSelectedPathProperties];
  }];
}

// Group-header expand state - KK kit's helper handles the main-queue
// dispatch needed for the header's AutoLayout mutations. The store push
// remains Canvas-specific (other observers like the layer-list renderer
// key off it).
- (void)_handleGroupHeaderExpandedEcho:(UInt32)parameterID {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;
  // Skip the kit's direct header.isExpanded write when stroke/fill/sketch
  // header is "Not available for groups" - the layer-list refresh below
  // (via syncGroupHeaders) keeps it collapsed. Without this, cmd-Z's
  // expanded-param echo flips the header back open right after we
  // disabled it.
  BOOL groupOnly = lst && KKCanvasSelectionIsGroupOnly([lst.store snapshot]);
  if (!(groupOnly && parameterID != kParamExpandedTransform))
    [self syncGroupHeaderExpandedForExpandedParamID:parameterID];
  if (!lst)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL expanded = KKReadCustomParamBool(getAPI, parameterID);
  [lst.store performBatch:^{
    KKCanvasApplyExpandedToStore(lst.store, parameterID, expanded);
  }];
}

// Group-header enabled checkbox - native bool toggle; KK kit's helper
// syncs the header's `isEnabled` on the main queue.
- (void)_handleGroupHeaderEnabledEcho:(UInt32)parameterID atTime:(CMTime)time {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;
  BOOL groupOnly = lst && KKCanvasSelectionIsGroupOnly([lst.store snapshot]);
  if (!(groupOnly && parameterID != kParamTransformEnabled))
    [self syncGroupHeaderEnabledForEnabledParamID:parameterID atTime:time];
  if (!lst)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [getAPI getBoolValue:&enabled fromParameter:parameterID atTime:time];
  [lst.store performBatch:^{
    KKCanvasApplyEnabledToStore(lst.store, parameterID, enabled);
  }];
}

// Cycle-style custom UI param echoes: cmd-Z reverts the persisted int,
// FCP fires parameterChanged here. Push the reverted value back into
// the cycle view (which doesn't observe the param itself) and reset
// visHash so the visibility refresh recomputes (e.g. revealing dash-gap
// when stroke style flips to dashed).
- (void)_handleCycleStyleEcho:(UInt32)parameterID {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;
  if (!lst)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  int idx = KKReadCustomParamInt(getAPI, parameterID);
  KKPillStyleView *view = nil;
  switch (parameterID) {
  case kParamStrokeStyle:
    view = lst.strokeStyleView;
    lst.cachedStrokeStyle = (uint8_t)idx;
    break;
  case kParamLineCap:
    view = lst.capStyleView;
    lst.cachedLineCap = (uint8_t)idx;
    break;
  case kParamLineJoin:
    view = lst.joinStyleView;
    lst.cachedLineJoin = (uint8_t)idx;
    break;
  case kParamStartMarker:
    view = lst.startMarkerView;
    lst.cachedStartMarker = (uint8_t)idx;
    break;
  case kParamEndMarker:
    view = lst.endMarkerView;
    lst.cachedEndMarker = (uint8_t)idx;
    break;
  case kParamSketchFillStyle:
    view = lst.fillStyleView;
    lst.cachedFillStyle = (uint8_t)idx;
    break;
  default:
    break;
  }
  // parameterChanged: runs on main; assign directly.
  if (view && view.selectedIndex != idx)
    view.selectedIndex = idx;
  lst.visHash = 0;
}

// Visibility flip - write the new flag set synchronously inside FCP's
// parameterChanged scope so it joins the user's bool change in one undo
// entry (mirrors motion blur's _setFlagsIfNeeded). The async store-
// observer apply that follows will see visHash unchanged and skip.
- (void)_pushVisibilityFlagsForBoolEcho {
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;
  if (!lst)
    return;
  KKCanvasStoreSnapshot *snap = [lst.store snapshot];
  KKBezierPath *sel =
      KKSelectedTransformTarget(snap.selectedIndices, snap.paths);
  KKParamSyncApplyFromSnapshotInScope(snap, sel, uuid, self.apiManager);
}

- (void)_handleColorOrGradientModeChanged:(UInt32)parameterID
                                   atTime:(CMTime)time {
  BOOL isColorMode = (parameterID == kParamStrokeColorMode ||
                      parameterID == kParamFillColorMode);
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

  // Seed the gradient-data param with the default JSON if it's still
  // empty. Without this, the path has the gradient JSON but the param
  // doesn't - and any later sync that calls KKParamsToPath
  // (fresh-shape creation, click-to-select) reads the empty param and
  // overwrites the path's gradient back to nothing → renders solid.
  // Dragging a stop happens to write both, which is why "move a stop"
  // was the user-visible workaround.
  if (isColorMode && value == 1) {
    UInt32 dataParamID =
        isStroke ? kParamStrokeGradientData : kParamFillGradientData;
    NSString *existing = KKReadCustomParamString(getAPI, dataParamID);
    if (existing.length == 0) {
      id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      id<FxParameterSettingAPI_v5> setAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [actAPI startAction:self];
      KKWriteCustomParamString(setAPI, defaultJSON, dataParamID);
      // Mirror lockstep write - readable from OSC scope.
      [setAPI setStringParameterValue:defaultJSON
                          toParameter:isStroke ? kParamStrokeGradientDataMirror
                                               : kParamFillGradientDataMirror];
      [actAPI endAction:self];
    }
  }
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  if (!uuid)
    return;
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

- (void)_handleForceShowChanged {
  // Invalidate the visibility hash so the sync engine re-applies flags
  // on the next drawOSC cycle with the updated forceShow state.
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  if (uuid) {
    BOOL fs = NO;
    id<FxParameterRetrievalAPI_v6> fsGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
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
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  NSString *str = KKCanvasReadPathData(getAPI);
  KKCanvasWritePathData(str, setAPI);
  [actAPI endAction:self];
}

@end
#pragma clang diagnostic pop
