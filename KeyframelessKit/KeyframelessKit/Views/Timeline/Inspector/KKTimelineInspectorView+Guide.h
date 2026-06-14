/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKTimelineInspectorView.h>

@class KKJoyrideGuideHost;
@class KKTimingGuideConfig;
@class KKJoyrideStep;
@class KKJoyrideController;
@class KKJoyrideLanesBinder;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Guide-only surface on the inspector toolbar: screen-rect lookups for
/// header buttons (play, etc.) and extra observation hooks a Joyride step
/// needs.
@interface KKTimelineInspectorView (Guide)

/// Screen rect of the play button in the inspector header row. NSZeroRect
/// if not on screen. Used by joyride steps that cutout the play control.
- (NSRect)guidePlayButtonScreenRect;

/// Screen rect of the Maintain Timing lock button (Advanced-only) in the header
/// row. NSZeroRect if not on screen / hidden (Basic tab).
- (NSRect)guideMaintainTimingButtonScreenRect;

/// Screen rect of the Basic (0) or Advanced (1) segment in the tab bar.
/// NSZeroRect if not on screen. Used by joyride steps that cutout a single
/// tab segment.
- (NSRect)guideTabSegmentScreenRectForTab:(NSInteger)tab;

/// Guide-only: when YES the play button accent is driven deterministically by
/// taps (each tap toggles it) and the poll-inferred `setPlaying:` is ignored.
/// A guide owns the playhead scenario, so the inferred play state - which
/// flickers under FCP's bursty currentTime - must not touch the button. Set
/// YES for the duration of a guide that walks the play control; restore NO on
/// completion.
@property(nonatomic) BOOL guideOwnsPlayState;

/// Guide-only: when YES, external `setActiveTab:` calls that would change the
/// tab are ignored, so a guide that pins a tab (e.g. the mini-viewer, which
/// runs in Advanced) can't be fought out of it by the plugin's parameterChanged
/// tab-restore. Set YES after pinning the tab; restore NO before the guide's
/// own tab-restore.
@property(nonatomic) BOOL guideOwnsTab;

/// Guide-only: switch the visible tab WITHOUT persisting it to the saved
/// UI-state (no `onTabChanged`). Use this for a guide's tab pin + restore so
/// the saved `activeTab` never changes - persisting it makes the plugin's
/// parameterChanged re-apply the pinned tab and race the restore into an
/// infinite Basic<->Advanced loop.
- (void)guideSetActiveTab:(NSInteger)tab;

/// Guide-only: fired on every raw play-button tap (one per click,
/// deterministic). Use this to advance a step on the *click* rather than the
/// poll-inferred play state. Drives nothing on its own.
@property(nonatomic, copy, nullable) void (^onPlaybackToggleTapped)(void);

/// Guide-only: set the play button accent directly, bypassing the
/// `guideOwnsPlayState` guard. For the guide to reflect a play state it caused
/// itself (e.g. an auto-pause), not a user tap.
- (void)guideSetPlayingAccent:(BOOL)on;

/// Guide-only: fired AFTER the tab actually changes (in addition to the
/// host's `onTabChanged`, which the plugin owns for blob persistence). Lets
/// a joyride step advance on a tab switch without taking over the host
/// callback.
@property(nonatomic, copy, nullable) void (^onGuideTabChanged)(NSInteger tab);

/// Guide-only: the OSC element labels to keep visible for the duration of the
/// current guide run (the rest are hidden, then restored on end). A guide's
/// restart sets this from its config before running; the plugin's OSC
/// force/restore hook reads it. nil/empty = keep all OSCs visible.
@property(nonatomic, copy, nullable) NSArray<NSString *> *guideOSCKeepLabels;

/// Guide-only OSC-visibility observation hooks, fired ALONGSIDE the plugin's
/// own OSC callbacks so the OSC guide advances on real user actions without
/// clobbering persistence. `master` fires on the On-Screen Controls checkbox;
/// `settingsPopoverWillOpen` fires (with the content view) after the gear's
/// popover settles; `element` fires when a per-element pill is toggled (raw
/// element key + new visible state).
@property(nonatomic, copy, nullable) void (^onGuideOSCMasterToggled)
    (BOOL visible);
@property(nonatomic, copy, nullable) void (^onGuideOSCSettingsPopoverWillOpen)
    (NSView *content);
@property(nonatomic, copy, nullable) void (^onGuideOSCElementToggled)
    (NSString *label, BOOL visible);

/// Screen rect of the On-Screen Controls master checkbox, the settings gear, or
/// the per-element pill bar in the open settings popover. NSZeroRect if the
/// control / popover isn't on screen. Used by the OSC guide to spotlight each
/// step's target.
- (NSRect)guideOSCCheckboxScreenRect;
- (NSRect)guideOSCSettingsButtonScreenRect;
- (NSRect)guideOSCSettingsPillBarScreenRect;

/// Screen rect of a single control's pill in the open settings popover (matched
/// by the compound's master label, e.g. @"Crop"). Lets a guide spotlight just
/// one control so the user can only toggle that one (clicks outside the
/// spotlight aren't forwarded). NSZeroRect if not found / popover closed.
- (NSRect)guideOSCSettingsPillScreenRectForLabel:(NSString *)label;

/// Close the OSC settings popover, if open. Used by the OSC guide to clear the
/// popover before a viewer-spotlight step.
- (void)guideCloseOSCSettingsPopover;

/// Guide-only: fired when a timing guide run reaches its final step (completed,
/// not skipped). A plugin's help guide sets this to `markCompleted`. Wired into
/// the shared host by -timingGuideHost.
@property(nonatomic, copy, nullable) void (^onGuideCompleted)(void);

/// The single shared KKJoyrideGuideHost that runs both timing guides, built
/// lazily on first use. Its timeline accessor / mutator / completion bridges
/// are pre-wired from this inspector (basicLanesView + onTimelineMutated +
/// onGuideCompleted), so a plugin never hand-rolls host setup. Exposed so the
/// plugin can attach its OSC force/restore hooks (onRunWillStart/onRunDidEnd).
- (KKJoyrideGuideHost *)timingGuideHost;

/// A KKTimingGuideConfig with every inspector-level bridge block pre-wired
/// (play button, tab segment, constants button, scrub, toggle playback,
/// play-accent, preview render) from this inspector. The plugin's config
/// provider builds on top of this, filling only the data fields it owns -
/// property labels, seed/target values - and the `viewerScreenRect` block (its
/// OSC bridge). Keeps the per-plugin config to pure data.
- (KKTimingGuideConfig *)makeTimingGuideConfig;

/// The plugin's config builder, set once (typically in createViewForParameterID
/// after the view exists). Returns a fresh fully-populated KKTimingGuideConfig
/// - usually `[self makeTimingGuideConfig]` with the plugin's data + viewer
/// bridge filled in. The restart/autostart methods below call it per run, so a
/// plugin supplies *only* this and the kit owns the rest of the lifecycle.
@property(nonatomic, copy, nullable)
    KKTimingGuideConfig * (^timingGuideConfigProvider)(void);

/// Runs the shared Basic timing walkthrough using `timingGuideConfigProvider`.
/// Forces the Basic tab + single-frame mini viewer + play-state ownership for
/// the run and restores them on completion/skip. No-op if no provider is set.
- (void)restartBasicTimingGuide;

/// Runs the shared Advanced timing walkthrough using
/// `timingGuideConfigProvider`. Starts visually on Basic so step 1's tab switch
/// is visible, auto-advances step 1 when the user flips to Advanced, restores
/// tab + render mode on end.
- (void)restartAdvancedTimingGuide;

/// Runs the shared mini-viewer walkthrough using `timingGuideConfigProvider`.
/// Forces the Advanced tab + a multi-keypose seed so the boundary popover's
/// filmstrip / onion modes have distinct frames; restores tab + render mode and
/// closes the popover on completion/skip.
- (void)restartMiniViewerGuide;

/// Runs the shared on-screen-control walkthrough using
/// `timingGuideConfigProvider`. Teaches the OSC visibility workflow (hide via
/// the gear / pills / opt-click, hide-all, peek). Disables OSC forcing for its
/// run so the user can toggle freely.
- (void)restartOSCGuide;

/// Runs a plugin-specific Advanced-mode walkthrough: forces the Advanced tab +
/// owns it for the run (so a parameterChanged tab-restore can't fight a
/// Basic-incompatible multi-keypose seed), drops the timeline render to Off,
/// applies `seedBlock`, and runs `buildSteps`. Restores the prior tab + render
/// mode and closes the popover on completion/skip. `oscKeepLabels` scopes which
/// on-screen controls stay visible (nil = all). Lets a plugin author a bespoke
/// guide from the shared step machinery without re-implementing the lifecycle.
- (void)runCustomAdvancedGuideWithSeed:(KKTimeline * (^)(void))seedBlock
                            buildSteps:
                                (NSArray<KKJoyrideStep *> * (^)(
                                    KKJoyrideController *guide,
                                    KKJoyrideLanesBinder *binder))buildSteps
                         oscKeepLabels:
                             (nullable NSArray<NSString *> *)oscKeepLabels;

/// First-appearance autostart of the Basic ("Introduction") guide: on the next
/// runloop turn, if the host view is in a window, not a detached copy, no lanes
/// exist yet, and `seenKey` isn't set, marks `seenKey` seen and runs the Basic
/// guide via `timingGuideConfigProvider`. No-op otherwise. Call from
/// -viewDidMoveToWindow.
- (void)autostartIntroGuideOnceWithSeenKey:(NSString *)seenKey;

@end

NS_ASSUME_NONNULL_END
