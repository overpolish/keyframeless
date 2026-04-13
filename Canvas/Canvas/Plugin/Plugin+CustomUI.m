/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#include <KeyframelessKit/KeyframelessKit.h>
#import <objc/message.h>

static const CGFloat kListHeight = 100.0;
static const CGFloat kVerticalPad = 4.0;
static const CGFloat kTotalHeight = kListHeight + kVerticalPad * 2;

static const CGFloat kRowHeight = 24.0;
static const CGFloat kRowSpacing = 1.0;

@interface KKFlippedView : NSView
@end

@implementation KKFlippedView
- (BOOL)isFlipped {
  return YES;
}
@end

static BOOL sForceRefresh = NO;
static BOOL sIsEditing = NO;
static NSIndexSet *sSelectedIndices;
static NSIndexSet *sUISelection;
static NSIndexSet *sPendingOSCSelection;
void KKCanvasRefreshLayerList(NSUInteger pathCount,
                              NSArray<KKBezierPath *> *paths);

@class KKLayerActionTarget;

@interface KKLayerListContainer : NSView
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSView *borderView;
@property(nonatomic, strong) NSView *emptyView;
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, strong) NSLayoutConstraint *contentHeightConstraint;
@property(nonatomic, strong) KKLayerActionTarget *actionTarget;
@end

static __weak KKLayerListContainer *sLayerListContainer;

@interface KKEditableLabel : NSTextField
@end

@implementation KKEditableLabel

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (self.currentEditor) {
    [self.currentEditor keyDown:event];
    return YES;
  }
  return [super performKeyEquivalent:event];
}

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    NSTextView *editor = (NSTextView *)self.currentEditor;
    NSColor *accent = [NSColor accent];
    editor.insertionPointColor = accent;
    editor.selectedTextAttributes = @{
      NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
      NSForegroundColorAttributeName : [NSColor labelColor],
    };
  }
  return ok;
}

@end

@interface KKLayerActionTarget : NSObject <NSTextFieldDelegate>
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
- (void)toggleVisibility:(NSButton *)sender;
- (void)toggleLock:(NSButton *)sender;
- (void)renameRow:(NSMenuItem *)sender;
- (void)duplicateRow:(NSMenuItem *)sender;
- (void)deleteRow:(NSMenuItem *)sender;
@end

@implementation KKLayerActionTarget

- (void)_toggleProperty:(NSButton *)sender
                  apply:(void (^)(KKBezierPath *))apply {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length == 0) {
    [actionAPI endAction:self];
    return;
  }

  NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
  NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
  NSUInteger index = sender.tag;
  if (index >= paths.count) {
    [actionAPI endAction:self];
    return;
  }

  apply(paths[index]);
  NSData *newBlob = [KKBezierPath blobFromPaths:paths];
  NSString *newStr = [newBlob base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:newStr toParameter:kParamPathData];
  [actionAPI endAction:self];

  sForceRefresh = YES;
  KKCanvasRefreshLayerList(paths.count, paths);
}

- (void)toggleVisibility:(NSButton *)sender {
  [self _toggleProperty:sender
                  apply:^(KKBezierPath *p) {
                    p.hidden = !p.hidden;
                  }];
}

- (void)toggleLock:(NSButton *)sender {
  [self _toggleProperty:sender
                  apply:^(KKBezierPath *p) {
                    p.locked = !p.locked;
                  }];
}

- (void)_commitEditing {
  KKLayerListContainer *container = sLayerListContainer;
  if (!container || !sIsEditing)
    return;
  [container.contentView.window makeFirstResponder:container.contentView];
}

- (void)renameRow:(NSMenuItem *)sender {
  [self _commitEditing];

  NSInteger index = sender.tag;
  KKLayerListContainer *container = sLayerListContainer;
  if (!container)
    return;

  NSView *content = container.contentView;
  for (NSStackView *row in content.subviews) {
    if (![row isKindOfClass:[NSStackView class]])
      continue;
    for (NSView *v in row.arrangedSubviews) {
      if ([v isKindOfClass:[NSButton class]] && v.tag == index &&
          [(NSButton *)v action] == @selector(selectRow:)) {
        NSButton *btn = (NSButton *)v;
        KKEditableLabel *field =
            [KKEditableLabel textFieldWithString:btn.title];
        field.font = btn.font;
        field.tag = index;
        field.bordered = NO;
        field.focusRingType = NSFocusRingTypeNone;
        field.drawsBackground = NO;
        field.textColor = [NSColor labelColor];
        field.delegate = self;
        field.translatesAutoresizingMaskIntoConstraints = NO;
        [field
            setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSUInteger viewIndex = [row.arrangedSubviews indexOfObject:btn];
        [row removeArrangedSubview:btn];
        [btn removeFromSuperview];
        [row insertArrangedSubview:field atIndex:viewIndex];

        sIsEditing = YES;
        [field.window makeFirstResponder:field];
        return;
      }
    }
  }
}

- (void)_modifyPaths:(void (^)(NSMutableArray<KKBezierPath *> *))block {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    block(paths);
    NSData *newBlob = [KKBezierPath blobFromPaths:paths];
    NSString *newStr = [newBlob base64EncodedStringWithOptions:0];
    [paramSetAPI setStringParameterValue:newStr toParameter:kParamPathData];

    sForceRefresh = YES;
    KKCanvasRefreshLayerList(paths.count, paths);
  }
  [actionAPI endAction:self];
}

- (void)duplicateRow:(NSMenuItem *)sender {
  NSIndexSet *sel = sUISelection;
  if (!sel || sel.count == 0)
    sel = [NSIndexSet indexSetWithIndex:sender.tag];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    NSMutableIndexSet *newSel = [NSMutableIndexSet indexSet];
    __block NSUInteger offset = 0;
    [sel enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      NSUInteger src = idx + offset;
      if (src >= paths.count)
        return;
      KKBezierPath *clone =
          [KKBezierPath pathWithData:[paths[src] dataRepresentation]];
      [paths insertObject:clone atIndex:src + 1];
      [newSel addIndex:src + 1];
      offset++;
    }];
    NSIndexSet *frozen = [newSel copy];
    sUISelection = frozen;
    sSelectedIndices = frozen;
    sPendingOSCSelection = frozen;
  }];
}

- (void)deleteRow:(NSMenuItem *)sender {
  NSIndexSet *sel = sUISelection;
  if (!sel || sel.count == 0)
    sel = [NSIndexSet indexSetWithIndex:sender.tag];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    [sel enumerateIndexesWithOptions:NSEnumerationReverse
                          usingBlock:^(NSUInteger idx, BOOL *stop) {
                            if (idx < paths.count)
                              [paths removeObjectAtIndex:idx];
                          }];
    NSIndexSet *empty = [NSIndexSet indexSet];
    sUISelection = empty;
    sSelectedIndices = empty;
    sPendingOSCSelection = empty;
  }];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
  NSTextField *field = note.object;
  NSString *newName = field.stringValue;
  NSInteger index = field.tag;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    if (index >= 0 && (NSUInteger)index < paths.count) {
      paths[index].name = newName.length > 0 ? newName : nil;
      NSData *newBlob = [KKBezierPath blobFromPaths:paths];
      NSString *newStr = [newBlob base64EncodedStringWithOptions:0];
      [paramSetAPI setStringParameterValue:newStr toParameter:kParamPathData];
    }
  }
  [actionAPI endAction:self];

  sIsEditing = NO;
  sForceRefresh = YES;
}

- (void)selectRow:(NSButton *)sender {
  [self _commitEditing];
  NSUInteger clicked = sender.tag;
  NSEventModifierFlags flags = NSEvent.modifierFlags;
  NSMutableIndexSet *sel =
      [sUISelection mutableCopy] ?: [NSMutableIndexSet indexSet];

  if (flags & NSEventModifierFlagCommand) {
    if ([sel containsIndex:clicked])
      [sel removeIndex:clicked];
    else
      [sel addIndex:clicked];
  } else if (flags & NSEventModifierFlagShift) {
    NSUInteger anchor = sel.count > 0 ? sel.lastIndex : 0;
    NSUInteger lo = MIN(anchor, clicked);
    NSUInteger hi = MAX(anchor, clicked);
    [sel addIndexesInRange:NSMakeRange(lo, hi - lo + 1)];
  } else {
    [sel removeAllIndexes];
    [sel addIndex:clicked];
  }

  NSIndexSet *frozen = [sel copy];
  sUISelection = frozen;
  sSelectedIndices = frozen;
  sPendingOSCSelection = frozen;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  [paramSetAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
  [actionAPI endAction:self];

  if (str.length > 0) {
    NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
    NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
    sForceRefresh = YES;
    KKCanvasRefreshLayerList(paths.count, paths);
  }
}

@end

@implementation KKLayerListContainer
@end

static NSUInteger sLastListHash = NSUIntegerMax;

NSIndexSet *_Nullable KKCanvasConsumePendingSelection(void) {
  NSIndexSet *pending = sPendingOSCSelection;
  sPendingOSCSelection = nil;
  return pending;
}

void KKCanvasUpdateSelection(NSIndexSet *indices) {
  NSIndexSet *copy = [indices copy];
  sSelectedIndices = copy;
  dispatch_async(dispatch_get_main_queue(), ^{
    sUISelection = copy;
  });
}

static NSUInteger layerListHash(NSUInteger count,
                                NSArray<KKBezierPath *> *paths,
                                NSIndexSet *selection) {
  NSUInteger h = count;
  for (NSUInteger i = 0; i < count; i++) {
    h = h * 31 + (paths[i].hidden ? 1 : 0);
    h = h * 31 + (paths[i].locked ? 2 : 0);
    h = h * 31 + paths[i].name.hash;
  }
  h = h * 31 + selection.hash;
  return h;
}

void KKCanvasRefreshLayerList(NSUInteger pathCount,
                              NSArray<KKBezierPath *> *paths) {
  NSIndexSet *selection = sSelectedIndices ?: [NSIndexSet indexSet];
  NSUInteger hash = layerListHash(pathCount, paths, selection);
  if (hash == sLastListHash && !sForceRefresh)
    return;
  sLastListHash = hash;
  sForceRefresh = NO;

  NSIndexSet *capturedSelection = [selection copy];
  NSMutableArray<NSNumber *> *hiddenStates =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSNumber *> *lockedStates =
      [NSMutableArray arrayWithCapacity:pathCount];
  NSMutableArray<NSString *> *names =
      [NSMutableArray arrayWithCapacity:pathCount];
  for (NSUInteger i = 0; i < pathCount; i++) {
    [hiddenStates addObject:@(paths[i].hidden)];
    [lockedStates addObject:@(paths[i].locked)];
    [names addObject:paths[i].name
                         ?: [NSString stringWithFormat:@"Path %lu",
                                                       (unsigned long)(i + 1)]];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    KKLayerListContainer *container = sLayerListContainer;
    if (!container)
      return;
    if (sIsEditing)
      return;

    NSView *content = container.contentView;
    [content.subviews
        makeObjectsPerformSelector:@selector(removeFromSuperview)];

    if (pathCount == 0) {
      container.emptyView.hidden = NO;
      [content addSubview:container.emptyView];
      container.contentHeightConstraint.constant = kListHeight;
      return;
    }

    container.emptyView.hidden = YES;
    CGFloat topPad = kVerticalPad;
    CGFloat stride = kRowHeight + kRowSpacing;
    CGFloat totalHeight = MAX(pathCount * stride + topPad, kListHeight);
    container.contentHeightConstraint.constant = totalHeight;

    NSImageSymbolConfiguration *symConfig = [NSImageSymbolConfiguration
        configurationWithPointSize:10.0
                            weight:NSFontWeightRegular];

    for (NSUInteger i = 0; i < pathCount; i++) {
      BOOL isHidden = hiddenStates[i].boolValue;
      BOOL isLocked = lockedStates[i].boolValue;

      NSString *eyeName = isHidden ? @"eye.slash" : @"eye.fill";
      NSButton *eyeButton =
          [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:eyeName
                                               accessibilityDescription:nil]
                                        imageWithSymbolConfiguration:symConfig]
                             target:container.actionTarget
                             action:@selector(toggleVisibility:)];
      eyeButton.bezelStyle = NSBezelStyleInline;
      eyeButton.bordered = NO;
      eyeButton.imagePosition = NSImageOnly;
      eyeButton.tag = i;
      eyeButton.contentTintColor = isHidden ? [NSColor tertiaryLabelColor]
                                            : [NSColor secondaryLabelColor];
      [eyeButton.widthAnchor constraintEqualToConstant:12.0].active = YES;
      [eyeButton.heightAnchor constraintEqualToConstant:12.0].active = YES;

      BOOL isSelected = [capturedSelection containsIndex:i];

      NSButton *rowButton = [NSButton buttonWithTitle:names[i]
                                               target:container.actionTarget
                                               action:@selector(selectRow:)];
      rowButton.bezelStyle = NSBezelStyleInline;
      rowButton.bordered = NO;
      rowButton.tag = i;
      rowButton.alignment = NSTextAlignmentLeft;
      rowButton.font = [NSFont systemFontOfSize:11.0];
      rowButton.contentTintColor =
          isHidden ? [NSColor tertiaryLabelColor] : [NSColor labelColor];
      rowButton.cell.lineBreakMode = NSLineBreakByTruncatingTail;
      [rowButton
          setContentHuggingPriority:1
                     forOrientation:NSLayoutConstraintOrientationHorizontal];

      NSString *lockName = isLocked ? @"lock.fill" : @"lock.open";
      NSButton *lockButton =
          [NSButton buttonWithImage:[[NSImage imageWithSystemSymbolName:lockName
                                               accessibilityDescription:nil]
                                        imageWithSymbolConfiguration:symConfig]
                             target:container.actionTarget
                             action:@selector(toggleLock:)];
      lockButton.bezelStyle = NSBezelStyleInline;
      lockButton.bordered = NO;
      lockButton.imagePosition = NSImageOnly;
      lockButton.tag = i;
      lockButton.contentTintColor = isLocked ? [NSColor secondaryLabelColor]
                                             : [NSColor tertiaryLabelColor];
      [lockButton.widthAnchor constraintEqualToConstant:12.0].active = YES;
      [lockButton.heightAnchor constraintEqualToConstant:12.0].active = YES;

      BOOL multiSelect = capturedSelection.count > 1;

      NSMenu *ctxMenu = [[NSMenu alloc] init];
      if (!multiSelect) {
        NSMenuItem *renameItem =
            [[NSMenuItem alloc] initWithTitle:@"Rename"
                                       action:@selector(renameRow:)
                                keyEquivalent:@""];
        renameItem.target = container.actionTarget;
        renameItem.tag = i;
        renameItem.image = [NSImage imageWithSystemSymbolName:@"pencil"
                                     accessibilityDescription:nil];
        [ctxMenu addItem:renameItem];
      }

      NSMenuItem *duplicateItem =
          [[NSMenuItem alloc] initWithTitle:@"Duplicate"
                                     action:@selector(duplicateRow:)
                              keyEquivalent:@""];
      duplicateItem.target = container.actionTarget;
      duplicateItem.tag = i;
      duplicateItem.image =
          [NSImage imageWithSystemSymbolName:@"plus.rectangle.on.rectangle"
                    accessibilityDescription:nil];
      [ctxMenu addItem:duplicateItem];

      [ctxMenu addItem:[NSMenuItem separatorItem]];

      NSMenuItem *deleteItem =
          [[NSMenuItem alloc] initWithTitle:@"Delete"
                                     action:@selector(deleteRow:)
                              keyEquivalent:@""];
      deleteItem.target = container.actionTarget;
      deleteItem.tag = i;
      deleteItem.image = [NSImage imageWithSystemSymbolName:@"trash"
                                   accessibilityDescription:nil];
      NSMutableAttributedString *deleteTitle =
          [[NSMutableAttributedString alloc]
              initWithString:@"Delete"
                  attributes:@{
                    NSForegroundColorAttributeName : [NSColor error]
                  }];
      deleteItem.attributedTitle = deleteTitle;
      [ctxMenu addItem:deleteItem];

      NSStackView *row = [NSStackView
          stackViewWithViews:@[ eyeButton, rowButton, lockButton ]];
      row.menu = ctxMenu;
      row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      row.alignment = NSLayoutAttributeCenterY;
      row.distribution = NSStackViewDistributionFill;
      row.spacing = 6.0;
      row.edgeInsets = NSEdgeInsetsMake(0, KKPaddingMD, 0, KKPaddingMD);
      row.wantsLayer = YES;
      row.layer.cornerRadius = 4.0;
      row.layer.backgroundColor =
          isSelected ? [[NSColor accent] colorWithAlphaComponent:0.15].CGColor
                     : [NSColor clearColor].CGColor;
      row.translatesAutoresizingMaskIntoConstraints = NO;
      [content addSubview:row];
      [row.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                        constant:KKPaddingSM]
          .active = YES;
      [row.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                         constant:-KKPaddingSM]
          .active = YES;
      [row.topAnchor constraintEqualToAnchor:content.topAnchor
                                    constant:topPad + i * stride]
          .active = YES;
      [row.heightAnchor constraintEqualToConstant:kRowHeight].active = YES;
    }
  });
}

@implementation CanvasPlugin (CustomUI)

- (void)refreshLayerList {
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamLayerList) {
    CGFloat inset = KKInspectorHorizontalInset;

    KKLayerListContainer *wrapper = [[KKLayerListContainer alloc]
        initWithFrame:NSMakeRect(0, 0, 300, kTotalHeight)];
    wrapper.autoresizingMask = NSViewWidthSizable;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0];
    scrollView.borderType = NSNoBorder;
    scrollView.wantsLayer = YES;
    scrollView.layer.cornerRadius = 6.0;
    scrollView.layer.masksToBounds = YES;
    wrapper.scrollView = scrollView;

    NSView *borderView = [[NSView alloc] initWithFrame:NSZeroRect];
    borderView.translatesAutoresizingMaskIntoConstraints = NO;
    borderView.wantsLayer = YES;
    borderView.layer.cornerRadius = 6.0;
    borderView.layer.borderWidth = 1.0;
    borderView.layer.borderColor =
        [NSColor colorWithWhite:1.0 alpha:0.05].CGColor;
    wrapper.borderView = borderView;
    [borderView addSubview:scrollView];
    [wrapper addSubview:borderView];

    [NSLayoutConstraint activateConstraints:@[
      [borderView.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor
                                               constant:inset],
      [borderView.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor
                                                constant:-inset],
      [borderView.topAnchor constraintEqualToAnchor:wrapper.topAnchor
                                           constant:kVerticalPad],
      [borderView.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor
                                              constant:-kVerticalPad],
      [scrollView.leadingAnchor
          constraintEqualToAnchor:borderView.leadingAnchor],
      [scrollView.trailingAnchor
          constraintEqualToAnchor:borderView.trailingAnchor],
      [scrollView.topAnchor constraintEqualToAnchor:borderView.topAnchor],
      [scrollView.bottomAnchor constraintEqualToAnchor:borderView.bottomAnchor],
    ]];

    NSImage *icon =
        [NSImage imageWithSystemSymbolName:@"square.3.layers.3d.slash"
                  accessibilityDescription:nil];
    NSImageView *iconView = [NSImageView imageViewWithImage:icon];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentTintColor = [NSColor secondaryLabelColor];
    [iconView.widthAnchor constraintEqualToConstant:12.0].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:12.0].active = YES;

    NSTextField *empty = [NSTextField labelWithString:@"No layers"];
    empty.font = [NSFont systemFontOfSize:11.0];
    empty.textColor = [NSColor secondaryLabelColor];
    empty.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *emptyStack =
        [NSStackView stackViewWithViews:@[ iconView, empty ]];
    emptyStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    emptyStack.spacing = 4.0;
    emptyStack.translatesAutoresizingMaskIntoConstraints = NO;

    KKFlippedView *content = [[KKFlippedView alloc] initWithFrame:NSZeroRect];
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
        [content.heightAnchor constraintEqualToConstant:kListHeight];
    heightConstraint.active = YES;
    [emptyStack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor]
        .active = YES;
    [emptyStack.topAnchor constraintEqualToAnchor:content.topAnchor
                                         constant:kListHeight / 2 - 7]
        .active = YES;

    KKLayerActionTarget *visTarget = [[KKLayerActionTarget alloc] init];
    visTarget.apiManager = self.apiManager;

    wrapper.emptyView = emptyStack;
    wrapper.contentView = content;
    wrapper.contentHeightConstraint = heightConstraint;
    wrapper.actionTarget = visTarget;
    sLayerListContainer = wrapper;
    sLastListHash = NSUIntegerMax;

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *str = nil;
    [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
    [actionAPI endAction:self];

    if (str.length > 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
      NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
      if (paths.count > 0)
        KKCanvasRefreshLayerList(paths.count, paths);
    }

    return wrapper;
  }

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
