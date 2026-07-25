/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKLane;
@class KKTimeline;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// How a subscriber treats a timeline time OUTSIDE the publisher's authored
/// span [timelineStart, timelineEnd] - e.g. a subscriber clip that starts
/// before or ends after the publisher clip.
typedef NS_ENUM(NSInteger, KKLinkOutOfRange) {
  /// Hold the nearest endpoint value: the start value before the span, the end
  /// value after it.
  KKLinkOutOfRangeHold = 0,
  /// Zero for every component outside the span.
  KKLinkOutOfRangeZero = 1,
};

/// A published parameter curve loaded from the link bus: one lane's animation
/// plus the absolute FCP-timeline span it was authored over. Sample it at any
/// timeline time to get the value the publisher's clip would show there.
@interface KKLinkedCurve : NSObject

@property(nonatomic, readonly) KKLane *lane;
@property(nonatomic, readonly) double timelineStart; // project seconds
@property(nonatomic, readonly) double timelineEnd;   // project seconds
@property(nonatomic, readonly, copy, nullable) NSString *unit;

/// Per-component values at absolute timeline time `tlSec` (project seconds, the
/// value `timelineTime:fromInputTime:` yields). Maps the time into the
/// publisher's clip fraction - clamped to [0,1] outside the authored span, so a
/// subscriber clip that starts before / ends after the publisher holds the end
/// value - and evaluates with the shared smoothed lane sampler. `outOfRange`
/// picks what happens strictly outside the span (hold endpoint vs zero). nil
/// when the lane has no keyposes.
- (nullable NSArray<NSNumber *> *)valuesAtTimelineSeconds:(double)tlSec
                                               outOfRange:
                                                   (KKLinkOutOfRange)outOfRange;

@end

/// One LAYER of a layered source - a "sub-clip" inside a clip (e.g. a Canvas
/// layer), advertising its own referenceable params. `layerID` is the stable
/// identity a `${uuid.layerID.label}` token stores (survives rename);
/// `displayName` is the user-facing layer name the picker/editor show.
@interface KKLinkLayerSource : NSObject
@property(nonatomic, copy) NSString *layerID;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSArray<NSString *> *paramLabels;
/// Friendly names for each `paramLabels` entry (same order/count; falls back
/// to the labels).
@property(nonatomic, copy) NSArray<NSString *> *paramDisplayNames;
/// WRITE-SIDE ONLY carrier (never serialized): the layer's effective lanes,
/// consumed by KKLinkWriteManifestWithLayers /
/// KKLinkPublishReferenceableLanesForLayer, which derive the param lists.
@property(nonatomic, copy, nullable) NSArray<KKLane *> *lanes;
@end

/// A discovered link SOURCE: one plugin instance (clip) advertising itself and
/// the parameters other clips can reference. Written by every instance at its
/// render tick (see KKLinkWriteManifest) and read back by the reference picker
/// (KKLinkBus +allManifests) to build the "link to..." menu grouped by clip.
/// The `uuid` is the stable identity (the instance UUID); `displayName` is a
/// human-facing label (auto `<Effect> @ <timecode>`, renamable later) - NOT
/// unique, so never key off it.
@interface KKLinkManifest : NSObject
@property(nonatomic, copy) NSString *uuid;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic) double clipStartSec; // project seconds at clip fraction 0
@property(nonatomic) double clipDurSec;
/// The source effect's name (e.g. "Mirage"), so the bus can scope operations to
/// one plugin's own manifests. Empty on legacy manifests written before this
/// field existed (they get rewritten with it on the source's next render/load).
@property(nonatomic, copy) NSString *effectName;
/// The FCP document (project/timeline) id this source lives in, as a string
/// (from FxProjectAPI -documentID:). Cross-clip refs only make sense WITHIN one
/// project, so the picker filters manifests to the editing clip's document.
/// Empty when the host can't provide one (older manifests, or FxProjectAPI
/// unavailable) - treated as matching any document so it never hides a source.
@property(nonatomic, copy) NSString *documentID;
/// Seconds since the manifest FILE was last written/touched, captured when the
/// manifest was loaded (+allManifests). A live rendering clip re-touches its
/// manifest every ~10s, so a large age means the clip is not rendering - it
/// may be deleted (FCP gives no deletion signal, so age is the only tell), or
/// merely idle. Drives the picker's staleness warning and freshest-wins
/// display-name disambiguation. Not serialized.
@property(nonatomic) double lastSeenAgeSec;
@property(nonatomic, copy)
    NSArray<NSString *> *paramLabels; // referenceable lanes
/// Friendly names to SHOW for each `paramLabels` entry (same order/count). The
/// LABEL is the stable key a `${uuid.label}` token stores; this is only what
/// the picker menu + editor display. Falls back to the label when a plugin has
/// no nicer name. Older manifests without it read back equal to `paramLabels`.
@property(nonatomic, copy) NSArray<NSString *> *paramDisplayNames;
/// Layered sources (e.g. Canvas): the clip's layers, each with its own param
/// lists - the picker shows Clip > Layer > Param and the token stores
/// `${uuid.layerID.label}`. Empty for flat sources (Mirage), and on manifests
/// written before this field existed.
@property(nonatomic, copy) NSArray<KKLinkLayerSource *> *layers;
@end

/// Cross-effect parameter "link bus": a directory of published curve files that
/// any plugin instance can write and any other can read. It bridges the XPC
/// process boundary the same way Sonar's spectrograms do - the file IS the
/// channel, keyed by absolute FCP-timeline seconds and sampled from each
/// subscriber's own render tick. Lives in the shared app-group container, so it
/// works from the plugin sandbox and across different plugins.
@interface KKLinkBus : NSObject

/// The links directory inside the shared app-group container, created on first
/// call. nil when the app group is unavailable (no entitlement) - callers treat
/// that as "linking off" and fall back to local lane values.
+ (nullable NSURL *)linksDirectory;

/// Resolve the app-group container on a background queue so the first cold
/// lookup (~1-2s in a sandboxed process) doesn't land on the render thread mid-
/// frame. Every plugin process that may publish or subscribe should call this
/// at init, before the render loop. Idempotent and cheap after the first call.
+ (void)warmUp;

/// Write `lane`'s curve to `<linkID>.json`, tagged with the absolute timeline
/// span [tlStart, tlEnd] the publisher's clip covers. Idempotent: a byte-
/// identical republish is skipped (per-process cache), so calling every render
/// tick is cheap. Call from the render tick - the only place timeline seconds
/// resolve.
+ (void)publishLane:(KKLane *)lane
             linkID:(NSString *)linkID
      timelineStart:(double)tlStart
        timelineEnd:(double)tlEnd
               unit:(nullable NSString *)unit;

/// Load the published curve for `linkID`, or nil when nothing is published
/// (yet) under that name / the file fails to decode. Cached per process and
/// invalidated on the file's mtime/size, so calling it every render tick is
/// cheap (an atomic republish swaps the file and the cache refreshes).
+ (nullable KKLinkedCurve *)loadCurve:(NSString *)linkID;

/// Display names of every currently-published link (sorted, de-duplicated), for
/// the subscribe picker. Reads the bus directory; call on demand (not the
/// render path).
+ (NSArray<NSString *> *)publishedLinkNames;

/// Nanosecond change-stamp of the published file for `name` (0 if absent). A
/// subscriber's watcher polls this to notice a source changed.
+ (long long)changeStampForLink:(NSString *)name;

/// The manifests directory inside the shared app-group container (parallel to
/// linksDirectory), created on first call. nil when the app group is
/// unavailable.
+ (nullable NSURL *)manifestsDirectory;

/// Write `manifest` to `<uuid>.manifest.json`. Idempotent: a byte-identical
/// rewrite is skipped (per-process cache), so calling it every render tick is
/// cheap. No-op when the manifest has no uuid.
+ (void)writeManifest:(KKLinkManifest *)manifest;

/// Every manifest currently on the bus, sorted by clip start then display name
/// - the source list the reference picker enumerates. Reads the directory; call
/// on demand (not the render path).
+ (NSArray<KKLinkManifest *> *)allManifests;

/// `allManifests` filtered to the given FCP document, so a clip's reference
/// picker only sees OTHER clips in the SAME project (not the whole library). A
/// manifest with an empty `documentID` (legacy / host couldn't provide one)
/// always matches, and a nil/empty `documentID` argument returns everything -
/// both degrade to the old library-wide behaviour rather than hiding sources.
+ (NSArray<KKLinkManifest *> *)manifestsForDocumentID:
    (nullable NSString *)documentID;

/// The thumbnails directory inside the shared app-group container (parallel to
/// manifestsDirectory), created on first call. Small per-clip JPEGs keyed by
/// instance UUID so the reference-insert menu can show what each source clip
/// looks like. nil when the app group is unavailable.
+ (nullable NSURL *)thumbnailsDirectory;

/// Write (or refresh) a clip's menu thumbnail JPEG, keyed by the same instance
/// UUID its manifest uses. A byte-identical rewrite is skipped. No-op on empty
/// data / uuid.
+ (void)writeThumbnailJPEG:(NSData *)jpeg forUUID:(NSString *)uuid;

/// Per-layer variant for layered sources (Canvas): keyed `uuid` + `layerID`,
/// shown on the picker's layer submenu items. nil/empty layerID = the
/// effect-level thumbnail.
+ (void)writeThumbnailJPEG:(NSData *)jpeg
                   forUUID:(NSString *)uuid
                   layerID:(nullable NSString *)layerID;
+ (nullable NSString *)thumbnailPathForUUID:(NSString *)uuid
                                    layerID:(nullable NSString *)layerID;

/// Filesystem path to a clip's thumbnail, or nil if none has been written. Used
/// by the reference menu to load the image (on demand, not the render path).
+ (nullable NSString *)thumbnailPathForUUID:(NSString *)uuid;

/// Remove EVERY trace of a source instance from the bus: its manifest, its
/// thumbnail, and every published curve file (`<uuid>.<label>`), plus the
/// per-process idempotency cache. Safe to call for a uuid that published
/// nothing.
+ (void)removeSourceForUUID:(NSString *)uuid;

/// Reconcile ONE effect's manifests against the set of its currently-LIVE
/// instance uuids: remove any manifest for `effectName` whose uuid is NOT in
/// `liveUUIDs` (a deleted / orphaned source). The caller builds `liveUUIDs`
/// from -pluginInstanceAddedToDocument, which fires on document load for every
/// existing instance - so a uuid absent from that set no longer exists. Scoped
/// by effect name so one plugin never touches another plugin's manifests
/// (legacy manifests with no recorded effect name are treated as matching,
/// since they predate multi-plugin use and self-heal on the source's next
/// write). Returns the uuids it removed.
+ (NSArray<NSString *> *)reconcileEffectName:(NSString *)effectName
                                keepingUUIDs:(NSSet<NSString *> *)liveUUIDs;

@end

/// Advertise this instance as a link source: gather its uuid (via
/// KKInstanceUUIDForAPI - read-only, a no-op when the instance has no UUID
/// yet), build a `<effectName> @ <timecode>` display name from `clipStartSec`,
/// record the REFERENCEABLE lanes' labels as params, and write the manifest
/// (idempotent). Pass the EFFECTIVE lane set (e.g. directive-seeded constants),
/// NOT just the persisted timeline, so a fresh clip is referenceable
/// immediately; the kit filters out lanes an expression can't consume (code
/// lanes, palette-generator bars). Call from the render tick, where the clip's
/// absolute span resolves. Engine-generic: one call gives any plugin discovery
/// for free.
/// `effectName` is the plugin's IDENTITY (scoping key for bus operations like
/// +reconcileEffectName:); `displayBaseName` is what the picker SHOWS, as
/// "<displayBaseName> @ <timecode>". They differ when an instance has a name of
/// its own (a Mirage clip running a named shader). Pass nil / empty to show the
/// effect name - never fold a per-instance name into `effectName` itself, or
/// orphan cleanup stops matching that instance's manifests.
FOUNDATION_EXPORT void
KKLinkWriteManifest(id<PROAPIAccessing> api, NSArray<KKLane *> *lanes,
                    double clipStartSec, double clipDurSec,
                    NSString *effectName, NSString *_Nullable displayBaseName);

/// Layered variant of KKLinkWriteManifest for plugins whose referenceable
/// params live on per-layer timelines (layers are "sub-clips": Canvas). Each
/// KKLinkLayerSource carries layerID + displayName + its EFFECTIVE `lanes`;
/// the kit derives the per-layer param lists with the same referenceable
/// filter. `topLevelLanes` may add clip-wide params alongside (empty = none).
/// Call from the render tick, like the flat variant.
FOUNDATION_EXPORT void KKLinkWriteManifestWithLayers(
    id<PROAPIAccessing> api, NSArray<KKLane *> *topLevelLanes,
    NSArray<KKLinkLayerSource *> *layers, double clipStartSec,
    double clipDurSec, NSString *effectName,
    NSString *_Nullable displayBaseName);

/// Per-layer counterpart of KKLinkPublishReferenceableLanes: publishes each
/// referenceable lane of `layer.lanes` keyed `<uuid>.<layerID>.<label>` - the
/// token a subscriber's `${Clip.Layer.Param}` stores. Same idempotency and
/// render-tick contract as the flat variant.
FOUNDATION_EXPORT void KKLinkPublishReferenceableLayer(id<PROAPIAccessing> api,
                                                       KKLinkLayerSource *layer,
                                                       double tlStart,
                                                       double tlEnd);

/// Auto-publish every referenceable lane in `lanes` as a link-bus curve keyed
/// `<uuid>.<label>` (the token another clip stores when it references
/// `${Clip.Param}`), tagged with the absolute timeline span [tlStart, tlEnd].
/// This is the render-tick counterpart to KKLinkWriteManifest: the manifest
/// advertises WHICH params exist, this publishes their actual curves so a
/// subscriber resolves them. Pass the EFFECTIVE lanes (defaults overlaid with
/// the user's real keyposes) so both a fresh and an edited clip publish the
/// value the render uses. Idempotent per lane (byte-identical republish
/// skipped), so calling every render tick is cheap. No-op when the instance has
/// no UUID yet.
FOUNDATION_EXPORT void KKLinkPublishReferenceableLanes(id<PROAPIAccessing> api,
                                                       NSArray<KKLane *> *lanes,
                                                       double tlStart,
                                                       double tlEnd);

/// Resolved value of `lane` at clip fraction `frac`: when the lane carries a
/// non-trivial `linkExpression`, the expression evaluated at absolute
/// `timelineSec` (`value` = own value, `${name}` = a source resolved
/// recursively); otherwise the normal smoothed lane value. `timelineSec` is
/// true FCP timeline seconds (`timelineTime:fromInputTime:`); `clipDurSec` is
/// the clip's duration, so the expression's `progress` (= frac) and `ct` (=
/// frac * clipDurSec, seconds since the clip started) resolve. Both computed by
/// the plugin at its render tick.
///
/// A drop-in for `KKLaneDisplayValueAtFraction` in a link-aware
/// render path - a lane with no expression behaves identically. This is the ONE
/// place a plugin routes lane evaluation through to get linking; the kit owns
/// the behaviour, the plugin just calls it.
FOUNDATION_EXPORT NSArray<NSNumber *> *_Nullable KKLinkResolvedLaneValue(
    KKLane *lane, double frac, double timelineSec, double clipDurSec);

/// A live-drag override for referenced sources: given a `${ref}` source name
/// (in its stored `uuid.label` form), return an in-flight value to use INSTEAD
/// of that source's published bus curve, or nil to fall through to the bus.
/// Lets a mini-viewer make an expression that references a lane being dragged
/// (e.g. `rotation` derived from `${split}`) update in REAL TIME during the
/// drag, before it commits and republishes.
typedef NSArray<NSNumber *> *_Nullable (^KKLinkRefOverride)(NSString *refName);

/// `KKLinkResolvedLaneValue` with a live-drag override for the sources its
/// expression references (see KKLinkRefOverride). `refOverride == nil` is
/// identical to the plain form.
FOUNDATION_EXPORT
NSArray<NSNumber *> *_Nullable KKLinkResolvedLaneValueWithOverride(
    KKLane *lane, double frac, double timelineSec, double clipDurSec,
    KKLinkRefOverride _Nullable refOverride);

/// The source names a timeline's lanes reference - the `${refs}` across all
/// lanes' linkExpressions - so a subscriber knows which sources to watch for
/// live re-render. Empty when nothing references anything.
FOUNDATION_EXPORT NSSet<NSString *> *
KKLinkTimelineSourceNames(KKTimeline *timeline);

/// Translate an expression's FRIENDLY refs (`${Clip.Param}`, as the picker
/// shows them and as an AI would write them) to the STORED form
/// (`${uuid.rawLabel}`) the model persists, using `manifests` (typically
/// `+[KKLinkBus allManifests]`). Plain text and unmatched names pass through
/// untouched (first clip whose displayName matches wins, mirroring the editor).
/// Use it to write an expression built from display names straight onto a lane,
/// bypassing the editor's own translation.
FOUNDATION_EXPORT NSString *
KKLinkStoredExpressionFromDisplay(NSString *display,
                                  NSArray<KKLinkManifest *> *manifests);

/// The inverse: translate an expression's STORED refs (`${uuid.rawLabel}`) to
/// the FRIENDLY display form (`${Clip.Param}`) for showing in the editor, using
/// `manifests`. Plain text and unknown uuids (source gone) pass through
/// untouched, so a broken ref stays visible.
FOUNDATION_EXPORT NSString *
KKLinkDisplayExpressionFromStored(NSString *stored,
                                  NSArray<KKLinkManifest *> *manifests);

/// The FCP document (project) id for `api`'s instance, as a string, via
/// FxProjectAPI -documentID:. nil when the host can't provide one (older host,
/// API unavailable, or an error) - callers treat nil as "unscoped". Cheap; safe
/// to call on the render tick.
FOUNDATION_EXPORT NSString *_Nullable KKLinkDocumentIDForAPI(
    id<PROAPIAccessing> api);

/// The document (project) id a clip is in, read off its OWN manifest on the bus
/// (keyed by instance `uuid`). For the VIEW side (ViewBridge process), which
/// has no render context to resolve FxProjectAPI but can read the manifest the
/// render process wrote. nil when `uuid` is empty or no manifest is published
/// yet.
FOUNDATION_EXPORT NSString *_Nullable KKLinkDocumentIDForSelfUUID(
    NSString *_Nullable uuid);

/// A compact JSON catalog of every OTHER clip on the bus and its referenceable
/// parameters, for grounding an AI that writes cross-clip `${Clip.Param}` refs:
/// `[{"clip":"<displayName>","params":["<paramDisplay>", ...]}]`. Excludes the
/// manifest whose uuid equals `excludeUUID` (the asking clip itself) and scopes
/// to `documentID` (the asking clip's project; nil = library-wide). Returns
/// `[]` when nothing else is published.
FOUNDATION_EXPORT NSString *
KKLinkAvailableSourcesJSON(NSString *excludeUUID,
                           NSString *_Nullable documentID);

NS_ASSUME_NONNULL_END
