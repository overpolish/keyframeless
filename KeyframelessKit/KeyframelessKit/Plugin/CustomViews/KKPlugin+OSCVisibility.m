/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasRenderer.h"
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
                             renderer:(KKMiniCanvasRenderer *)renderer {
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
               renderer:(KKMiniCanvasRenderer *)renderer
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
                  renderer:(KKMiniCanvasRenderer *)renderer
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
                          renderer:(KKMiniCanvasRenderer *)renderer
                         compounds:(NSArray<NSArray<NSString *> *> *)compounds
                           paramID:(UInt32)paramID {
  NSArray<NSString *> *keys = [KKPlugin kkOSCElementKeysForCompounds:compounds];
  __weak typeof(self) weak = self;
  // Renderer retains onHandleVisibilityToggled, so capture it weakly to avoid a
  // cycle; the inspector callbacks capture it weakly too for symmetry.
  __weak KKMiniCanvasRenderer *weakRenderer = renderer;

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
                               renderer:(KKMiniCanvasRenderer *)renderer
                            elementKeys:(NSArray<NSString *> *)keys {
  BOOL oscVisible =
      state[@"oscMasterVisible"] ? [state[@"oscMasterVisible"] boolValue] : YES;
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  st.oscMasterVisible = oscVisible;
  st.lastUIState = state;
  [self kkApplyOSCVisibilityFromState:state elementKeys:keys renderer:renderer];
  dispatch_async(dispatch_get_main_queue(), ^{
    [view setOSCVisible:oscVisible];
    renderer.handlesHidden = !oscVisible;
  });
}

- (NSDictionary *)
    kkForceOSCForGuideKeepingLabels:(NSArray<NSString *> *)keepLabels
                        elementKeys:(NSArray<NSString *> *)keys
                               view:(KKTimelineInspectorView *)view
                           renderer:(KKMiniCanvasRenderer *)renderer {
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
  }
  renderer.handlesHidden = NO;
  renderer.hiddenHandleLabels = forced;
  [view setOSCVisible:YES];
  return @{@"master" : @(priorMaster), @"hidden" : priorHidden};
}

- (void)kkRestoreOSCForGuide:(NSDictionary *)snapshot
                        view:(KKTimelineInspectorView *)view
                    renderer:(KKMiniCanvasRenderer *)renderer {
  if (!snapshot)
    return;
  BOOL priorMaster = [snapshot[@"master"] boolValue];
  NSSet<NSString *> *priorHidden = snapshot[@"hidden"];
  if (![priorHidden isKindOfClass:[NSSet class]])
    priorHidden = [NSSet set];
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  if (st) {
    st.oscMasterVisible = priorMaster;
    st.hiddenOSCElements = priorHidden;
  }
  renderer.handlesHidden = !priorMaster;
  renderer.hiddenHandleLabels = priorHidden;
  [view setOSCVisible:priorMaster];
}

- (void)kkInstallGuideOSCForcingOnHost:(KKJoyrideGuideHost *)host
                                  view:(KKTimelineInspectorView *)view
                           elementKeys:(NSArray<NSString *> *)keys {
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
    KKMiniCanvasRenderer *r = (KKMiniCanvasRenderer *)v.miniCanvasDelegate;
    snapshot = [p kkForceOSCForGuideKeepingLabels:v.guideOSCKeepLabels
                                      elementKeys:keys
                                             view:v
                                         renderer:r];
  };
  host.onRunDidEnd = ^{
    __strong typeof(weakPlugin) p = weakPlugin;
    __strong KKTimelineInspectorView *v = weakView;
    if (!p || !v)
      return;
    KKMiniCanvasRenderer *r = (KKMiniCanvasRenderer *)v.miniCanvasDelegate;
    [p kkRestoreOSCForGuide:snapshot view:v renderer:r];
  };
}

@end
