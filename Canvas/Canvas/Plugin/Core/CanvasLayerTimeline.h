/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKTimeline, KKLane, KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// The layer the inspector edit surfaces currently act on. `selectedLayerID`
/// picks it (matched by KKBezierPath.layerID); falls back to the first
/// non-group (topmost) layer when nil/unmatched. nil when there are no editable
/// layers.
KKBezierPath *_Nullable CanvasSelectedLayerForPaths(
    NSArray<KKBezierPath *> *paths, NSString *_Nullable selectedLayerID);

/// Builds the PLAIN-label timeline the kit inspector edits for `path` (the
/// selected layer): the layer's own animationJSON, or lanes seeded from
/// `templates` (CanvasPlugin.availableLanes) when it has none. Plain labels +
/// one Transform group, so the kit's Animated dropdown / Constants / Keypose
/// (which key by plain name) work unchanged. nil path => empty timeline.
KKTimeline *CanvasLayerTimelineForPath(KKBezierPath *_Nullable path,
                                       NSArray<KKLane *> *templates);

/// Writes an edited selected-layer timeline back into `path.animationJSON`.
/// No-op when `path` is nil.
void CanvasApplyTimelineToPath(KKTimeline *timeline,
                               KKBezierPath *_Nullable path);

/// Seeds a freshly-created GROUP's Anchor lane to its content-bbox centre, so
/// the group's scale/rotation pivot starts where the members sit (matching the
/// old derived-pivot behaviour) but is now STORED - moving a member no longer
/// drags the pivot and swings its siblings. No-op for a non-group /
/// unmeasurable group. `paths` is the layer stack (with the group's members
/// already reparented); `templates` is CanvasPlugin.availableLanes.
void CanvasSeedGroupAnchor(KKBezierPath *_Nullable group,
                           NSArray<KKBezierPath *> *paths,
                           NSArray<KKLane *> *templates);

/// The all-layers GRAPH timeline: every layer's ANIMATED (enabled) lanes across
/// the whole stack, each tagged label "<short>\x1f<layerID>" + layerKey +
/// layerLabel + layerSymbol (folder for groups), ordered by layer-stack order
/// then `templates` (parameter) order. Fed to KKTimelineLanesView.graphTimeline
/// so both graphs show + edit every layer, independent of selection. Layers
/// with nothing animated contribute no rows.
KKTimeline *CanvasMergedTimeline(NSArray<KKBezierPath *> *paths,
                                 NSArray<KKLane *> *templates);

/// Splits an edited merged graph timeline back into each layer's animationJSON,
/// in place on `paths`: groups lanes by layerKey, strips the tag, and replaces
/// the matching plain lanes in each layer's stored timeline (constant/disabled
/// lanes are preserved). `templates` sets each layer's paramOrder.
void CanvasApplyMergedTimelineToPaths(KKTimeline *merged,
                                      NSArray<KKBezierPath *> *paths,
                                      NSArray<KKLane *> *templates);

/// The all-layers AI timeline handed to the AI agent as "current timeline":
/// like CanvasMergedTimeline but ALSO seeds every layer's cross-layer transform
/// lanes (Scale, Position, Rotation, Opacity, Anchor) even when they're still
/// constant, so the agent can animate movement on ANY layer (the kit merge
/// drops mutation operations whose lane label isn't already present). Already
/// -animated non-transform lanes (Stroke Width, Fill Amount, Draw On...) are
/// carried in too so they can be retimed. Same tagged-label scheme
/// ("<short>\x1f<layerID>") as CanvasMergedTimeline, so the merged result feeds
/// straight back through CanvasApplyMergedTimelineToPaths. Per-layer
/// applicability is respected (image/group layers omit vector-only lanes).
KKTimeline *CanvasAITimeline(NSArray<KKBezierPath *> *paths,
                             NSArray<KKLane *> *templates);

/// YES if `path` has at least one constant (non-animated) param - i.e. fewer
/// animated lanes than `templates` (or no animationJSON at all).
BOOL CanvasLayerHasConstant(KKBezierPath *_Nullable path,
                            NSArray<KKLane *> *templates);

/// YES if ANY layer has at least one constant (non-animated) param. Drives
/// whether the Constants button stays available when the selected layer is
/// fully animated.
BOOL CanvasAnyLayerHasConstant(NSArray<KKBezierPath *> *paths,
                               NSArray<KKLane *> *templates);

/// Process-wide snapshot of the current layer blob (base64), published by the
/// inspector and read by the viewer OSC. The OSC can WRITE custom params (its
/// setting API resolves) but gets an EMPTY READ of kParamLayerData (its
/// retrieval API is limited in the OSC context), so it can't load the layer
/// stack to splice its edit into - this static carries it across, mirroring
/// KKProcessTimelineSnapshot. Same process (the snapshot already crosses
/// inspector<->OSC), so a plain static is enough.
void CanvasSetLayerBlobSnapshot(NSString *_Nullable b64);
NSString *_Nullable CanvasLayerBlobSnapshot(void);

/// Process-wide snapshot of the current kParamUIState JSON, published by the
/// inspector and read by the viewer OSC. Same rationale as the layer blob: the
/// OSC can WRITE kParamUIState (e.g. to change the selected layer on a hit-test
/// click) but can't READ the custom param, so it needs the current full state
/// as a base to merge its one key into without dropping the others. Also lets
/// the OSC read view-preference flags like "autoSelect".
void CanvasSetUIStateSnapshot(NSString *_Nullable json);
NSString *_Nullable CanvasUIStateSnapshot(void);

/// Process-wide snapshot of the real render OUTPUT size in pixels, published by
/// the render (which knows `destinationImage.imagePixelBounds`) and read by the
/// viewer OSC. The OSC only knows zoom-dependent on-screen canvas px, but path
/// ops that bake px-relative geometry (stroke-to-outline) need the true output
/// pixels. Same process as render, so a plain static suffices. Returns NO (and
/// leaves the out-params untouched) before the first render has published a
/// size.
void CanvasSetOutputSize(float width, float height);
BOOL CanvasOutputSize(float *_Nonnull outWidth, float *_Nonnull outHeight);

NS_ASSUME_NONNULL_END
