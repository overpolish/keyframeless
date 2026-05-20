/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideTrigger.h>

@class KKTimelineLanesView;
@class KKMiniCanvasView;
@class KKSegmentEditView;

NS_ASSUME_NONNULL_BEGIN

/// What (if anything) the binder closes after a step's advance trigger fires.
/// Closes happen via `dispatch_async` to avoid cascading into applyTimeline:
/// from inside the triggering callback's call stack.
typedef NS_ENUM(NSInteger, KKJoyrideCloseOnAdvance) {
  KKJoyrideCloseOnAdvanceNone = 0,
  KKJoyrideCloseOnAdvanceManagePopover,  // -closeManagePopover
  KKJoyrideCloseOnAdvanceContentPopover, // -guideCloseContentPopover
};

/// Wires a guide to a KKTimelineLanesView's callback properties so plugins
/// don't have to install/dispatch/teardown each one by hand. Owns:
///   - all manage/lane/static-values/gap/basic-graph callbacks,
///   - per-step `advanceOn:` / `dismissOn:` dispatch, guarded by step index,
///   - automatic `guide.additionalPassthroughWindow` lifecycle around the
///     manage, static-values, and gap popovers,
///   - mini-canvas onViewTransformChanged / onViewReset hookup whenever the
///     static-values popover opens with a canvas,
///   - per-label constant-field edit handlers installed on demand when a
///     binding uses `constantFieldEditedLabel:component:equals:tolerance:`,
///   - latest payloads (popover row, opted-in lane row, popover content,
///     mini-canvas, gap segment editor, last static value per label) so a
///     step's targetView/targetScreenRect/hit-test block can resolve a
///     control without the plugin plumbing __block variables.
///
/// Inspector-side signals (`playingChanged`, `playPauseEdge`) are driven by
/// the plugin calling `-notifyPlayingChanged:` from its own onPlayingChanged
/// callback — the binder doesn't know about the inspector class.
///
/// Lifetime: create one per guide, give it to the steps builder, call
/// `-teardown` from the controller's `onComplete`.
@interface KKJoyrideLanesBinder : NSObject

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView
                            guide:(KKJoyrideController *)guide
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Binding

/// Records `step` at `stepIndex` and the triggers that should advance /
/// dismiss the guide while that step is active. Either trigger may be nil.
- (void)bindStep:(KKJoyrideStep *)step
         atIndex:(NSInteger)stepIndex
       advanceOn:(nullable KKJoyrideTrigger *)advance
       dismissOn:(nullable KKJoyrideTrigger *)dismiss;

/// On advance from this step, close the named popover on the next runloop
/// turn (the deferred-close pattern that avoids cascading into applyTimeline:
/// from inside the triggering call stack).
- (void)setCloseOnAdvance:(KKJoyrideCloseOnAdvance)close
                  forStep:(KKJoyrideStep *)step;

#pragma mark - Inspector signals (plugin-driven)

/// Forward the inspector's `onPlayingChanged` here so playingChanged: /
/// playPauseEdge triggers fire.
- (void)notifyPlayingChanged:(BOOL)playing;

#pragma mark - Latest payloads (for step target blocks)

@property(nonatomic, readonly, weak, nullable) NSView *latestManagePopoverRow;
- (nullable NSView *)latestOptedInLaneRow;

@property(nonatomic, readonly, weak, nullable) NSView
    *latestStaticValuesPopoverContent;
@property(nonatomic, readonly, weak, nullable) KKMiniCanvasView
    *latestMiniCanvas;

@property(nonatomic, readonly, weak, nullable) NSView *latestGapPopoverContent;
@property(nonatomic, readonly, weak, nullable) KKSegmentEditView
    *latestGapSegmentEditor;

/// Last static value array reported via `onStaticValueChanged` for `label`,
/// or nil if none yet. Use for drag-step hit tests.
- (nullable NSArray<NSNumber *> *)latestStaticValueForLabel:(NSString *)label;

#pragma mark - Relay hooks for plugin side effects

/// Fired after the binder's bookkeeping when the static-values popover opens.
/// Use for custom plugin work that needs the live content view / canvas
/// (e.g. installing a scroll forwarder).
@property(nonatomic, copy, nullable) void (^staticValuesPopoverDidOpen)
    (NSView *content, KKMiniCanvasView *_Nullable canvas);
@property(nonatomic, copy, nullable) void (^staticValuesPopoverDidClose)(void);
/// Fires after the binder records the value, for plugins that need to do
/// custom per-drag work (e.g. multi-signal AND across labels).
@property(nonatomic, copy, nullable) void (^staticValueDragDidEnd)
    (NSString *label, NSArray<NSNumber *> *values);

#pragma mark - Teardown

/// Nils every callback property installed on the lanes view + basic graph +
/// mini-canvas + constant-field handlers. Idempotent.
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
