/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKDragUndoSessionMode) {
  /// The undo group is opened and closed in its own BRIEF action scopes;
  /// per-tick writes during the drag manage their own scopes (the mini-drag
  /// model). Nested scopes never occur.
  KKDragUndoSessionModeGroupOnly = 0,
  /// One action scope is HELD OPEN for the whole gesture with the group
  /// inside it; per-tick writes run scope-less inside the held scope (the
  /// gradient model). Writers must check `active` and skip their own scope.
  KKDragUndoSessionModeHoldScope = 1,
};

/// A host undo group held open across a drag gesture's callbacks, so every
/// per-tick param write coalesces into ONE undo entry. Create on dragBegin,
/// -finish on dragEnd. -finish is idempotent and dealloc calls it as a safety
/// net, so an interrupted drag (view teardown, owner dealloc) can never leak
/// an open group or action scope - the leak that wedges FCP's undo machinery.
/// Replaces the per-feature BOOL flags (miniDragUndoStarted,
/// gradientDragUndoActive) with one owned lifecycle.
@interface KKDragUndoSession : NSObject

/// Returns nil (no session, no group) when the action API is unavailable.
+ (nullable instancetype)beginWithAPIManager:(id<PROAPIAccessing>)apiManager
                                   principal:(id)principal
                                        name:(NSString *)name
                                        mode:(KKDragUndoSessionMode)mode;

/// YES between begin and finish. HoldScope writers use this to skip opening
/// their own (would-be nested) scope.
@property(nonatomic, readonly) BOOL active;

- (void)finish;

@end

NS_ASSUME_NONNULL_END
