/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKDataBlob.h"
#import "KKMiniViewerRenderer.h"
#import "KKPlugin+OSCVisibility.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import "KKTimelineInspectorView.h"
#import <KeyframelessKit/KKJoyrideGuideHost.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation KKPlugin (OSCVisibility)

+ (NSArray<NSString *> *)kkOSCElementKeysForCompounds:
    (NSArray<NSArray<NSString *> *> *)compounds {
  NSMutableArray<NSString *> *flat = [NSMutableArray array];
  for (NSArray<NSString *> *c in compounds)
    [flat addObjectsFromArray:c];
  return flat;
}

- (void)kkApplyOSCVisibilityFromState:(NSDictionary *)uiState
                          elementKeys:(NSArray<NSString *> *)keys
                             renderer:(KKMiniViewerRenderer *)renderer {
  NSDictionary *els = uiState[@"oscElements"];
  NSMutableSet<NSString *> *hidden = [NSMutableSet set];
  if ([els isKindOfClass:[NSDictionary class]])
    for (NSString *key in keys)
      if (els[key] && ![els[key] boolValue])
        [hidden addObject:key];
  KKInstanceStateForAPI(self.apiManager).hiddenOSCElements = hidden;
  renderer.hiddenHandleLabels = hidden;
}

// Core set-explicit + persist. Rebuilds the FULL element map from the
// authoritative in-memory hidden set so a stale base can't drop a sibling.
- (void)kkSetOSCElement:(NSString *)label
                 hidden:(BOOL)hidden
            elementKeys:(NSArray<NSString *> *)keys
               renderer:(KKMiniViewerRenderer *)renderer
                paramID:(UInt32)paramID {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  NSMutableSet<NSString *> *h =
      [(st.hiddenOSCElements ?: [NSSet set]) mutableCopy];
  if (hidden)
    [h addObject:label];
  else
    [h removeObject:label];
  st.hiddenOSCElements = h;
  renderer.hiddenHandleLabels = h;
  NSMutableDictionary<NSString *, NSNumber *> *els =
      [NSMutableDictionary dictionary];
  for (NSString *k in keys)
    els[k] = @(![h containsObject:k]);
  [self patchUIStateKey:@"oscElements" value:els paramID:paramID];
}

- (void)kkToggleOSCElement:(NSString *)label
               elementKeys:(NSArray<NSString *> *)keys
                  renderer:(KKMiniViewerRenderer *)renderer
                   paramID:(UInt32)paramID {
  BOOL currentlyHidden =
      [KKInstanceStateForAPI(self.apiManager).hiddenOSCElements
          containsObject:label];
  [self kkSetOSCElement:label
                 hidden:!currentlyHidden
            elementKeys:keys
               renderer:renderer
                paramID:paramID];
}

- (void)kkWireOSCVisibilityForView:(KKTimelineInspectorView *)view
                          renderer:(KKMiniViewerRenderer *)renderer
                         compounds:(NSArray<NSArray<NSString *> *> *)compounds
                           paramID:(UInt32)paramID {
  NSArray<NSString *> *keys = [KKPlugin kkOSCElementKeysForCompounds:compounds];
  __weak typeof(self) weak = self;
  // Renderer retains onHandleVisibilityToggled, so capture it weakly to avoid a
  // cycle; the inspector callbacks capture it weakly too for symmetry.
  __weak KKMiniViewerRenderer *weakRenderer = renderer;

  view.onOSCVisibleToggled = ^(BOOL visible) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    KKInstanceStateForAPI(strong.apiManager).oscMasterVisible = visible;
    weakRenderer.handlesHidden = !visible;
    [strong patchUIStateKey:@"oscMasterVisible"
                      value:@(visible)
                    paramID:paramID];
  };
  view.oscVisibilityCompounds = compounds;
  view.oscVisibilityElementStates = ^NSArray<NSArray<NSNumber *> *> * {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return @[];
    NSSet<NSString *> *hidden =
        KKInstanceStateForAPI(strong.apiManager).hiddenOSCElements
            ?: [NSSet set];
    NSMutableArray<NSArray<NSNumber *> *> *out = [NSMutableArray array];
    for (NSArray<NSString *> *compound in compounds) {
      NSMutableArray<NSNumber *> *group = [NSMutableArray array];
      for (NSString *key in compound)
        [group addObject:@(![hidden containsObject:key])];
      [out addObject:group];
    }
    return out;
  };
  view.oscVisibilityElementToggled = ^(NSInteger ci, NSInteger seg, BOOL isOn) {
    __strong typeof(weak) strong = weak;
    if (!strong || ci < 0 || ci >= (NSInteger)compounds.count)
      return;
    NSArray<NSString *> *compound = compounds[ci];
    if (seg < 0 || seg >= (NSInteger)compound.count)
      return;
    [strong kkSetOSCElement:compound[seg]
                     hidden:!isOn
                elementKeys:keys
                   renderer:weakRenderer
                    paramID:paramID];
  };
  renderer.onHandleVisibilityToggled = ^(NSString *label) {
    __strong typeof(weak) strong = weak;
    [strong kkToggleOSCElement:label
                   elementKeys:keys
                      renderer:weakRenderer
                       paramID:paramID];
  };
}

- (void)kkRefreshOSCVisibilityFromState:(NSDictionary *)state
                                   view:(KKTimelineInspectorView *)view
                               renderer:(KKMiniViewerRenderer *)renderer
                            elementKeys:(NSArray<NSString *> *)keys {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  // Keep the cached blob current, but if a guide is transiently forcing OSC
  // visibility, don't re-apply the saved (user) visibility - otherwise an async
  // parameterChanged the guide itself triggered (e.g. its own activeTab write)
  // toggles the forced OSC back off mid-guide.
  st.lastUIState = state;
  if (st.guideForcingOSC)
    return;
  BOOL oscVisible =
      state[@"oscMasterVisible"] ? [state[@"oscMasterVisible"] boolValue] : YES;
  st.oscMasterVisible = oscVisible;
  [self kkApplyOSCVisibilityFromState:state elementKeys:keys renderer:renderer];
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strong = weakSelf;
    // Re-check at execution time: a guide may have started forcing OSC
    // visibility AFTER this refresh was scheduled (its sync part ran before the
    // force, but this async block lands after). Don't undo the force.
    if (KKInstanceStateForAPI(strong.apiManager).guideForcingOSC)
      return;
    [view setOSCVisible:oscVisible];
    renderer.handlesHidden = !oscVisible;
  });
}

- (NSDictionary *)
    kkForceOSCForGuideKeepingLabels:(NSArray<NSString *> *)keepLabels
                        elementKeys:(NSArray<NSString *> *)keys
                               view:(KKTimelineInspectorView *)view
                           renderer:(KKMiniViewerRenderer *)renderer {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  BOOL priorMaster = st ? st.oscMasterVisible : YES;
  NSSet<NSString *> *priorHidden =
      st.hiddenOSCElements ? [st.hiddenOSCElements copy] : [NSSet set];
  // Hide everything except the kept labels (nil/empty = show all). Transient
  // only - no patchUIStateKey, so the user's saved OSC visibility is untouched.
  NSSet<NSString *> *forced;
  if (keepLabels.count) {
    NSMutableSet<NSString *> *h = [NSMutableSet setWithArray:keys];
    [h minusSet:[NSSet setWithArray:keepLabels]];
    forced = h;
  } else {
    forced = [NSSet set];
  }
  if (st) {
    st.oscMasterVisible = YES;
    st.hiddenOSCElements = forced;
    st.guideForcingOSC = YES; // ignore saved-state OSC refreshes until restore
  }
  renderer.handlesHidden = NO;
  renderer.hiddenHandleLabels = forced;
  [view setOSCVisible:YES];
  return @{@"master" : @(priorMaster), @"hidden" : priorHidden};
}

- (void)kkRestoreOSCForGuide:(NSDictionary *)snapshot
                        view:(KKTimelineInspectorView *)view
                    renderer:(KKMiniViewerRenderer *)renderer {
  if (!snapshot)
    return;
  BOOL priorMaster = [snapshot[@"master"] boolValue];
  NSSet<NSString *> *priorHidden = snapshot[@"hidden"];
  if (![priorHidden isKindOfClass:[NSSet class]])
    priorHidden = [NSSet set];
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  if (st) {
    st.guideForcingOSC = NO;
    st.oscMasterVisible = priorMaster;
    st.hiddenOSCElements = priorHidden;
  }
  renderer.handlesHidden = !priorMaster;
  renderer.hiddenHandleLabels = priorHidden;
  // The OSC guide drives peek reveal directly (setGuidePeekActive); clear it so
  // a run that ended mid-peek doesn't leave the mini-viewer stuck in peek mode
  // (which the master toggle then can't hide).
  renderer.revealHidden = NO;
  [view setOSCVisible:priorMaster];
}

- (void)kkInstallGuideOSCForcingOnHost:(KKJoyrideGuideHost *)host
                                  view:(KKTimelineInspectorView *)view
                           elementKeys:(NSArray<NSString *> *)keys
                          nudgeParamID:(UInt32)nudgeParamID {
  __weak typeof(self) weakPlugin = self;
  __weak KKTimelineInspectorView *weakView = view;
  __block NSDictionary *snapshot = nil;
  host.onRunWillStart = ^{
    __strong typeof(weakPlugin) p = weakPlugin;
    __strong KKTimelineInspectorView *v = weakView;
    if (!p || !v)
      return;
    // Keep-set + renderer resolve at fire time: the running guide's config has
    // installed `guideOSCKeepLabels` by now, and the renderer may have changed.
    KKMiniViewerRenderer *r = (KKMiniViewerRenderer *)v.miniViewerDelegate;
    snapshot = [p kkForceOSCForGuideKeepingLabels:v.guideOSCKeepLabels
                                      elementKeys:keys
                                             view:v
                                         renderer:r];
    [p kkNudgeRenderWithParamID:nudgeParamID];
  };
  host.onRunDidEnd = ^{
    __strong typeof(weakPlugin) p = weakPlugin;
    __strong KKTimelineInspectorView *v = weakView;
    if (!p || !v)
      return;
    KKMiniViewerRenderer *r = (KKMiniViewerRenderer *)v.miniViewerDelegate;
    [p kkRestoreOSCForGuide:snapshot view:v renderer:r];
    [p kkNudgeRenderWithParamID:nudgeParamID];
  };
}

// Force the FCP viewer to redraw its on-screen controls by writing a fresh
// nonce to the hidden render-nudge scratch param inside an action scope. The
// OSC visibility state lives in in-memory instance state that drawOSC reads,
// but FCP only re-invokes drawOSC on a render - and a pure-navigation guide
// triggers none. This nonce write is the same mechanism the boundary-preview
// path uses; it doesn't touch any persisted UI state.
- (void)kkNudgeRenderWithParamID:(UInt32)nudgeParamID {
  id<FxCustomParameterActionAPI_v4> act =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!act)
    return;
  [act startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  KKWriteCustomParamString(setAPI, [[NSUUID UUID] UUIDString], nudgeParamID);
  [act endAction:self];
}

@end
