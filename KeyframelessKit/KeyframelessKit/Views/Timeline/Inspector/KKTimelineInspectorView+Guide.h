/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKTimelineInspectorView.h>

@class KKJoyrideGuideHost;
@class KKTimingGuideConfig;

NS_ASSUME_NONNULL_BEGIN

/// Guide-only surface on the inspector toolbar: screen-rect lookups for
/// header buttons (play, etc.) and extra observation hooks a Joyride step
/// needs.
@interface KKTimelineInspectorView (Guide)

/// Screen rect of the play button in the inspector header row. NSZeroRect
/// if not on screen. Used by joyride steps that cutout the play control.
- (NSRect)guidePlayButtonScreenRect;

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

/// First-appearance autostart of the Basic ("Introduction") guide: on the next
/// runloop turn, if the host view is in a window, not a detached copy, no lanes
/// exist yet, and `seenKey` isn't set, marks `seenKey` seen and runs the Basic
/// guide via `timingGuideConfigProvider`. No-op otherwise. Call from
/// -viewDidMoveToWindow.
- (void)autostartIntroGuideOnceWithSeenKey:(NSString *)seenKey;

@end

NS_ASSUME_NONNULL_END
