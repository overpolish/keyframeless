/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "KKCanvasStore.h"
#import "Plugin_Private.h"
#include <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kLayerListHeight __attribute__((unused)) = 100.0;
static const CGFloat kLayerListVerticalPad __attribute__((unused)) = 4.0;
static const CGFloat kLayerListHintHeight __attribute__((unused)) = 16.0;
static const CGFloat kLayerListTotalHeight __attribute__((unused)) =
    kLayerListHintHeight + kLayerListHeight + kLayerListVerticalPad * 2;
static const CGFloat kLayerRowHeight __attribute__((unused)) = 24.0;
static const CGFloat kLayerRowSpacing __attribute__((unused)) = 1.0;
static const CGFloat kLayerRowStride __attribute__((unused)) =
    kLayerRowHeight + kLayerRowSpacing;
static const NSUInteger kGroupDepthGuard __attribute__((unused)) = 20;
static const CGFloat kLayerSelectionAlpha __attribute__((unused)) = 0.15;
static const CGFloat kLayerBorderAlpha __attribute__((unused)) = 0.05;
static const CGFloat kLayerGroupIndent __attribute__((unused)) = 18.0;

static NSString *const _Nonnull kLayerDragType __attribute__((unused)) =
    @"com.overpolish.canvas.layerDrag";
static NSString *const _Nonnull kLayerDuplicateDragType
    __attribute__((unused)) = @"com.overpolish.canvas.layerDuplicateDrag";

@class KKCapStyleView;
@class KKCustomGroupHeaderView;
@class KKFillStyleView;
@class KKJoinStyleView;
@class KKGradientControl;
@class KKMarkerStyleView;
@class KKStrokeStyleView;
@class KKLayerActionTarget;
@class KKLayerListContainer;

NS_ASSUME_NONNULL_BEGIN

@interface KKLayerInstanceState : NSObject
@property(nonatomic, strong, nullable) KKCanvasStore *store;
@property(nonatomic) BOOL isEditing;
@property(nonatomic) BOOL isDragging;
@property(nonatomic) BOOL soloActive;
@property(nonatomic, copy, nullable) NSIndexSet *selectedIndices;
@property(nonatomic, copy, nullable) NSIndexSet *uiSelection;
@property(nonatomic, copy, nullable) NSIndexSet *pendingOSCSelection;
@property(nonatomic, copy, nullable) NSSet<NSString *> *collapsedGroupIDs;
@property(nonatomic, weak, nullable) KKLayerListContainer *container;
@property(nonatomic, weak, nullable) KKCapStyleView *capStyleView;
@property(nonatomic, weak, nullable) KKJoinStyleView *joinStyleView;
@property(nonatomic, weak, nullable) KKStrokeStyleView *strokeStyleView;
@property(nonatomic, weak, nullable) KKMarkerStyleView *startMarkerView;
@property(nonatomic, weak, nullable) KKMarkerStyleView *endMarkerView;
@property(nonatomic, weak, nullable) KKFillStyleView *fillStyleView;
@property(nonatomic, weak, nullable) KKSeedView *seedView;
@property(nonatomic, weak, nullable) KKGradientControl *strokeGradientControl;
@property(nonatomic, weak, nullable) KKGradientControl *fillGradientControl;
@property(nonatomic, weak, nullable)
    KKCustomGroupHeaderView *transformGroupHeader;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *strokeGroupHeader;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *fillGroupHeader;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *sketchGroupHeader;
@property(nonatomic) uint8_t cachedLineCap;
@property(nonatomic) uint8_t cachedLineJoin;
@property(nonatomic) uint8_t cachedStrokeStyle;
@property(nonatomic) uint8_t cachedStartMarker;
@property(nonatomic) uint8_t cachedEndMarker;
@property(nonatomic) uint8_t cachedFillStyle;
@property(nonatomic) NSUInteger visHash;
@property(nonatomic) BOOL didLoadCollapsedFromParam;
/// Last `merged` flags value we wrote per paramID. Some param flags
/// (notably the group containers 130/132/134/148) don't preserve all
/// bits across `getParameterFlags` calls - FCP appears to strip
/// CUSTOM_UI / USE_FULL_VIEW_WIDTH between reads - so the host-flag
/// comparison in `KKSetFlagsIfNeeded` always disagrees and we'd write
/// every call, fragmenting one user action into multiple undo entries.
/// Cache what we wrote and short-circuit when it matches.
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSNumber *, NSNumber *> *lastWrittenFlags;
@property(nonatomic) float canvasWidth;
@property(nonatomic) float canvasHeight;
@property(nonatomic, copy, nullable) NSIndexSet *previewSelectedIndices;
@property(nonatomic, strong, nullable) KKBezierPath *previewResultPath;
@property(nonatomic) BOOL previewActive;
/// Pointer of the api manager that owns this state. Used to detect
/// duplicate-UUID clones (FCP copy/paste/cut clones `kParamInstanceID`)
/// and mint a fresh UUID for the second instance. Stored unsafe-unretained:
/// only ever pointer-compared, never dereferenced.
@property(nonatomic, assign, nullable) void *ownerAPIPointer;
@end

NSString *_Nullable KKLayerUUIDForAPI(id<PROAPIAccessing> api);
KKLayerInstanceState *_Nullable KKLayerStateForUUID(NSString *_Nullable uuid);
/// Caches `uuid` against `api` so subsequent KKLayerUUIDForAPI calls hit the
/// cache without re-reading kParamInstanceID. Used when the caller mints a
/// fresh UUID (initial setup, duplicate-clone rebind).
void KKBindUUIDToAPI(id<PROAPIAccessing> _Nonnull api, NSString *_Nonnull uuid);

@protocol KKLayerReorder
- (void)_reorderFromIndices:(NSIndexSet *)indices
                    toIndex:(NSUInteger)target
              parentGroupID:(nullable NSString *)parentGroupID;
- (void)_duplicateFromIndices:(NSIndexSet *)indices
                      toIndex:(NSUInteger)target
                parentGroupID:(nullable NSString *)parentGroupID;
- (void)_importSVGString:(NSString *)svgString
                    name:(NSString *)name
                 atIndex:(NSUInteger)index;
- (void)_importImageAtPath:(NSString *)path
                      name:(NSString *)name
                   atIndex:(NSUInteger)index;
- (void)renameRow:(NSMenuItem *)sender;
- (void)groupSelection:(NSMenuItem *)sender;
@end

@class KKLayerButton;

@interface KKLayerRow : NSStackView
@property(nonatomic) NSUInteger rowIndex;
@property(nonatomic, copy, nullable) NSString *groupID;
@property(nonatomic, copy, nullable) NSString *parentGroupID;
@property(nonatomic) BOOL isGroupRow;
@property(nonatomic) BOOL isImageRow;
@property(nonatomic, weak, nullable) NSButton *folderButton;
@property(nonatomic, weak, nullable) NSButton *visibilityButton;
@property(nonatomic, weak, nullable) KKLayerButton *nameButton;
@property(nonatomic, weak, nullable) NSButton *lockButton;
- (NSImage *)snapshot;
@end

@interface KKLayerContentView : NSView
@property(nonatomic, weak, nullable) id<KKLayerReorder> actionTarget;
@property(nonatomic, weak, nullable) KKLayerListContainer *container;
@property(nonatomic) NSInteger dropFlatIndex;
@property(nonatomic) CGFloat dropIndent;
@property(nonatomic, copy, nullable) NSString *dropParentGroupID;
@end

@interface KKLayerListContainer : NSView
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSView *borderView;
@property(nonatomic, strong) NSView *emptyView;
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, strong) NSLayoutConstraint *contentHeightConstraint;
@property(nonatomic, strong) KKLayerActionTarget *actionTarget;
@end

@interface KKEditableLabel : NSTextField
@end

@interface KKLayerButton : NSButton <NSDraggingSource>
@property(nonatomic, weak, nullable) KKLayerRow *parentRow;
@end

@interface KKLayerActionTarget : NSObject <NSTextFieldDelegate, KKLayerReorder>
@property(nonatomic, weak, nullable) id<PROAPIAccessing> apiManager;
@property(nonatomic, copy) NSString *instanceUUID;
- (void)toggleVisibility:(NSButton *)sender;
- (void)toggleLock:(NSButton *)sender;
- (void)renameRow:(NSMenuItem *)sender;
- (void)duplicateRow:(NSMenuItem *)sender;
- (void)deleteRow:(NSMenuItem *)sender;
- (void)groupSelection:(NSMenuItem *)sender;
- (void)ungroupRow:(NSMenuItem *)sender;
- (void)removeFromGroup:(NSMenuItem *)sender;
- (void)toggleGroupCollapse:(id)sender;
- (void)selectRow:(NSButton *)sender;
- (void)_modifyPaths:(void (^)(NSMutableArray<KKBezierPath *> *))block;
- (void)_commitEditing;
- (void)_writeBackObjectParams:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                       toPaths:(NSMutableArray<KKBezierPath *> *)paths
                     selection:(NSIndexSet *)sel;
- (void)_syncObjectParamsForSelection:(NSIndexSet *)sel
                                paths:(NSArray<KKBezierPath *> *)paths
                          paramSetAPI:(id<FxParameterSettingAPI_v5>)paramSetAPI;
- (void)_reorderFromIndices:(NSIndexSet *)indices
                    toIndex:(NSUInteger)target
              parentGroupID:(nullable NSString *)parentGroupID;
- (void)_duplicateFromIndices:(NSIndexSet *)indices
                      toIndex:(NSUInteger)target
                parentGroupID:(nullable NSString *)parentGroupID;
- (void)_importSVGString:(NSString *)svgString
                    name:(NSString *)name
                 atIndex:(NSUInteger)index;
- (void)_importImageAtPath:(NSString *)path
                      name:(NSString *)name
                   atIndex:(NSUInteger)index;
@end

NSIndexSet *KKDescendantIndices(NSUInteger groupIdx,
                                NSArray<KKBezierPath *> *paths);

void KKCanvasRefreshLayerListFromSnapshot(KKCanvasStoreSnapshot *snap,
                                          KKLayerInstanceState *st,
                                          id<PROAPIAccessing> api);
void KKCanvasUpdateSelection(NSString *uuid, NSIndexSet *indices);
NSIndexSet *_Nullable KKCanvasConsumePendingSelection(NSString *uuid);

static inline void KKSetLayerSelection(NSString *uuid, NSIndexSet *sel) {
  KKLayerInstanceState *s = KKLayerStateForUUID(uuid);
  s.uiSelection = sel;
  s.selectedIndices = sel;
  s.pendingOSCSelection = sel;
}

static inline NSButton *KKIconButton(NSString *symbolName,
                                     NSImageSymbolConfiguration *config,
                                     id target, SEL action, NSUInteger tag,
                                     NSColor *tintColor) {
  NSButton *btn =
      [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:symbolName
                                           accessibilityDescription:nil]
                                    imageWithSymbolConfiguration:config]
                         target:target
                         action:action];
  btn.bezelStyle = NSBezelStyleInline;
  btn.bordered = NO;
  btn.imagePosition = NSImageOnly;
  btn.tag = tag;
  btn.contentTintColor = tintColor;
  [btn.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [btn.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  return btn;
}

static inline NSMenuItem *KKMenuItem(NSString *title,
                                     NSString *_Nullable symbolName, id target,
                                     SEL action, NSUInteger tag) {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                action:action
                                         keyEquivalent:@""];
  item.target = target;
  item.tag = tag;
  if (symbolName)
    item.image = [NSImage imageWithSystemSymbolName:symbolName
                           accessibilityDescription:nil];
  return item;
}

NS_ASSUME_NONNULL_END
