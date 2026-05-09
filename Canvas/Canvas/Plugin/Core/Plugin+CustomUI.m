/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CapStyleView.h"
#import "FillStyleView.h"
#import "JoinStyleView.h"
#import "KKParamSync.h"
#import "KKPillStyleView.h"
#import "LayerList_Private.h"
#import "MarkerStyleView.h"
#import "ObjectParams.h"
#import "StrokeStyleView.h"
#import <KeyframelessKit/KKGradientSampling.h>
#import <objc/message.h>
#import <objc/runtime.h>

// FCP's OZViewCtrlRootScrollView claims forwarded scroll events from nested
// scroll views, which scrolls the inspector when the user reaches the layer
// list's top/bottom. Returning nil from this private method blocks the
// forwarding-target search; native momentum/elasticity stay intact.
@interface KKLayerListScrollView : NSScrollView
@end
@implementation KKLayerListScrollView
- (NSResponder *)_recursiveResponderThatWantsForwardedScrollEventsForAxis:
                     (NSEventGestureAxis)axis
                                                         intendedForSwipe:
                                                             (BOOL)forSwipe {
  return nil;
}
@end

@implementation CanvasPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (void)refreshLayerList {
}

- (KKCustomGroupHeaderView *)
    createGroupHeaderWithText:(NSString *)text
                         icon:(NSImage *)icon
                 enabledParam:(UInt32)enabledParam
                expandedParam:(UInt32)expandedParam
              storeSetEnabled:(SEL)storeSetEnabled
             storeSetExpanded:(SEL)storeSetExpanded
              stateHeaderProp:(NSString *)stateHeaderProp
            pathPropertyBlock:(void (^)(KKBezierPath *, BOOL))pathBlock {
  // Delegate to KKKit's checkbox group header factory. Path-mutation runs
  // *inside* the click-handler's scope (via the in-scope variant), and the
  // store push is dropped — Plugin.m's parameterChanged hook re-pushes the
  // bool to KKCanvasStore, so doing it here a second time creates a
  // separate scope/undo entry (the bug we're fixing).
  __weak typeof(self) weakSelf = self;
  void (^pathBlockCopy)(KKBezierPath *, BOOL) = [pathBlock copy];
  KKCustomGroupHeaderView *header = [self
      createCheckboxGroupHeaderWithTitle:text
                                    icon:icon
                          enabledParamID:enabledParam
                         expandedParamID:expandedParam
                          onEnabledExtra:^(
                              BOOL isEnabled,
                              id<FxParameterSettingAPI_v5> setAPI) {
                            __strong typeof(weakSelf) strongSelf = weakSelf;
                            if (!strongSelf || !pathBlockCopy)
                              return;
                            id<FxParameterRetrievalAPI_v6> getAPI =
                                [strongSelf.apiManager
                                    apiForProtocol:
                                        @protocol(FxParameterRetrievalAPI_v6)];
                            if (!getAPI)
                              return;
                            KKModifySelectedPathPropertyInScope(
                                strongSelf.apiManager, getAPI, setAPI,
                                ^(KKBezierPath *path) {
                                  pathBlockCopy(path, isEnabled);
                                });
                          }
                         onExpandedExtra:nil];
  header.isInteractive = YES;

  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  if (uuid)
    [KKLayerStateForUUID(uuid) setValue:header forKey:stateHeaderProp];

  return header;
}

- (NSView *)createLayerListView NS_RETURNS_RETAINED {
  CGFloat inset = KKInspectorHorizontalInset;

  KKLayerListContainer *wrapper = [[KKLayerListContainer alloc]
      initWithFrame:NSMakeRect(0, 0, 300, kLayerListTotalHeight)];
  wrapper.autoresizingMask = NSViewWidthSizable;

  NSScrollView *scrollView =
      [[KKLayerListScrollView alloc] initWithFrame:NSZeroRect];
  scrollView.translatesAutoresizingMaskIntoConstraints = NO;
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = NO;
  scrollView.autohidesScrollers = YES;
  scrollView.drawsBackground = YES;
  scrollView.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0];
  scrollView.borderType = NSNoBorder;
  scrollView.wantsLayer = YES;
  scrollView.layer.cornerRadius = KKSpacingMD;
  scrollView.layer.masksToBounds = YES;
  wrapper.scrollView = scrollView;

  NSView *borderView = [[NSView alloc] initWithFrame:NSZeroRect];
  borderView.translatesAutoresizingMaskIntoConstraints = NO;
  borderView.wantsLayer = YES;
  borderView.layer.cornerRadius = KKSpacingMD;
  borderView.layer.borderWidth = KKBorderWidthXS;
  borderView.layer.borderColor =
      [NSColor colorWithWhite:1.0 alpha:kLayerBorderAlpha].CGColor;
  wrapper.borderView = borderView;
  [borderView addSubview:scrollView];
  [wrapper addSubview:borderView];

  NSTextField *hintLabel =
      [NSTextField labelWithString:@"Drop images into the layer list"];
  hintLabel.font = [NSFont systemFontOfSize:KKFontSizeSM - 1.0];
  hintLabel.textColor = [NSColor tertiaryLabelColor];
  hintLabel.translatesAutoresizingMaskIntoConstraints = NO;

  NSImageView *hintIcon = [NSImageView
      imageViewWithImage:[NSImage imageWithSystemSymbolName:@"photo.fill"
                                   accessibilityDescription:nil]];
  hintIcon.translatesAutoresizingMaskIntoConstraints = NO;
  hintIcon.contentTintColor = [NSColor tertiaryLabelColor];
  [hintIcon.widthAnchor constraintEqualToConstant:KKFontSizeSM].active = YES;
  [hintIcon.heightAnchor constraintEqualToConstant:KKFontSizeSM].active = YES;

  NSStackView *hintStack =
      [NSStackView stackViewWithViews:@[ hintIcon, hintLabel ]];
  hintStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  hintStack.spacing = KKSpacingXS;
  hintStack.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:hintStack];

  [NSLayoutConstraint activateConstraints:@[
    [hintStack.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor
                                            constant:inset + KKPaddingSM],
    [hintStack.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [hintStack.heightAnchor constraintEqualToConstant:kLayerListHintHeight],
    [borderView.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor
                                             constant:inset],
    [borderView.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor
                                              constant:-inset],
    [borderView.topAnchor constraintEqualToAnchor:hintStack.bottomAnchor],
    [borderView.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor
                                            constant:-kLayerListVerticalPad],
    [scrollView.leadingAnchor constraintEqualToAnchor:borderView.leadingAnchor],
    [scrollView.trailingAnchor
        constraintEqualToAnchor:borderView.trailingAnchor],
    [scrollView.topAnchor constraintEqualToAnchor:borderView.topAnchor],
    [scrollView.bottomAnchor constraintEqualToAnchor:borderView.bottomAnchor],
  ]];

  NSImage *icon = [NSImage imageWithSystemSymbolName:@"square.3.layers.3d.slash"
                            accessibilityDescription:nil];
  NSImageView *iconView = [NSImageView imageViewWithImage:icon];
  iconView.translatesAutoresizingMaskIntoConstraints = NO;
  iconView.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  [iconView.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [iconView.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;

  NSTextField *empty = [NSTextField labelWithString:@"No shapes"];
  empty.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  empty.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  empty.translatesAutoresizingMaskIntoConstraints = NO;

  NSStackView *emptyStack =
      [NSStackView stackViewWithViews:@[ iconView, empty ]];
  emptyStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  emptyStack.spacing = KKSpacingSM;
  emptyStack.translatesAutoresizingMaskIntoConstraints = NO;

  KKLayerContentView *content =
      [[KKLayerContentView alloc] initWithFrame:NSZeroRect];
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [content addSubview:emptyStack];
  scrollView.documentView = content;

  [content.leadingAnchor
      constraintEqualToAnchor:scrollView.contentView.leadingAnchor]
      .active = YES;
  [content.trailingAnchor
      constraintEqualToAnchor:scrollView.contentView.trailingAnchor]
      .active = YES;
  NSLayoutConstraint *heightConstraint =
      [content.heightAnchor constraintEqualToConstant:kLayerListHeight];
  heightConstraint.active = YES;
  [emptyStack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor]
      .active = YES;
  [emptyStack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor]
      .active = YES;

  KKLayerActionTarget *actionTarget = [[KKLayerActionTarget alloc] init];
  actionTarget.apiManager = self.apiManager;

  wrapper.emptyView = emptyStack;
  wrapper.contentView = content;
  content.container = wrapper;
  wrapper.contentHeightConstraint = heightConstraint;
  wrapper.actionTarget = actionTarget;
  content.actionTarget = actionTarget;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *uuid = nil;
  [paramGetAPI getStringParameterValue:&uuid fromParameter:kParamInstanceID];
  if (uuid.length == 0) {
    uuid = [[NSUUID UUID] UUIDString];
    [paramSetAPI setStringParameterValue:uuid toParameter:kParamInstanceID];
  }
  KKBindUUIDToAPI(self.apiManager, uuid);

  KKLayerInstanceState *state = KKLayerStateForUUID(uuid);
  // Duplicate-UUID detection: FCP copy/paste/cut clones `kParamInstanceID`
  // along with the rest of the params, so two distinct plugin instances
  // can resolve to the same state and clobber each other's view refs. If
  // this state is already owned by a different api, mint a fresh UUID for
  // the new instance and rebind to a new state entry.
  void *apiPtr = (__bridge void *)self.apiManager;
  if (state.ownerAPIPointer && state.ownerAPIPointer != apiPtr) {
    uuid = [[NSUUID UUID] UUIDString];
    [paramSetAPI setStringParameterValue:uuid toParameter:kParamInstanceID];
    KKBindUUIDToAPI(self.apiManager, uuid);
    state = KKLayerStateForUUID(uuid);
  }
  state.ownerAPIPointer = apiPtr;
  actionTarget.instanceUUID = uuid;

  state.container = wrapper;

  // Write back any pending per-object param edits.
  NSString *str = KKCanvasReadPathData(paramGetAPI);
  NSInteger lastIdx = KKReadSelectedIndex(paramGetAPI);
  if (str.length > 0 && lastIdx >= 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if ((NSUInteger)lastIdx < paths.count && !paths[lastIdx].isGroup) {
      KKParamsToPath(paramGetAPI, paths[lastIdx]);
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      KKCanvasWritePathData([newBlob base64EncodedStringWithOptions:0],
                            paramSetAPI);
    }
  }
  // Read persisted expand/enable state so the seed block below can prime
  // the store. Without this, parameterChanged events that fired before
  // the layer-list view (and therefore before the UUID was associated)
  // were dropped, leaving the store at default-NO and the visibility
  // pass hiding all stroke/fill/sketch/transform children on reopen.
  BOOL seedStrokeEnabled = NO, seedFillEnabled = NO;
  BOOL seedSketchEnabled = NO, seedTransformEnabled = NO;
  [paramGetAPI getBoolValue:&seedStrokeEnabled
              fromParameter:kParamStrokeEnabled
                     atTime:kCMTimeZero];
  [paramGetAPI getBoolValue:&seedFillEnabled
              fromParameter:kParamFillEnabled
                     atTime:kCMTimeZero];
  [paramGetAPI getBoolValue:&seedSketchEnabled
              fromParameter:kParamSketchEnabled
                     atTime:kCMTimeZero];
  [paramGetAPI getBoolValue:&seedTransformEnabled
              fromParameter:kParamTransformEnabled
                     atTime:kCMTimeZero];
  BOOL seedStrokeExpanded =
      KKReadCustomParamBool(paramGetAPI, kParamExpandedStroke);
  BOOL seedFillExpanded =
      KKReadCustomParamBool(paramGetAPI, kParamExpandedFill);
  BOOL seedSketchExpanded =
      KKReadCustomParamBool(paramGetAPI, kParamExpandedSketch);
  BOOL seedTransformExpanded =
      KKReadCustomParamBool(paramGetAPI, kParamExpandedTransform);
  [actionAPI endAction:self];

  // Register store observer.
  __weak KKLayerInstanceState *weakState = state;
  __weak id weakAPI = self.apiManager;
  __weak CanvasPlugin *weakSelf = self;
  [state.store
      addObserverForChanges:(KKStoreChangePaths | KKStoreChangeSelection |
                             KKStoreChangeVisibility | KKStoreChangeCollapse |
                             KKStoreChangeSolo | KKStoreChangeEditing |
                             KKStoreChangePathProps | KKStoreChangeExpanded)
                      block:^(KKCanvasStoreSnapshot *snap,
                              KKStoreChange changes) {
                        KKLayerInstanceState *s = weakState;
                        id api = weakAPI;
                        if (!s || !api)
                          return;
                        KKCanvasRefreshLayerListFromSnapshot(snap, s, api);
                        if (changes &
                            (KKStoreChangePaths | KKStoreChangePathProps))
                          [KKPlugin multiStageSyncFromParams:api];
                        // Selection or path changes can both shift which
                        // layer the sequencer should accent (paths gone →
                        // groupKey vanishes; selection moves → key swaps).
                        if (changes &
                            (KKStoreChangeSelection | KKStoreChangePaths))
                          [weakSelf kkRefreshSequencerSelectedGroup];
                      }];

  // Seed the store so the observer fires on initial setup.
  {
    NSArray<KKBezierPath *> *seedPaths = @[];
    if (str.length > 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
      seedPaths = [KKBezierPath pathsFromBlob:blob];
    }
    NSIndexSet *seedSel = [NSIndexSet indexSet];
    if (lastIdx >= 0)
      seedSel = [NSIndexSet indexSetWithIndex:(NSUInteger)lastIdx];
    KKCanvasStore *initStore = state.store;
    [initStore performBatch:^{
      [initStore setPaths:seedPaths];
      [initStore setSelectedIndices:seedSel];
      [initStore syncSelectedPathProperties];
      [initStore setStrokeEnabled:seedStrokeEnabled];
      [initStore setFillEnabled:seedFillEnabled];
      [initStore setSketchEnabled:seedSketchEnabled];
      [initStore setTransformEnabled:seedTransformEnabled];
      [initStore setStrokeExpanded:seedStrokeExpanded];
      [initStore setFillExpanded:seedFillExpanded];
      [initStore setSketchExpanded:seedSketchExpanded];
      [initStore setTransformExpanded:seedTransformExpanded];
    }];
    KKCanvasRefreshLayerListFromSnapshot([initStore snapshot], state,
                                         self.apiManager);
  }

  return wrapper;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamLayerList)
    return [self createLayerListView];

  if (parameterID == kParamGroupTransform) {
    return [self
        createGroupHeaderWithText:@"Transform"
                             icon:
                                 [NSImage
                                     imageWithSystemSymbolName:
                                         @"arrow.up.and.down.and.arrow.left.and"
                                         @".right"
                                      accessibilityDescription:nil]
                     enabledParam:kParamTransformEnabled
                    expandedParam:kParamExpandedTransform
                  storeSetEnabled:@selector(setTransformEnabled:)
                 storeSetExpanded:@selector(setTransformExpanded:)
                  stateHeaderProp:@"transformGroupHeader"
                pathPropertyBlock:^(KKBezierPath *path, BOOL enabled) {
                  path.transformEnabled = enabled;
                }];
  }

  if (parameterID == kParamGroupStroke) {
    return
        [self createGroupHeaderWithText:@"Stroke"
                                   icon:[NSImage imageWithSystemSymbolName:
                                                     @"stroke.line.diagonal"
                                                  accessibilityDescription:nil]
                           enabledParam:kParamStrokeEnabled
                          expandedParam:kParamExpandedStroke
                        storeSetEnabled:@selector(setStrokeEnabled:)
                       storeSetExpanded:@selector(setStrokeExpanded:)
                        stateHeaderProp:@"strokeGroupHeader"
                      pathPropertyBlock:^(KKBezierPath *path, BOOL enabled) {
                        path.strokeEnabled = enabled;
                      }];
  }

  if (parameterID == kParamGroupFill) {
    return [self
        createGroupHeaderWithText:@"Fill"
                             icon:[NSImage imageWithSystemSymbolName:
                                               @"rectangle.trailinghalf.filled"
                                            accessibilityDescription:nil]
                     enabledParam:kParamFillEnabled
                    expandedParam:kParamExpandedFill
                  storeSetEnabled:@selector(setFillEnabled:)
                 storeSetExpanded:@selector(setFillExpanded:)
                  stateHeaderProp:@"fillGroupHeader"
                pathPropertyBlock:^(KKBezierPath *path, BOOL enabled) {
                  path.fillEnabled = enabled;
                }];
  }

  if (parameterID == kParamGroupSketch) {
    return [self
        createGroupHeaderWithText:@"Sketch"
                             icon:[NSImage imageWithSystemSymbolName:@"scribble"
                                            accessibilityDescription:nil]
                     enabledParam:kParamSketchEnabled
                    expandedParam:kParamExpandedSketch
                  storeSetEnabled:@selector(setSketchEnabled:)
                 storeSetExpanded:@selector(setSketchExpanded:)
                  stateHeaderProp:@"sketchGroupHeader"
                pathPropertyBlock:^(KKBezierPath *path, BOOL enabled) {
                  path.sketchEnabled = enabled;
                  if (enabled && path.sketchSeed == 0)
                    path.sketchSeed = arc4random();
                }];
  }

  NSView *styleView = [self createStyleViewForParameterID:parameterID];
  if (styleView)
    return styleView;

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

static NSSet<NSString *> *_kkTransformOSCLabels(void) {
  static NSSet<NSString *> *sLabels = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sLabels = [NSSet setWithObjects:@"Position", @"Scale", @"Anchor", @"Rot Z",
                                    @"Rot X", @"Rot Y", nil];
  });
  return sLabels;
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return _kkTransformOSCLabels();
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSCDefaultOff {
  return _kkTransformOSCLabels();
}

- (NSString *)emptyLanesMessageWhenNoLanes {
  return @"No layers";
}

- (NSString *)emptyLanesIconNameWhenNoLanes {
  return @"square.dashed";
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *tools = [KKHelpSection
      sectionWithTitle:@"Tools"
             tipMarkup:@[
               (@"Pick a tool from the on-canvas toolbar - "
                @"<accent>Cursor</accent> selects and reshapes paths, "
                @"<accent>Pen</accent> draws bezier paths anchor by anchor, "
                @"and <accent>Rectangle</accent>, <accent>Ellipse</accent>, "
                @"and <accent>Line</accent> drag out primitive shapes."),
               (@"Each path becomes a <accent>layer</accent> in the inspector "
                @"with its own Stroke, Fill, and Sketch styling."),
               (@"With the Pen tool, click to add corner anchors or drag to "
                @"pull out smooth handles. Close a path by clicking its first "
                @"anchor."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>V</kbd>"
                               descMarkup:@"Cursor tool"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>X</kbd>"
                               descMarkup:@"Pen tool"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>B</kbd>"
                               descMarkup:@"Rectangle tool"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>G</kbd>"
                               descMarkup:@"Ellipse tool"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>M</kbd>"
                               descMarkup:@"Line tool"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>esc</kbd>"
                                           descMarkup:@"Return to Cursor and "
                                                      @"clear selection"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌫</kbd>"
                                           descMarkup:@"Delete the selected "
                                                      @"path (cursor mode)"],
             ]];
  tools.icon = [NSImage imageWithSystemSymbolName:@"scribble.variable"
                         accessibilityDescription:nil];

  KKHelpSection *editing = [KKHelpSection
      sectionWithTitle:@"Editing"
             tipMarkup:@[
               (@"Drag an anchor or handle to reshape a path. Drag empty "
                @"canvas to marquee-select multiple anchors or paths."),
               (@"Resize and rotate handles wrap any selection so you can "
                @"transform several paths at once."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag"
                               descMarkup:@"Constrain motion to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌘</kbd> + drag"
                                           descMarkup:@"Disable snapping"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag "
                                                      @"path"
                                           descMarkup:@"Duplicate the "
                                                      @"selected path"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + corner resize"
                               descMarkup:@"Lock to aspect ratio"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + corner resize"
                               descMarkup:@"Scale symmetrically from center"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + "
                                                      @"rotate"
                                           descMarkup:@"Snap rotation to 15° "
                                                      @"increments"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + "
                                                      @"marquee"
                                           descMarkup:@"Add to selection"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + marquee"
                                           descMarkup:@"Remove from selection"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"anchor"
                                           descMarkup:@"Delete the anchor "
                                                      @"(Pen tool)"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag "
                                                      @"handle"
                                           descMarkup:@"Break handle "
                                                      @"symmetry (move "
                                                      @"independently)"],
             ]];
  editing.icon = [NSImage imageWithSystemSymbolName:@"hand.draw"
                           accessibilityDescription:nil];

  return @[ tools, editing ];
}

@end
