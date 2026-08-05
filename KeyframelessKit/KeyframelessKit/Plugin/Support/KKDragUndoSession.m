/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKDragUndoSession.h"

#import "KKPlugin.h" // KKBeginUndoGroup / KKEndUndoGroup
#import <FxPlug/FxPlugSDK.h>

@implementation KKDragUndoSession {
  id<PROAPIAccessing> _apiManager;
  id _principal; // strong for the session's (drag-length) life: the dealloc
                 // safety net still needs it to close the scope
  KKDragUndoSessionMode _mode;
  BOOL _groupStarted;
  BOOL _active;
}

+ (instancetype)beginWithAPIManager:(id<PROAPIAccessing>)apiManager
                          principal:(id)principal
                               name:(NSString *)name
                               mode:(KKDragUndoSessionMode)mode {
  id<FxCustomParameterActionAPI_v4> act =
      apiManager
          ? [apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)]
          : nil;
  if (!act)
    return nil;
  KKDragUndoSession *s = [KKDragUndoSession new];
  s->_apiManager = apiManager;
  s->_principal = principal;
  s->_mode = mode;
  [act startAction:principal];
  s->_groupStarted = KKBeginUndoGroup(apiManager, name);
  if (mode == KKDragUndoSessionModeGroupOnly)
    [act endAction:principal];
  s->_active = YES;
  return s;
}

- (BOOL)active {
  return _active;
}

- (void)finish {
  if (!_active)
    return;
  _active = NO;
  id<FxCustomParameterActionAPI_v4> act =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (_mode == KKDragUndoSessionModeGroupOnly) {
    if (act)
      [act startAction:_principal];
    KKEndUndoGroup(_apiManager, _groupStarted);
    if (act)
      [act endAction:_principal];
  } else {
    KKEndUndoGroup(_apiManager, _groupStarted);
    [act endAction:_principal];
  }
  _principal = nil;
  _apiManager = nil;
}

- (void)dealloc {
  [self finish];
}

@end
