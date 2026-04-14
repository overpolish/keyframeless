/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#include <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kLayerListHeight __attribute__((unused)) = 100.0;
static const CGFloat kLayerListVerticalPad __attribute__((unused)) = 4.0;
static const CGFloat kLayerListTotalHeight __attribute__((unused)) =
    kLayerListHeight + kLayerListVerticalPad * 2;
static const CGFloat kLayerRowHeight __attribute__((unused)) = 24.0;
static const CGFloat kLayerRowSpacing __attribute__((unused)) = 1.0;
static const CGFloat kLayerRowStride __attribute__((unused)) =
    kLayerRowHeight + kLayerRowSpacing;
static const NSUInteger kGroupDepthGuard __attribute__((unused)) = 20;
static const CGFloat kLayerSelectionAlpha __attribute__((unused)) = 0.15;
static const CGFloat kLayerBorderAlpha __attribute__((unused)) = 0.05;
static const CGFloat kLayerGroupIndent __attribute__((unused)) = 18.0;

static NSString *const kLayerDragType __attribute__((unused)) =
    @"com.overpolish.canvas.layerDrag";
static NSString *const kLayerDuplicateDragType __attribute__((unused)) =
    @"com.overpolish.canvas.layerDuplicateDrag";

@class KKLayerActionTarget;
@class KKLayerListContainer;

@interface KKLayerInstanceState : NSObject
@property(nonatomic) BOOL forceRefresh;
@property(nonatomic) BOOL isEditing;
@property(nonatomic) BOOL isDragging;
@property(nonatomic, copy) NSIndexSet *selectedIndices;
@property(nonatomic, copy) NSIndexSet *uiSelection;
@property(nonatomic, copy) NSIndexSet *pendingOSCSelection;
@property(nonatomic, copy) NSSet<NSString *> *collapsedGroupIDs;
@property(nonatomic, weak) KKLayerListContainer *container;
@property(nonatomic) NSUInteger listHash;
@end

NSString *KKLayerUUIDForAPI(id<PROAPIAccessing> api);
KKLayerInstanceState *KKLayerStateForUUID(NSString *uuid);

@protocol KKLayerReorder
- (void)_reorderFromIndices:(NSIndexSet *)indices
                    toIndex:(NSUInteger)target
              parentGroupID:(NSString *)parentGroupID;
- (void)_duplicateFromIndices:(NSIndexSet *)indices
                      toIndex:(NSUInteger)target
                parentGroupID:(NSString *)parentGroupID;
- (void)renameRow:(NSMenuItem *)sender;
- (void)groupSelection:(NSMenuItem *)sender;
@end

@interface KKLayerRow : NSStackView
@property(nonatomic) NSUInteger rowIndex;
@property(nonatomic, copy) NSString *groupID;
@property(nonatomic, copy) NSString *parentGroupID;
- (NSImage *)snapshot;
@end

@interface KKLayerContentView : NSView
@property(nonatomic, weak) id<KKLayerReorder> actionTarget;
@property(nonatomic) NSInteger dropFlatIndex;
@property(nonatomic) CGFloat dropIndent;
@property(nonatomic, copy) NSString *dropParentGroupID;
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
@property(nonatomic, weak) KKLayerRow *parentRow;
@end

@interface KKLayerActionTarget : NSObject <NSTextFieldDelegate, KKLayerReorder>
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
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
- (void)_reorderFromIndices:(NSIndexSet *)indices
                    toIndex:(NSUInteger)target
              parentGroupID:(NSString *)parentGroupID;
- (void)_duplicateFromIndices:(NSIndexSet *)indices
                      toIndex:(NSUInteger)target
                parentGroupID:(NSString *)parentGroupID;
@end

NSIndexSet *KKDescendantIndices(NSUInteger groupIdx,
                                NSArray<KKBezierPath *> *paths);

void KKCanvasRefreshLayerList(NSString *uuid, NSUInteger pathCount,
                              NSArray<KKBezierPath *> *paths);
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

static inline NSMenuItem *KKMenuItem(NSString *title, NSString *symbolName,
                                     id target, SEL action, NSUInteger tag) {
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
