/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKDragUndoSession.h"
#import "KKPlugin.h"
#import <FxPlug/FxPlugSDK.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@class KKCustomGroupHeaderView;
@class KKLogoBannerView;

/// Identifier stamped on the single root subview added into a remote window's
/// host. Lets a subsequent open (help or sequencer) cleanly replace prior
/// content without disturbing the host-managed `parentView`.
extern NSUserInterfaceItemIdentifier const KKRemoteWindowContentID;

/// Current clip duration in seconds for the plugin instance behind
/// `apiManager`, or 0 when `FxTimingAPI_v4` is unavailable.
extern double KKCurrentEffectDurationSeconds(id<PROAPIAccessing> apiManager);

@interface KKPlugin () <FxCustomParameterViewHost_v2, NSPopoverDelegate>

/// This effect instance's logo banner. Scoped per plugin instance (FxPlug
/// makes one plugin object per effect) so multi-instance timelines resolve
/// the correct banner instead of a process-global "latest".
@property(nonatomic, weak, nullable) KKLogoBannerView *logoBanner;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *motionBlurHeader;
/// Weak map of generic group headers (created via
/// `createGroupHeaderWithTitle:…:expandedParamID:`) keyed by the
/// `expandedParamID`. Lets `parameterChanged:` re-sync the chevron when the
/// expanded bool param is reverted by host undo. Strong key (NSNumber),
/// weak value (KKCustomGroupHeaderView).
@property(nonatomic, strong, nullable)
    NSMapTable<NSNumber *, KKCustomGroupHeaderView *> *genericGroupHeaders;
/// Companion to `genericGroupHeaders`: same headers keyed by their
/// `enabledParamID` (the native bool toggle) instead of the expanded blob
/// param. Populated by `registerGroupHeader:enabledParamID:expandedParamID:`
/// when the caller's header has a checkbox. Used by
/// `syncGroupHeaderEnabledForEnabledParamID:atTime:`.
@property(nonatomic, strong, nullable)
    NSMapTable<NSNumber *, KKCustomGroupHeaderView *>
        *genericGroupHeadersByEnabledParamID;
/// Drag-coalescing flag for
/// gradient stop / midpoint drags in the color popover. Set YES while
/// the drag is in flight; the per-tick `onStopsChanged` callback skips
/// its own action scope + undo group when this is YES.
@property(nonatomic, strong, nullable) KKDragUndoSession *gradientDragSession;

@end

@interface KKPlugin (ColorViews)
- (NSView *)_createColorCustomUI:(UInt32)parameterID;
@end

@interface KKPlugin (MotionBlurHeader)
- (NSView *)_createMotionBlurHeader:(UInt32)parameterID;
@end

/// Runs `block` on the main thread. Synchronous when already on main,
/// dispatch_async otherwise. Use for view-state pushes triggered from
/// background callbacks (parameterChanged: from non-main, etc).
extern void KKRunOnMain(dispatch_block_t block);

/// Stack-style undo grouping. Pair every `KKBeginUndoGroup` with exactly
/// one `KKEndUndoGroup` along every code path (including early returns).
/// Returns YES if the group was actually started - pass that BOOL into
/// `KKEndUndoGroup` so the end is a no-op when the start was a no-op.
extern BOOL KKBeginUndoGroup(id<PROAPIAccessing> _Nullable apiManager,
                             NSString *name);
extern void KKEndUndoGroup(id<PROAPIAccessing> _Nullable apiManager,
                           BOOL started);

// FxPlug calls createViewForParameterID: on a fresh plugin instance, not the
// one that ran addParametersWithError:. Store parameter metadata at class level
// (keyed by the concrete plugin class) so any instance can look it up.
static const void *_Nonnull const kKKSepTexts = &kKKSepTexts;
static const void *_Nonnull const kKKSepIcons = &kKKSepIcons;
static const void *_Nonnull const kKKInfoTexts = &kKKInfoTexts;
static const void *_Nonnull const kKKInfoAttrTexts = &kKKInfoAttrTexts;
static const void *_Nonnull const kKKInfoIcons = &kKKInfoIcons;

static inline NSMutableDictionary<NSNumber *, id> *
kkClassRegistry(Class cls, const void *_Nonnull key) {
  NSMutableDictionary *dict = objc_getAssociatedObject(cls, key);
  if (!dict) {
    dict = [NSMutableDictionary new];
    objc_setAssociatedObject(cls, key, dict, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return dict;
}

NS_ASSUME_NONNULL_END
