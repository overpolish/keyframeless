/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKAlertStackView.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

@interface _KKAlertEntry : NSObject
@property(nonatomic, strong) KKAlertView *alert;
@property(nonatomic) NSUInteger priority;
@property(nonatomic) BOOL active;
@property(nonatomic, strong) NSButton *iconButton;
@end

@implementation _KKAlertEntry
@end

@implementation KKAlertStackView {
  KKAlertView *_defaultAlert;
  NSMutableArray<_KKAlertEntry *> *_entries;
  NSStackView *_alertStack;
  NSStackView *_iconBar;
  NSButton *_defaultIconButton;
  KKAlertView *_visibleAlert;
  NSString *_selectedTag;
  __weak id<PROAPIAccessing> _apiManager;
  UInt32 _persistParameterID;
}

- (instancetype)initWithDefaultAlert:(KKAlertView *)defaultAlert
                          apiManager:(id<PROAPIAccessing>)apiManager
                  persistParameterID:(UInt32)parameterID {
  CGFloat alertH = KKInspectorRowHeight * 2;
  self = [super initWithFrame:NSMakeRect(0, 0, 0, alertH + KKPaddingMD)];
  if (self) {
    _defaultAlert = defaultAlert;
    _entries = [NSMutableArray array];
    _visibleAlert = defaultAlert;
    _apiManager = apiManager;
    _persistParameterID = parameterID;

    if (apiManager && parameterID != 0) {
      id<FxCustomParameterActionAPI_v4> actionAPI =
          [apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actionAPI startAction:self];
      id<FxParameterRetrievalAPI_v6> paramGetAPI =
          [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      NSString *saved = nil;
      [paramGetAPI getStringParameterValue:&saved fromParameter:parameterID];
      [actionAPI endAction:self];
      if (saved.length > 0)
        _selectedTag = [saved copy];
    }

    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    defaultAlert.translatesAutoresizingMaskIntoConstraints = NO;

    _alertStack = [NSStackView stackViewWithViews:@[ defaultAlert ]];
    _alertStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _alertStack.spacing = 0;
    _alertStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_alertStack];

    _iconBar = [[NSStackView alloc] init];
    _iconBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _iconBar.spacing = KKSpacingSM;
    _iconBar.translatesAutoresizingMaskIntoConstraints = NO;
    _iconBar.hidden = YES;
    [self addSubview:_iconBar];

    _defaultIconButton = [self _createIconButtonForAlert:defaultAlert tag:-1];
    [_iconBar addArrangedSubview:_defaultIconButton];

    [NSLayoutConstraint activateConstraints:@[
      [_alertStack.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_alertStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_alertStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_alertStack.heightAnchor constraintEqualToConstant:alertH],
      [defaultAlert.widthAnchor
          constraintEqualToAnchor:_alertStack.widthAnchor],
      [_iconBar.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [_iconBar.topAnchor constraintEqualToAnchor:_alertStack.bottomAnchor
                                         constant:-KKSpacingXS],
    ]];
  }
  return self;
}

- (NSButton *)_createIconButtonForAlert:(KKAlertView *)alert
                                    tag:(NSInteger)tag {
  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:9.0
                          weight:NSFontWeightRegular
                           scale:NSImageSymbolScaleSmall];
  NSImage *icon = [alert.icon imageWithSymbolConfiguration:cfg];
  NSButton *btn = [NSButton buttonWithImage:icon
                                     target:self
                                     action:@selector(_iconTapped:)];
  btn.bordered = NO;
  btn.tag = tag;
  btn.contentTintColor = alert.color;
  return btn;
}

- (void)addAlert:(KKAlertView *)alert priority:(NSUInteger)priority {
  _KKAlertEntry *entry = [[_KKAlertEntry alloc] init];
  entry.alert = alert;
  entry.priority = priority;
  entry.active = NO;

  alert.translatesAutoresizingMaskIntoConstraints = NO;
  alert.hidden = YES;

  [_alertStack addArrangedSubview:alert];
  [alert.widthAnchor constraintEqualToAnchor:_alertStack.widthAnchor].active =
      YES;

  entry.iconButton = [self _createIconButtonForAlert:alert tag:0];
  entry.iconButton.hidden = YES;

  NSUInteger insertIdx = _entries.count;
  for (NSUInteger i = 0; i < _entries.count; i++) {
    if (priority < _entries[i].priority) {
      insertIdx = i;
      break;
    }
  }
  [_entries insertObject:entry atIndex:insertIdx];

  [self _rebuildIconBar];
  _iconBar.hidden = NO;
}

- (void)_rebuildIconBar {
  for (_KKAlertEntry *e in _entries)
    [e.iconButton removeFromSuperview];
  for (NSUInteger i = 0; i < _entries.count; i++) {
    _entries[i].iconButton.tag = (NSInteger)i;
    [_iconBar addArrangedSubview:_entries[i].iconButton];
  }
}

- (void)setAlert:(KKAlertView *)alert active:(BOOL)active {
  _KKAlertEntry *entry = [self _entryForAlert:alert];
  if (!entry)
    return;
  entry.active = active;
  entry.iconButton.hidden = !active;
  [self _resolve];
}

- (_KKAlertEntry *)_entryForAlert:(KKAlertView *)alert {
  for (_KKAlertEntry *e in _entries) {
    if (e.alert == alert)
      return e;
  }
  return nil;
}

- (void)_resolve {
  KKAlertView *target = _defaultAlert;
  for (_KKAlertEntry *e in _entries) {
    if (e.active) {
      target = e.alert;
      break;
    }
  }

  if (_selectedTag != nil) {
    NSInteger tag = _selectedTag.integerValue;
    KKAlertView *selected = nil;
    if (tag == -1)
      selected = _defaultAlert;
    else if (tag >= 0 && tag < (NSInteger)_entries.count)
      selected = _entries[tag].alert;
    if (selected) {
      BOOL valid = (selected == _defaultAlert);
      if (!valid) {
        _KKAlertEntry *e = [self _entryForAlert:selected];
        valid = (e && e.active);
      }
      if (valid)
        target = selected;
    }
  }

  if (_visibleAlert != target) {
    _visibleAlert.hidden = YES;
    target.hidden = NO;
    _visibleAlert = target;
  }

  BOOL anyActive = NO;
  CGFloat dimAlpha = 0.4;
  _defaultIconButton.contentTintColor =
      (_visibleAlert == _defaultAlert)
          ? _defaultAlert.color
          : [_defaultAlert.color colorWithAlphaComponent:dimAlpha];
  for (_KKAlertEntry *e in _entries) {
    BOOL selected = (_visibleAlert == e.alert);
    e.iconButton.contentTintColor =
        selected ? e.alert.color
                 : [e.alert.color colorWithAlphaComponent:dimAlpha];
    if (e.active)
      anyActive = YES;
  }
  _iconBar.hidden = !anyActive;
}

- (void)selectAlertWithTag:(NSInteger)tag {
  _selectedTag = [NSString stringWithFormat:@"%ld", (long)tag];
  [self _resolve];
}

- (void)_iconTapped:(NSButton *)sender {
  [self selectAlertWithTag:sender.tag];
  [self _persistSelectedTag];
  if (_onSelectedChanged)
    _onSelectedChanged(sender.tag);
}

- (void)_persistSelectedTag {
  if (!_apiManager || _persistParameterID == 0 || !_selectedTag)
    return;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [paramSetAPI setStringParameterValue:_selectedTag
                           toParameter:_persistParameterID];
  [actionAPI endAction:self];
}

@end
