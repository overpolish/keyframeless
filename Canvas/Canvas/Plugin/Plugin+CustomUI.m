/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <objc/message.h>

static const CGFloat kListHeight = 100.0;
static const CGFloat kVerticalPad = 4.0;
static const CGFloat kTotalHeight = kListHeight + kVerticalPad * 2;

static const CGFloat kRowHeight = 24.0;

@interface KKFlippedView : NSView
@end

@implementation KKFlippedView
- (BOOL)isFlipped {
  return YES;
}
@end

static BOOL sForceRefresh = NO;
void KKCanvasRefreshLayerList(NSUInteger pathCount,
                              NSArray<KKBezierPath *> *paths);

@interface KKLayerVisibilityTarget : NSObject
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
- (void)toggle:(NSButton *)sender;
@end

@implementation KKLayerVisibilityTarget

- (void)toggle:(NSButton *)sender {
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

  paths[index].hidden = !paths[index].hidden;
  NSData *newBlob = [KKBezierPath blobFromPaths:paths];
  NSString *newStr = [newBlob base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:newStr toParameter:kParamPathData];
  [actionAPI endAction:self];

  sForceRefresh = YES;
  KKCanvasRefreshLayerList(paths.count, paths);
}

@end

@interface KKLayerListContainer : NSView
@property(nonatomic, strong) NSScrollView *scrollView;
@property(nonatomic, strong) NSView *borderView;
@property(nonatomic, strong) NSView *emptyView;
@property(nonatomic, strong) NSView *contentView;
@property(nonatomic, strong) NSLayoutConstraint *contentHeightConstraint;
@property(nonatomic, strong) KKLayerVisibilityTarget *visibilityTarget;
@end

static __weak KKLayerListContainer *sLayerListContainer;
static NSUInteger sLastPathCount = NSUIntegerMax;

@implementation KKLayerListContainer
@end

void KKCanvasRefreshLayerList(NSUInteger pathCount,
                              NSArray<KKBezierPath *> *paths) {
  if (pathCount == sLastPathCount && !sForceRefresh)
    return;
  sLastPathCount = pathCount;
  sForceRefresh = NO;

  NSMutableArray<NSNumber *> *hiddenStates =
      [NSMutableArray arrayWithCapacity:pathCount];
  for (NSUInteger i = 0; i < pathCount; i++)
    [hiddenStates addObject:@(paths[i].hidden)];

  dispatch_async(dispatch_get_main_queue(), ^{
    KKLayerListContainer *container = sLayerListContainer;
    if (!container)
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
    CGFloat totalHeight = MAX(pathCount * kRowHeight + topPad, kListHeight);
    container.contentHeightConstraint.constant = totalHeight;

    for (NSUInteger i = 0; i < pathCount; i++) {
      BOOL isHidden = hiddenStates[i].boolValue;
      NSString *iconName = isHidden ? @"eye.slash" : @"eye.fill";
      NSImage *eyeIcon = [NSImage imageWithSystemSymbolName:iconName
                                   accessibilityDescription:nil];
      NSImageSymbolConfiguration *symConfig = [NSImageSymbolConfiguration
          configurationWithPointSize:10.0
                              weight:NSFontWeightRegular];
      NSButton *eyeButton = [NSButton
          buttonWithImage:[eyeIcon imageWithSymbolConfiguration:symConfig]
                   target:container.visibilityTarget
                   action:@selector(toggle:)];
      eyeButton.bezelStyle = NSBezelStyleInline;
      eyeButton.bordered = NO;
      eyeButton.imagePosition = NSImageOnly;
      eyeButton.tag = i;
      eyeButton.contentTintColor = isHidden ? [NSColor tertiaryLabelColor]
                                            : [NSColor secondaryLabelColor];
      [eyeButton.widthAnchor constraintEqualToConstant:12.0].active = YES;
      [eyeButton.heightAnchor constraintEqualToConstant:12.0].active = YES;

      NSTextField *label = [NSTextField
          labelWithString:[NSString stringWithFormat:@"Path %lu",
                                                     (unsigned long)(i + 1)]];
      label.font = [NSFont systemFontOfSize:11.0];
      label.textColor =
          isHidden ? [NSColor tertiaryLabelColor] : [NSColor labelColor];

      NSStackView *row = [NSStackView stackViewWithViews:@[ eyeButton, label ]];
      row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
      row.alignment = NSLayoutAttributeCenterY;
      row.spacing = 6.0;
      row.frame = NSMakeRect(8, topPad + i * kRowHeight, 200, kRowHeight);
      row.autoresizingMask = NSViewWidthSizable;
      [content addSubview:row];
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

    KKLayerVisibilityTarget *visTarget = [[KKLayerVisibilityTarget alloc] init];
    visTarget.apiManager = self.apiManager;

    wrapper.emptyView = emptyStack;
    wrapper.contentView = content;
    wrapper.contentHeightConstraint = heightConstraint;
    wrapper.visibilityTarget = visTarget;
    sLayerListContainer = wrapper;
    sLastPathCount = NSUIntegerMax;

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
