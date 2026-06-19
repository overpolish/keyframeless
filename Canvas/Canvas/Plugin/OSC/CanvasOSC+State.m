/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import "CanvasLayerTimeline.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>

@implementation CanvasOSC (State)

// The current layer stack, decoded from the inspector-published blob snapshot
// (the OSC can't read kParamLayerData directly). Cached by the blob string so a
// hover (which hit-tests every mouse-move) doesn't re-decode the blob each tick;
// re-decodes only when the blob actually changes. Read-only callers - the
// persist path decodes its own fresh copy before mutating.
- (NSArray<KKBezierPath *> *)_snapshotPaths {
  NSString *b64 = CanvasLayerBlobSnapshot();
  if (!b64.length)
    return @[];
  static NSString *sLastB64 = nil;
  static NSArray<KKBezierPath *> *sLastPaths = nil;
  if (sLastPaths && [b64 isEqualToString:sLastB64])
    return sLastPaths;
  NSArray<KKBezierPath *> *paths = [KKBezierPath
      pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64 options:0]];
  sLastB64 = [b64 copy];
  sLastPaths = paths;
  return paths;
}

// The layer the OSC acts on, resolved against the stack (nil/topmost handled):
// the process timeline snapshot's lanes carry the owning layerKey (set by the
// inspector when it publishes the selected layer's timeline).
- (KKBezierPath *)_selectedLayer {
  NSString *layerID = nil;
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if (l.layerKey.length) {
      layerID = l.layerKey;
      break;
    }
  return CanvasSelectedLayerForPaths([self _snapshotPaths], layerID);
}

- (NSString *)_resolvedSelectedLayerID {
  return [self _selectedLayer].layerID;
}

- (BOOL)_selectedLayerLocked {
  return [self _selectedLayer].locked;
}

// The current kParamUIState as a dictionary, parsed from the inspector-published
// snapshot (the OSC can't read the custom param itself). Empty dict when absent.
- (NSDictionary *)_uiStateDict {
  NSString *json = CanvasUIStateSnapshot();
  NSDictionary *st =
      json.length
          ? [NSJSONSerialization
                JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                           options:0
                             error:nil]
          : nil;
  return [st isKindOfClass:[NSDictionary class]] ? st : @{};
}

// Mutate kParamUIState and write it back inside an action scope. The OSC can't
// READ the custom param to merge, so `mutate` runs on a copy of the published
// snapshot (preserving every key Canvas keeps there - selectedLayerID,
// activeTab, oscElementsByLayer, ...); the write fires the effect's
// parameterChanged, and we republish the snapshot so a follow-up write sees the
// new value before the round-trip. The single home for OSC-side UIState writes.
- (void)_writeUIStateMerging:(void (^)(NSMutableDictionary *state))mutate {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!actionAPI || !setAPI)
    return;
  NSMutableDictionary *state = [[self _uiStateDict] mutableCopy];
  mutate(state);
  NSString *newJSON = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  [actionAPI startAction:self];
  KKWriteCustomParamString(setAPI, newJSON, kParamUIState);
  [actionAPI endAction:self];
  CanvasSetUIStateSnapshot(newJSON);
}

// Master-on opt-click over a handle toggles that element's visibility. The kit
// base rebuilds kParamUIState from `st.lastUIState` and writes the GLOBAL
// "oscElements" key - but Canvas keeps visibility PER LAYER
// ("oscElementsByLayer") and overwrites lastUIState with a partial 2-key dict on
// every layer switch (canvasApplyOSCForLayer), so the kit write (a) doesn't
// persist for Canvas's per-layer read and (b) DROPS selectedLayerID/activeTab,
// resetting selection to topmost + the tab to Basic. Override to flip the
// SELECTED layer's set and write the FULL state, merged into the snapshot base
// (the OSC can't read the custom param to merge itself).
- (void)kkToggleOSCElementHidden:(NSString *)key {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  NSMutableSet<NSString *> *hidden =
      [(st.hiddenOSCElements ?: [NSSet set]) mutableCopy];
  if ([hidden containsObject:key])
    [hidden removeObject:key];
  else
    [hidden addObject:key];
  st.hiddenOSCElements = hidden;

  NSString *layerID = [self _resolvedSelectedLayerID] ?: @"";
  NSMutableDictionary<NSString *, NSNumber *> *els =
      [NSMutableDictionary dictionary];
  for (NSString *k in [self oscElementKeys])
    els[k] = @(![hidden containsObject:k]);

  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    NSMutableDictionary *byLayer =
        [(state[@"oscElementsByLayer"] ?: @{}) mutableCopy];
    byLayer[layerID] = els;
    state[@"oscElementsByLayer"] = byLayer;
    st.oscElementsByOwner = byLayer; // keep the in-process map in step
    st.lastUIState = state;
  }];
}

// Called inside the KKPositionOSC control's open action scope (same
// apiManager), so the get/set API resolves here. `tl` is the selected layer's
// full timeline with the Position edit applied; its lanes carry `layerKey`,
// which tells us the owning layer. Write the edit back into that layer's
// animationJSON in the shared layer blob, then refresh the snapshot for
// immediate redraw.
- (void)_persistSelectedLayerTimeline:(KKTimeline *)tl {
  if (!tl)
    return;
  NSString *layerID = nil;
  for (KKLane *l in tl.lanes)
    if (l.layerKey.length) {
      layerID = l.layerKey;
      break;
    }
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI)
    return;
  // The OSC can't READ kParamLayerData (its retrieval API comes back empty), so
  // load the stack from the inspector-published blob snapshot, splice the edit
  // in, and WRITE it back (the setting API does resolve here).
  NSString *b64 = CanvasLayerBlobSnapshot();
  NSMutableArray<KKBezierPath *> *paths =
      b64.length
          ? [KKBezierPath
                pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64
                                                                  options:0]]
          : [NSMutableArray array];
  KKBezierPath *layer = CanvasSelectedLayerForPaths(paths, layerID);
  if (!layer)
    return;
  // The control edited in the published (shifted) space for a group; un-shift
  // Position back to the canvas-relative offset before storing, so the blob +
  // Constants/keypose popovers keep the 0.5 = no-move convention. No-op for a
  // non-group.
  KKTimeline *storeTL = CanvasUnshiftGroupOSCPosition(tl, layer, paths);
  CanvasApplyTimelineToPath(storeTL, layer);
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  NSString *newB64 = [blob base64EncodedStringWithOptions:0];
  KKWriteCustomParamString(setAPI, newB64, kParamLayerData);
  // Keep both snapshots in step so the control's next draw + the next drag tick
  // read the new value before the param round-trip republishes them. The process
  // timeline stays in the SHIFTED space the control reads (tl); the blob holds
  // the un-shifted stored values.
  KKSetProcessTimelineSnapshot(tl);
  CanvasSetLayerBlobSnapshot(newB64);
}

@end
