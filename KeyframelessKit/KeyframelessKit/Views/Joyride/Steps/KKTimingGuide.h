/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>

@class KKTimeline;
@class KKTimelineLanesView;
@class KKTimelineInspectorView;
@class KKTimingGuideConfig;
@class KKHelpGuide;
@class KKOSCGuideBridge;
@class KKOSCGuideStrategy;

NS_ASSUME_NONNULL_BEGIN

/// Shared, plugin-agnostic Basic + Advanced timing walkthroughs.
///
/// The timing UI (Basic/Advanced graph, manage popover, gap/curve editor,
/// mini viewer) is identical across every animating plugin, so the step copy
/// and choreography live here once and are localized once in the kit
/// `KKLocalizable` catalog. A plugin adopts a timing guide by handing in a
/// `KKTimingGuideConfig` that names the property to teach (`Radius`,
/// `Position`, ...) and supplies the few *inspector-level* anchors the kit
/// timeline views don't already expose (play button, tab switch, viewer,
/// scrub + play-accent control).
///
/// The plugin keeps owning guide *lifecycle* via its `KKJoyrideGuideHost`
/// (seed timeline, tab forcing, render-mode, play-state ownership, restore).
/// These builders only produce the step array and wire the binder, so they
/// slot straight into the existing `runWithSeed:buildSteps:` call.
@interface KKTimingGuide : NSObject

/// Builds the Basic timing steps (the 13-step lane -> keypose -> easing ->
/// retime flow) and installs their advance/dismiss bindings on `binder`.
/// Returns the ordered step array to hand back from `buildSteps`.
+ (NSArray<KKJoyrideStep *> *)basicStepsForGuide:(KKJoyrideController *)guide
                                          binder:(KKJoyrideLanesBinder *)binder
                                          config:(KKTimingGuideConfig *)config;

/// Builds the Advanced timing steps (tab switch -> per-property orientation ->
/// cmd-click keypose -> value popover -> set easing -> retime) and installs
/// their bindings. Returns the ordered step array.
+ (NSArray<KKJoyrideStep *> *)
    advancedStepsForGuide:(KKJoyrideController *)guide
                   binder:(KKJoyrideLanesBinder *)binder
                   config:(KKTimingGuideConfig *)config;

/// Seed for the Basic guide: the primary lane as a constant (enabled = NO),
/// so the opening constants step has a value to edit in the Constants panel
/// before the user opts it in to animation.
+ (KKTimeline *)basicSeedTimelineForConfig:(KKTimingGuideConfig *)config;

/// Seed for the Advanced guide: the primary (and optional secondary) lane,
/// each animatable with two keyposes at t=0 and t=1, so the user lands on a
/// populated sequencer. Component count + default endpoint values come from
/// `config`.
+ (KKTimeline *)advancedSeedTimelineForConfig:(KKTimingGuideConfig *)config;

/// The two standard help-window entries every animating plugin exposes:
/// "Introduction" (the Basic timing walkthrough) and "Advanced Timing". The
/// title/subtitle copy is localized once here in the kit, each entry is gated
/// by `enabledProvider`, and completion is wired through the inspector's
/// `onGuideCompleted` (strong-captured so it still marks after the help window
/// closes). `inspectorProvider` resolves the live inspector lazily at tap time;
/// it must already have its `timingGuideConfigProvider` set. Returned in
/// display order; hand straight back from `-[KKPlugin helpGuides]`.
+ (NSArray<KKHelpGuide *> *)
    standardHelpGuidesForInspectorProvider:
        (KKTimelineInspectorView * (^)(void))inspectorProvider
                           enabledProvider:(BOOL (^)(void))enabledProvider;

@end

/// Everything a plugin must supply to run the shared timing guides. The
/// property labels parameterize the copy ("Add %@", "Cmd-click the %@ lane");
/// the block hooks bridge the inspector-level controls the kit timeline views
/// can't reach. Labels are already-localized display names so they drop into
/// the kit's localized templates.
@interface KKTimingGuideConfig : NSObject

/// The lanes view the guide drives. Its basic/advanced graphs are read from
/// here; all timeline anchors resolve through the kit `+Guide` categories.
@property(nonatomic, weak) KKTimelineLanesView *lanesView;

/// The inspector view that owns this guide run. Pre-set by
/// -makeTimingGuideConfig. The OSC guide uses it to reach inspector-level OSC
/// hooks + anchors (checkbox, gear, pills); the timing/mini-viewer guides don't
/// need it.
@property(nonatomic, weak) KKTimelineInspectorView *inspectorView;

/// The property the guide teaches, e.g. @"Radius" / @"Position". Required.
@property(nonatomic, copy) NSString *primaryLabel;

/// Optional second property to seed in Advanced (e.g. @"Crop"). The Basic
/// flow teaches a single property; nil keeps it single-lane.
@property(nonatomic, copy, nullable) NSString *secondaryLabel;

/// OSC element labels to keep visible for this guide's duration (the rest are
/// hidden, then restored on end). nil/empty = keep all OSCs. The plugin's
/// restart method applies this to the inspector's `guideOSCKeepLabels`.
@property(nonatomic, copy, nullable) NSArray<NSString *> *oscKeepLabels;

/// Component count for the primary lane (1 for Radius, 2 for Position).
@property(nonatomic) NSInteger primaryComponentCount;

/// Endpoint values written at both t=0 and t=1 for the primary lane in the
/// Advanced seed. Count must match `primaryComponentCount`.
@property(nonatomic, copy) NSArray<NSNumber *> *primarySeedValues;

/// Destination the Basic constants step asks the user to drag the primary
/// handle to (the glowing "drag to here" target). Scalar lanes use the first
/// element; spatial lanes (e.g. Position) use all components. Required for the
/// Basic guide.
@property(nonatomic, copy) NSArray<NSNumber *> *primaryTargetValues;

/// Destination for the Basic keypose-edit step's drag. Keep distinct from
/// `primaryTargetValues` so the handle visibly moves (the keypose starts at
/// the constant value). Falls back to `primaryTargetValues` when nil.
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *keyposeTargetValues;

/// Lane value type for the primary lane (KKLaneValueTypeFloat / Generic / ...).
@property(nonatomic) NSInteger primaryValueType;

/// Optional secondary-lane seed (only consulted when `secondaryLabel` set).
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *secondarySeedValues;
@property(nonatomic) NSInteger secondaryValueType;

/// The mini-viewer guide seeds the primary lane with one keypose per entry
/// here (distinct values, so Filmstrip/Onion show visibly different frames).
/// Each element is a value array matching `primaryComponentCount`. ~4 entries
/// is ideal. Required for the mini-viewer guide; unused by the timing guides.
@property(nonatomic, copy, nullable)
    NSArray<NSArray<NSNumber *> *> *miniViewerSeedValues;

/// Screen rect of the inspector play button. Required (Basic watch-back).
@property(nonatomic, copy) NSRect (^playButtonScreenRect)(void);

/// Screen rect of a tab segment (0 = Basic, 1 = Advanced). Required (Advanced).
@property(nonatomic, copy) NSRect (^tabSegmentScreenRect)(NSInteger tab);

/// Optional: screen rect of the host viewer image, unioned into the Basic
/// watch-back cutout when the OSC is alive. Return NSZeroRect if unavailable.
@property(nonatomic, copy, nullable) NSRect (^viewerScreenRect)(void);

/// The inspector's Constants button view, spotlighted by the opening
/// constants step of the Basic flow. Required for the Basic guide.
@property(nonatomic, copy) NSView * (^constantsButtonView)(void);

/// Park the host playhead at `fraction` (0 = clip start). Wired to the
/// inspector's host-aware scrub (FxCommandAPI movePlayheadToTime:). Required.
@property(nonatomic, copy) void (^scrubToFraction)(double fraction);

/// Toggle host playback (play/pause). Required for the watch-back step.
@property(nonatomic, copy) void (^togglePlayback)(void);

/// Drive the play button's accent on/off directly (the guide owns play state
/// for its duration so FCP's bursty currentTime can't flicker it). Required.
@property(nonatomic, copy) void (^setPlayingAccent)(BOOL playing);

/// Optional: wake the plugin's preview/OSC render so a draw tick lands and
/// `viewerScreenRect` populates before the watch-back cutout is queried (the
/// playhead is static at clip start on enter). No-op safe to omit.
@property(nonatomic, copy, nullable) void (^requestPreviewRender)(void);

/// The shared OSC-guide bridge for this plugin's viewer on-screen control (the
/// same process-lifetime instance the plugin's OSC tick feeds geometry into).
/// Required for the On-Screen Controls guide's interactive viewer-drag step;
/// nil falls back to a narrated (non-interactive) viewer spotlight.
@property(nonatomic, copy, nullable) KKOSCGuideBridge * (^oscGuideBridge)(void);

/// Builds a fresh OSC-shape strategy mapping a viewer drag to this plugin's
/// control value (radius, position, ...) and back. Paired with `oscGuideBridge`
/// to drive the interactive drag-to-target step of the On-Screen Controls
/// guide. nil = narrated fallback.
@property(nonatomic, copy, nullable) KKOSCGuideStrategy * (^oscGuideStrategy)
    (void);

/// The control the OSC guide's inspector pill step has the user disable. Must
/// be a NON-featured control (one NOT shown in the keypose mini-viewer, which
/// only shows the featured lane), so disabling it can't empty the mini-viewer
/// the later steps need. Matched by the compound's master label (e.g. @"Crop").
/// nil = the pill step spotlights the whole bar (any control).
@property(nonatomic, copy, nullable) NSString *oscDisableLabel;

@end

NS_ASSUME_NONNULL_END
