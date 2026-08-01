/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MirageInspectorView.h"
#import "Plugin.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPlayheadPoller;

@interface MiragePlugin ()
/// Covariant re-type of the KKPlugin base property (one storage, @dynamic in
/// the implementation).
@property(nonatomic, weak, nullable) MirageInspectorView *inspectorView;
// miniViewerFeed + miniDragUndoStarted now live on the KKPlugin base.
@property(nonatomic, strong, nonnull) KKRenderCache *renderCache;
@property(nonatomic, strong, nullable) KKPlayheadPoller *playheadPoller;
/// Subscriber-side link watcher: polls the published sources this clip's
/// expressions reference and forces a re-render when one changes (FCP won't
/// refresh a subscriber on a cross-clip source edit). Fed each render in
/// buildStates; nil until this clip references something.
@property(nonatomic, strong, nullable) KKLinkWatcher *linkWatcher;
/// Persistent feedback-buffer state for Custom multi-pass shaders that read
/// their own (or a later) buffer's previous frame. Keyed by "WxH" so the main
/// viewer, thumbnails, and library previews keep independent ping-pong sets.
/// Holds `MirageFeedbackSet` values (see MirageFeedbackSet.h).
@property(nonatomic, strong, nullable) NSMutableDictionary *feedbackSets;
/// waitUntilCompleted calls made during render callbacks by anything other than
/// the kit helper. ONE mandatory wait per callback is the architecture, on
/// every path; a non-zero value names a path that reintroduced a second round
/// trip. Reported by the `[RenderGuard] STRAY WAITS` line and cleared when it
/// emits.
@property(nonatomic) NSInteger renderStrayWaitsSnapshot;
@property(nonatomic) NSInteger renderStrayWaitsRestore;
@property(nonatomic) NSInteger renderStrayWaitsBlurDrain;
/// Throttle for that line, so a sustained stray cannot flood the log.
@property(nonatomic) NSTimeInterval renderStrayWaitsLastLog;
/// Motion-blur samples the last render asked for. KKMotionBlur commits AND
/// waits per sample, so this is a round-trip multiplier the canary cannot count
/// from outside: N samples are N waits plus one for the accumulate.
@property(nonatomic) NSInteger lastRenderBlurSamples;
/// Reused gamma-conversion destinations, keyed by role (see the
/// `MirageGammaDest*` keys): the source, the To well, and one per `// #frames`
/// neighbour. Held per instance so the render stops allocating a
/// full-resolution RGBA16Float per converted texture per frame. Safe to reuse
/// across frames because the render callback commits AND waits before
/// returning, so no previous frame can still be reading one.
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSNumber *, id<MTLTexture>> *gammaDestinations;
/// Last-read Sonar tickets (key -> ticket), refreshed by `syncAudioTickets…`.
///
/// Cached because the lane builder needs them where the param APIs don't
/// resolve: `availableLanesProvider` fires from a code-commit callback, which
/// is outside any action scope, and reading a parameter there returns nil.
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *audioTickets;
@end

NS_ASSUME_NONNULL_BEGIN

@interface MiragePlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface MiragePlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
+ (NSArray<KKLane *> *)availableLanes;
/// Source-aware lane set: Core lanes + the dynamic lanes the given shader
/// source declares (e.g. the `// #color` Colours group).
+ (NSArray<KKLane *> *)availableLanesForShaderSource:(NSString *)source;
/// As above, plus what this instance remembers about its `#audio` bindings, so
/// a lane bound to a source not published here can name it instead of reading
/// "None". Pass nil where that doesn't matter (the OSC draws no such label).
+ (NSArray<KKLane *> *)
    availableLanesForShaderSource:(NSString *)source
                     audioTickets:
                         (nullable NSDictionary<NSString *, id> *)tickets;
/// As above, with the timeline whose `#slots` registry says how many instances
/// of each repeatable group exist. Every control inside a `// #slots` block is
/// a PROTOTYPE, so this is the only entry that returns the real rows for one -
/// pass nil (the entries above) where the question is about the source rather
/// than about a project, and the prototypes come back instead.
///
/// A group the timeline has never registered is brought up to the declared
/// `default=` here, which mutates `timeline` in place.
+ (NSArray<KKLane *> *)
    availableLanesForShaderSource:(NSString *)source
                     audioTickets:
                         (nullable NSDictionary<NSString *, id> *)tickets
                         timeline:(nullable KKTimeline *)timeline;
/// The current shader source from a timeline's "Mirage" code lane (baked
/// default when absent).
+ (NSString *)shaderSourceFromTimeline:(KKTimeline *)timeline;
/// The PROTOTYPE lanes of one `// #slots` group: the lane set one instance of
/// it is a copy of. What a caller stamping a new instance hands the kit.
+ (NSArray<KKLane *> *)slotPrototypeLanesForShaderSource:(NSString *)source
                                                   group:(NSString *)groupName;
/// The OSC-visibility compound groups (empty for now - the legacy Origin /
/// Scale / Rotation controls are gone pending shader-exposed OSCs). Single
/// source of truth: createView wires these and parameterChanged refreshes from
/// them, so the element-key list can't drift out of sync (which silently breaks
/// OSC hide persistence + opt-click).
+ (NSArray<NSArray<NSString *> *> *)oscCompounds;
/// Per-shader OSC-visibility compounds: one element per `osc`-annotated lane
/// the given source declares (point handle / rotation gizmo / ...). Drives the
/// settings-cog popover + hide persistence for the current shader.
+ (NSArray<NSArray<NSString *> *> *)oscCompoundsForShaderSource:
    (NSString *)source;
@end

@interface MiragePlugin (AudioTickets)
/// Records what each `#audio` lane is bound to, so the binding can still be
/// named on a Mac where the source was never published (nothing but plugin
/// parameters travels inside an FCP library).
///
/// Idempotent and self-scoping: writes only when something actually changed,
/// and opens its own action scope. Never call from the render path.
///
/// Takes the timeline rather than reading the process snapshot, which is empty
/// until something seeds it - a caller that already holds the canonical one
/// shouldn't be made to depend on having seeded it first.
- (void)syncAudioTicketsForTimeline:(nullable KKTimeline *)timeline;
@end

@interface MiragePlugin (Render)
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

@interface MiragePlugin (RenderState)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
