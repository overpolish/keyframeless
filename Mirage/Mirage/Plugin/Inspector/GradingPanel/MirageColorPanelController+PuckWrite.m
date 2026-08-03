/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageColorPanelController.h"

#import <KeyframelessKit/KKFloatingPanel.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKPaddedScrollView.h>
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

#import "MirageColorPanelController_Internal.h"
#import "MirageColorSurfaceProps.h"
#import "MirageLocalized.h"
#import "MirageScopeSampler.h"
#import "MirageSurfaceCircleView.h"
#import "MirageSurfaceCircleView_Internal.h" // cancelDrag
#import "MirageSurfaceResponse.h"
#import "Plugin_Private.h" // +shaderSourceFromTimeline:

/// The same name for the logs, which are read as evidence and must not change
/// with the user's language.
static NSString *MirageRingLogName(MirageColorSurfaceRing ring) {
  if (ring == MirageColorSurfaceRingHue)
    return @"hue";
  if (ring == MirageColorSurfaceRingLight)
    return @"light";
  return @"surface";
}

/// The glyph for a handle that declared no symbol and is not one of a numbered
/// run: the shader's single global puck. An icon-like mark rather than a word -
/// it is drawn at nine points inside a handle and is never read as language -
/// so it is deliberately NOT localized.
static NSString *const kMirageGlobalPuckGlyph = @"G";

/// Put the declared glyph on `puck`, deciding between a symbol and literal
/// text.
///
/// The symbol slot is resolved as an SF Symbol first, because that is what
/// nearly every template writes. A name macOS does not have is then taken at
/// its word and drawn as text: authors ask for "S" or "3" far more often than
/// there is a symbol shaped like it, and a mistyped symbol name that reads as
/// itself is a typo you can see rather than a handle that silently lost its
/// mark.
///
/// With nothing declared the defaults fill in: a `#slots` instance shows its
/// own number, anything else shows the global glyph. Both are last resorts - an
/// authored symbol or text always wins.
static void MirageApplyPuckGlyph(MirageSurfacePuck *puck,
                                 NSDictionary<NSString *, NSString *> *spec) {
  NSString *symbol = spec[@"symbol"] ?: @"";
  if (symbol.length) {
    puck.icon = [NSImage imageWithSystemSymbolName:symbol
                          accessibilityDescription:nil];
    if (!puck.icon)
      puck.textGlyph = symbol;
    return;
  }
  NSString *number = spec[@"number"] ?: @"";
  puck.textGlyph = number.length ? number : kMirageGlobalPuckGlyph;
}

/// YES when `r` belongs to the puck being dragged. A shader with no `puck=` has
/// one unnamed puck and every mapping belongs to it.
BOOL MirageResponseBelongsToPuck(MirageSurfaceResponse r, NSString *puckName) {
  return [(@(r.puck) ?: @"") isEqualToString:puckName ?: @""];
}

@implementation MirageColorPanelController (PuckWrite)

- (void)_focusLeftPanel:(NSNotification *)note {
  [self _endPuckDragReason:@"the app resigned active"];
}

- (void)_windowResignedKey:(NSNotification *)note {
  if (note.object != _panel)
    return;
  [self _endPuckDragReason:@"the panel's window resigned key"];
}

// Put every mapped control back to its declared `default=`, which is by
// definition where a centred puck sits. Written as one undo group, like a drag,
// so a reset is a single step back.
- (void)_resetMappedControlsForPuck:(NSUInteger)puckIndex
                               ring:(NSUInteger)ringIndex {
  // A double-click reaches the view's reset branch without its drag branch, so
  // a drag left open by a lost mouse-up would still be open here.
  [self _endPuckDragReason:@"recentred"];
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline)
    return;
  NSString *source = [self _entrySource:timeline];
  NSDictionary<NSString *, NSValue *> *responses =
      [self _responsesForRing:ringIndex source:source];
  if (!responses.count)
    return;
  double frac = [self _editFraction];
  // Recentring is the puck's own gesture, so it reaches exactly what that puck
  // reaches: the handle you double-clicked, not every correction in the circle.
  NSString *puckName = [self _puckNameAtIndex:puckIndex
                                         ring:ringIndex
                                       source:source];
  if (!puckName)
    return;
  NSSet<NSString *> *drivable = [self _drivableKeysIn:timeline fraction:frac];
  NSMutableArray<KKLane *> *lanes = [timeline.lanes mutableCopy];
  BOOL changed = NO;
  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKLane *lane = lanes[i];
    // `responses` is keyed by the uniform name the SHADER declared, the lane by
    // its rack-scoped key - so the lookup crosses the strip/prefix boundary
    // (nil = another entry's lane, which this panel is not about). `drivable`
    // is a set of real timeline keys and stays on `lane.key`.
    NSString *bare = [self _bareKeyForLane:lane];
    NSValue *boxed = bare ? responses[bare] : nil;
    if (!boxed || ![drivable containsObject:lane.key])
      continue;
    MirageSurfaceResponse r;
    [boxed getValue:&r];
    if (!r.hasBase || !MirageResponseBelongsToPuck(r, puckName))
      continue;
    NSArray<NSNumber *> *current = KKTimelineLaneValueAtFraction(lane, frac);
    if (!current.count)
      continue;
    NSInteger idx = KKLaneNearestKeyposeIndex(lane, frac);
    if (idx == NSNotFound)
      continue;
    NSMutableArray<NSNumber *> *values = [current mutableCopy];
    if (r.baseIsHue) {
      // Rotate back to the declared hue rather than replacing the colour, so
      // the lightness and colourfulness the user chose survive the recentre.
      // Oklab, because `r.base` is an Oklab angle and so is everything the
      // wheel paints.
      if (values.count < 3)
        continue;
      double L = 0.0, chroma = 0.0, hue = -1.0;
      MirageSurfaceOklabLCh(MAX(0.0, MIN(1.0, values[0].doubleValue)),
                            MAX(0.0, MIN(1.0, values[1].doubleValue)),
                            MAX(0.0, MIN(1.0, values[2].doubleValue)), &L,
                            &chroma, &hue);
      if (hue < 0.0)
        continue;
      double nr = 0.0, ng = 0.0, nb = 0.0;
      MirageSurfaceEncodedForOklabLCh(L, chroma, r.base, &nr, &ng, &nb);
      values[0] = @(nr);
      values[1] = @(ng);
      values[2] = @(nb);
    } else {
      if (fabs(current.firstObject.doubleValue - r.base) < 1e-9)
        continue;
      values[0] = @(r.base);
    }
    lanes[i] = KKLaneBySettingValuesAtIndex(lane, idx, values);
    changed = YES;
  }
  if (!changed)
    return;
  KKTimeline *updated = [timeline copy];
  updated.lanes = lanes;
  [self _beginWriteGroup:@"recentre"];
  if (self.onTimelineMutated)
    self.onTimelineMutated(updated);
  [self _endWriteGroup:@"recentre"];
  [self _refreshPuck];
}

// Every write this panel makes goes through this pair, and the BOOL is what
// makes the pairing structural.
//
// FCP reported a caught exception from inside our own "Adjust Mirage" action -
// FFChannelChangeContext willSetChannel: through FFChannelAction lockChannels -
// which is what its channel lock raises when a second undo group opens inside
// one that is still open. Reordering the call sites cannot prevent that,
// because the missing end is not a call site at all: it is a mouse-up that was
// delivered to another application. So the guard closes the stale group instead
// of trusting anyone to have closed it.
- (void)_beginWriteGroup:(NSString *)reason {
  if (_writeGroupOpen) {
    KKLogWarn(@"[Surface] a write group was still open when \"%@\" began - a "
              @"mouse-up was lost; closing it first",
              reason);
    [self _endWriteGroup:@"superseded by a new write"];
  }
  _writeGroupOpen = YES;
  KKLogInfo(@"[Surface] write group OPEN (%@)", reason);
  if (self.onDragBegin)
    self.onDragBegin();
}

- (void)_endWriteGroup:(NSString *)reason {
  if (!_writeGroupOpen)
    return; // idempotent: safe to call from every teardown path
  _writeGroupOpen = NO;
  KKLogInfo(@"[Surface] write group CLOSED (%@)", reason);
  if (self.onDragEnd)
    self.onDragEnd();
}

/// Show the values this tick just wrote in the preview, the way a constants
/// slider drag already does.
///
/// The mini viewer renders the shader IN PROCESS, reading each uniform through
/// the renderer's -valuesForLabel:, which prefers a live override over the
/// committed timeline. The puck's own write leaves through the host - the whole
/// timeline as JSON plus a render nudge, once per tick - and the picture under
/// the cursor should not be a statement about whether that round trip has
/// landed. Additive: the write itself is untouched, and the override is dropped
/// the moment the drag ends, so the committed timeline takes over again.
///
/// Pushed at the RENDERER's own edit fraction, not the panel's: the override is
/// fraction-keyed and only answers when the two agree, and it is the renderer
/// that will be asked at draw time.
- (void)_pushLivePreviewValues:
    (NSDictionary<NSString *, NSArray<NSNumber *> *> *)values {
  KKMiniViewerRenderer *renderer =
      (KKMiniViewerRenderer *)_lanesView.miniViewerDelegate;
  if (![renderer isKindOfClass:[KKMiniViewerRenderer class]])
    return;
  double fraction = renderer.editFraction;
  for (NSString *key in values)
    [renderer setLiveValues:values[key] forLabel:key atFraction:fraction];
  [self _redrawPreview];
}

/// Assert BOTH of the panel's preview overrides: whether the matte is showing,
/// and which key it is about.
///
/// Overrides and nothing else. These two answer "what am I looking at", which
/// changes on every click and is not a decision about the shot - so writing
/// them would spend an undo entry per glance, and a project reopened tomorrow
/// would come up showing a grey diagnostic instead of the shot. Neither has a
/// lane to write to any more: the catalog leaves a `preview=` control out of
/// the lane set entirely.
///
/// Which is also why nothing here checks that a lane EXISTS. The override
/// channel is keyed by LABEL and consulted before any lane, and the shader
/// model fills its uniform pool by walking the DECLARED uniforms - so a name
/// with no lane still gets asked, still finds this override, and falls back to
/// the author's `default=` when there is none. That fallback is what Final
/// Cut's viewer renders, always: an override is mini-viewer-local, so the
/// matte is a thing you see while you are grading and never a thing you ship.
///
/// One method for both, so every path that clears overrides has ONE call to
/// make to put them back rather than a list to remember.
///
/// Idempotent: the record of what is asserted is compared first, because
/// pushing marks the preview as needing display and this runs on every sampled
/// frame - an unconditional push would be a redraw loop that never settles.
- (void)_pushPreviewOverrides {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline)
    return;
  NSString *source = [self _entrySource:timeline];
  NSString *selectionKey = MirageSurfaceSelectionToggleForSource(source);
  NSString *activeKey = MirageSurfaceActiveKeyControlForSource(source);
  if (!selectionKey.length && !activeKey.length)
    return;
  KKMiniViewerRenderer *renderer =
      (KKMiniViewerRenderer *)_lanesView.miniViewerDelegate;
  double fraction = [renderer isKindOfClass:[KKMiniViewerRenderer class]]
                        ? renderer.editFraction
                        : 0.0;
  NSInteger number = activeKey.length ? [self _activeKeyNumber] : 0;
  BOOL showing = _showSelectionActive;
  // The override is fraction-keyed and only answers when the renderer's own
  // edit fraction agrees, so a playhead move needs a fresh push even at the
  // same values - which is why the fraction is part of what "already asserted"
  // means.
  if (_pushedActiveKey && _pushedActiveKey.integerValue == number &&
      _pushedSelection == showing &&
      fabs(_pushedActiveKeyFraction - fraction) < 1e-9)
    return;
  _pushedActiveKey = @(number);
  _pushedSelection = showing;
  _pushedActiveKeyFraction = fraction;
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *push =
      [NSMutableDictionary dictionary];
  if (selectionKey.length)
    push[selectionKey] = @[ @(showing ? 1.0 : 0.0) ];
  if (activeKey.length)
    push[activeKey] = @[ @(number) ];
  [self _pushLivePreviewValues:push];
}

/// Which key the active handle belongs to: the instance's own NUMBER, or zero
/// for a handle that is not a slot instance at all.
///
/// The number comes off the expanded puck entry, which carries the INSTANCE it
/// was stamped from - not the handle's position in the puck array. Those two
/// disagree the moment a group puts more than one handle on a key, which is
/// exactly what Qualifier does: "Key {n}" and "Key {n} Adjust" are two pucks of
/// the same instance, so the array runs 0,1,2,3 across two keys while the
/// numbers run 1,1,2,2. Reading the index would have shown key 2's matte while
/// dragging key 1's second handle.
///
/// Zero is also the honest answer for a shader with no `#slots` at all: the
/// marker is pointless there, every handle is the whole shader, and "all keys"
/// is what the matte already shows.
- (NSInteger)_activeKeyNumber {
  NSString *source = [self _entrySource:_lanesView.currentTimeline];
  NSDictionary<NSString *, NSString *> *entry =
      [self _activeSlotPuckInSource:source];
  return entry[@"number"] ? entry[@"number"].integerValue : 0;
}

- (void)_clearLivePreviewValues {
  _liveDragValues = nil;
  // -clearLiveValues drops EVERY override, the active key's among them, so the
  // record of what is asserted has to go with it. Without this the re-push at
  // each clear site would find its own number already recorded and skip - the
  // matte would fall back to the union for the rest of the session.
  _pushedActiveKey = nil;
  KKMiniViewerRenderer *renderer =
      (KKMiniViewerRenderer *)_lanesView.miniViewerDelegate;
  if (![renderer isKindOfClass:[KKMiniViewerRenderer class]])
    return;
  [renderer clearLiveValues];
  [self _redrawPreview];
}

/// The preview is a PAUSED Metal view, so it holds its last frame until someone
/// marks it. Asked for by name rather than relying on the renderer's own
/// `canvas` back-reference, which is whichever view last called into the
/// delegate.
- (void)_redrawPreview {
  KKMiniViewerView *mini =
      _measuredMini ?: MirageFindMiniViewer(_popoverContentView);
  [mini setNeedsDisplay:YES];
  [mini setHandlesNeedDisplay];
}

- (void)_beginPuckDrag:(NSUInteger)puckIndex ring:(NSUInteger)ringIndex {
  // A drag whose mouse-up went to another application never reached
  // -_endPuckDrag, so the view can hand us a second begin with the first still
  // open. End it here, the way the mini viewer's overlay ends a drag on a new
  // mouseDown. The ring the new drag is on is kept, since its view has just
  // latched on purpose.
  [self _endPuckDragReason:@"lost mouse-up - a new drag began"
               keepingRing:ringIndex];
  // Before the capture below, which reads through -_valuesForLane: and would
  // otherwise seed this drag from an override the previous one left behind.
  [self _clearLivePreviewValues];
  // A pending commit cannot survive into a new drag: the end above wrote it,
  // and anything still here would be a timeline computed from a base this drag
  // has already moved on from.
  _pendingPuckCommit = nil;
  KKTimeline *timeline = _lanesView.currentTimeline;
  NSString *ring = MirageRingLogName([self _ringAtIndex:ringIndex]);
  if (!timeline) {
    KKLogWarn(@"[Surface] %@ puck %lu drag began with no timeline, no group "
              @"opened",
              ring, (unsigned long)puckIndex);
    return;
  }
  NSString *source = [self _entrySource:timeline];
  NSDictionary<NSString *, NSValue *> *responses =
      [self _responsesForRing:ringIndex source:source];
  NSMutableDictionary *captured = [NSMutableDictionary dictionary];
  double frac = [self _editFraction];
  for (KKLane *lane in timeline.lanes) {
    NSString *bare = [self _bareKeyForLane:lane];
    if (!bare || !responses[bare])
      continue;
    NSArray<NSNumber *> *values = [self _valuesForLane:lane fraction:frac];
    // Captured under the REAL key: this dictionary is read back against
    // `lane.key` on every drag tick, and against the renderer's live-value
    // overrides, both of which speak full timeline keys.
    if (values.count)
      captured[lane.key] = values;
  }
  _dragStartValues = captured;
  _puckDragIndex = puckIndex;
  _puckDragRing = ringIndex;
  _puckDragActive = YES;
  KKLogInfo(@"[Surface] %@ puck %lu drag beginning", ring,
            (unsigned long)puckIndex);
  [self _beginWriteGroup:[NSString stringWithFormat:@"%@ puck %lu drag", ring,
                                                    (unsigned long)puckIndex]];
  // AFTER the capture above, which is why the clear near the top of this method
  // could not simply spare this one override: the capture reads through
  // -_valuesForLane: and has to start from the committed timeline. Re-asserted
  // here instead, in the same event, so the matte never shows a frame of the
  // union - and this is also the path a click that CHANGES the active handle
  // takes, since the view sets activePuck before it calls back.
  [self _pushPreviewOverrides];
}

- (void)_endPuckDragReason:(NSString *)reason {
  [self _endPuckDragReason:reason keepingRing:NSNotFound];
}

/// End an in-progress puck drag exactly once, whatever ended it, and make the
/// position it reached real. Called from the view's own drag-ended callback,
/// from a new drag beginning while this one is still marked active, from the
/// app or the panel losing focus, from a slot or eyedropper write arriving, and
/// from teardown - so a begin always has a matching end, the undo group never
/// leaks, and no route out of a drag can lose the grade.
///
/// This is the ONLY place the puck writes, which is why every one of those
/// routes already comes through here rather than each having to remember.
///
/// The circles are unlatched whether or not a group was open: closing the group
/// and leaving a view following the cursor is the half-fix that lets a drag on
/// one ring keep writing the other's controls.
- (void)_endPuckDragReason:(NSString *)reason keepingRing:(NSUInteger)keepRing {
  for (NSUInteger i = 0; i < _circles.count; i++)
    if (i != keepRing)
      [_circles[i] cancelDrag];
  if (!_puckDragActive)
    return;
  _puckDragActive = NO;
  _dragStartValues = nil;
  KKLogInfo(@"[Surface] %@ puck %lu drag ending (%@)",
            MirageRingLogName([self _ringAtIndex:_puckDragRing]),
            (unsigned long)_puckDragIndex, reason);
  // The gesture's one write, INSIDE the group the begin opened - so the drag is
  // one step back, exactly as when every tick wrote. Nil means the puck was
  // pressed and released without moving: nothing to persist, and writing the
  // timeline it already holds would spend an undo entry and a render on a
  // gesture that changed nothing.
  KKTimeline *pending = _pendingPuckCommit;
  _pendingPuckCommit = nil;
  if (pending && self.onTimelineMutated)
    self.onTimelineMutated(pending);
  [self _endWriteGroup:reason];
  // Refreshed BEFORE the overrides are dropped, so the derive cannot read a
  // timeline the commit has not reached yet: the host write and the inspector's
  // own -applyTimeline: both run inline above, so by now they agree, but a puck
  // that springs to centre for one tick is the failure this ordering rules out
  // rather than relies on.
  // Only while there is still a panel to refresh: this runs from -dealloc too.
  if (_panel.isVisible)
    [self _refreshPuck];
  // Now the handover: the renderer reads the committed timeline from here on,
  // which holds the numbers the overrides were carrying. Nothing can draw
  // between the commit and this - both happen in the one event that ended the
  // drag - so the preview never shows a frame of the pre-drag grade.
  [self _clearLivePreviewValues];
  // The handover above returns the DRAG'S values to the timeline, which holds
  // them. It does not return the active key, which the timeline never held and
  // never will - so that one override is re-asserted rather than handed back.
  // Every route out of a drag comes through here, including the slot add, the
  // slot remove and the eyedropper's write, so this is the one re-push those
  // three need.
  [self _pushPreviewOverrides];
}

// Write the controls the puck's POSITION implies.
//
// Absolute, not a delta from where the drag started. A delta is what a mouse
// gives you and it is the wrong currency here: the response curve is nonlinear,
// so a control nudged by curve(offset) from its drag-start value does not sit
// where curve(position) says it should, and the derive - which reads position
// straight back out of the values - disagrees with the puck the moment the drag
// ends. That disagreement was the jump.
//
// So the puck means one thing: every mapped control equals its declared
// `default=` plus the curve at this position. Hand-tuned MAPPED controls
// therefore snap onto the mapping on first drag, which is the honest
// consequence of a puck that claims to show where they are. Unmapped controls
// are never touched.
/// The puck name at `index`, or nil when the index is stale (a recompile can
/// change the puck list under a drag).
- (NSString *)_puckNameAtIndex:(NSUInteger)index
                          ring:(NSUInteger)ringIndex
                        source:(NSString *)source {
  NSArray<NSDictionary<NSString *, NSString *> *> *pucks =
      [self _pucksForRing:ringIndex source:source];
  return index < pucks.count ? pucks[index][@"name"] : nil;
}

/// The response directions this puck's gesture actually has to satisfy.
///
/// Built here rather than at each call site because the apply and the derive
/// MUST stretch by the same set: they are inverses of each other, and a set
/// that differs between them is exactly the disagreement that makes a puck
/// spring away from where it was dropped. Same participation gate as both loops
/// - this puck's controls, currently visible, with a declared origin.
- (MirageSurfaceAxisSet)_axesForPuck:(NSString *)puckName
                           responses:
                               (NSDictionary<NSString *, NSValue *> *)responses
                            drivable:(NSSet<NSString *> *)drivable {
  MirageSurfaceAxisSet axes;
  memset(&axes, 0, sizeof(axes));
  for (NSString *key in responses) {
    if (![drivable containsObject:key])
      continue;
    MirageSurfaceResponse r;
    [responses[key] getValue:&r];
    if (!r.hasBase || !MirageResponseBelongsToPuck(r, puckName))
      continue;
    MirageSurfaceAxisSetAdd(&axes, r.x, r.y);
  }
  return axes;
}

- (void)_applyPuckTo:(NSPoint)position
                puck:(NSUInteger)puckIndex
                ring:(NSUInteger)ringIndex {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline || !_dragStartValues.count)
    return;
  NSString *source = [self _entrySource:timeline];
  NSDictionary<NSString *, NSValue *> *responses =
      [self _responsesForRing:ringIndex source:source];
  double frac = [self _editFraction];
  NSString *puckName = [self _puckNameAtIndex:puckIndex
                                         ring:ringIndex
                                       source:source];
  if (!puckName)
    return;
  BOOL polar = MirageSurfaceResponsesArePolar(responses);
  NSSet<NSString *> *drivable = [self _drivableKeysIn:timeline fraction:frac];
  // The rim has to mean full strength in every direction, so a cartesian
  // gesture is stretched into the puck's own control basis before anything
  // projects onto it - otherwise the directions between the axes are simply
  // unreachable. A polar surface is left alone: its radius is a control's own
  // deflection, not a direction to be normalised.
  if (!polar)
    MirageSurfaceDiscToAxes(&position.x, &position.y,
                            [self _axesForPuck:puckName
                                     responses:responses
                                      drivable:drivable]);
  double distance = MirageSurfaceDistance(position.x, position.y);
  double bearing = MirageSurfaceBearingDegrees(position.x, position.y);
  NSMutableArray<KKLane *> *lanes = [timeline.lanes mutableCopy];
  // Every lane this tick writes, for the preview. A puck moves the whole set of
  // controls its handle is mapped to, so the picture only tracks the drag if
  // all of them are pushed - one lane's worth would show a half-applied grade.
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *live =
      [NSMutableDictionary dictionary];
  BOOL changed = NO;
  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKLane *lane = lanes[i];
    NSString *bare = [self _bareKeyForLane:lane];
    NSValue *boxed = bare ? responses[bare] : nil;
    NSArray<NSNumber *> *start =
        lane.key.length ? _dragStartValues[lane.key] : nil;
    if (!boxed || !start.count)
      continue;
    if (![drivable containsObject:lane.key])
      continue; // gated off by a visibleby= rule, so not part of this gesture
    MirageSurfaceResponse r;
    [boxed getValue:&r];
    if (!MirageResponseBelongsToPuck(r, puckName))
      continue; // another puck's control: this gesture is not for it
    // No declared origin means there is no value a centred puck could stand
    // for, so the control stays out of the gesture rather than drifting from
    // wherever it happened to be. The derive skips it for the same reason.
    if (!r.hasBase)
      continue;
    double magnitude;
    double move;
    if (polar) {
      // Distance for `r:`, bearing for `a:`. A cartesian mapping on a polar
      // surface is skipped rather than blended in - see
      // MirageSurfaceResponsesArePolar.
      if (fabs(r.r) > 0.0) {
        magnitude = r.r;
        move = MirageSurfaceCurveDelta(r, r.base, distance, magnitude);
      } else if (fabs(r.a) > 0.0) {
        magnitude = r.a;
        move = MirageSurfaceAngleDelta(r, bearing);
      } else {
        continue;
      }
    } else {
      // Project the puck position onto this control's response direction, then
      // shape it through the curve so the rim reaches the control's real limit.
      magnitude = hypot(r.x, r.y);
      if (magnitude < 1e-12)
        continue;
      double u = (position.x * r.x + position.y * r.y) / magnitude;
      if (u > 1.0)
        u = 1.0;
      if (u < -1.0)
        u = -1.0;
      move = MirageSurfaceCurveDelta(r, r.base, u, magnitude);
    }
    NSInteger idx = KKLaneNearestKeyposeIndex(lane, frac);
    if (idx == NSNotFound)
      continue;
    NSMutableArray<NSNumber *> *values = [start mutableCopy];
    if (r.baseIsHue) {
      if (values.count < 3)
        continue;
      // Rotate the colour's hue, preserving its lightness and colourfulness:
      // the author asked for a hue response, not a different colour. Measured
      // and rewritten in OKLAB, the space the ring is painted in - through HSV
      // the swatch landed up to 30 degrees off the green the cursor was sitting
      // on.
      double L = 0.0, chroma = 0.0;
      MirageSurfaceOklabLCh(MAX(0.0, MIN(1.0, values[0].doubleValue)),
                            MAX(0.0, MIN(1.0, values[1].doubleValue)),
                            MAX(0.0, MIN(1.0, values[2].doubleValue)), &L,
                            &chroma, NULL);
      // On a wheel, the puck's BEARING IS THE HUE. Not an offset from the
      // control's default: the ring paints absolute hues, so adding the default
      // rotated the whole wheel by whatever colour that default happened to be
      // - point at green on a control defaulting to cyan and the swatch went
      // magenta. Every colour control was skewed, and the ones defaulting near
      // cyan read as exactly inverted, which is the "it moves the opposite way"
      // this fixes. Dragging at a colour now produces that colour on every
      // control.
      //
      // The `a:` magnitude has nothing to scale here and is ignored: a hue's
      // range is the whole circle by definition, so the wheel already is the
      // range. Lightness and chroma stay the swatch's own - the author asked
      // for a hue response, not a different colour.
      double hueDegrees =
          (polar && fabs(r.a) > 0.0) ? bearing : (r.base + move);
      double nr = 0.0, ng = 0.0, nb = 0.0;
      MirageSurfaceEncodedForOklabLCh(L, chroma, hueDegrees, &nr, &ng, &nb);
      values[0] = @(nr);
      values[1] = @(ng);
      values[2] = @(nb);
    } else {
      double next = r.base + move;
      // Clamp to the control's own declared bounds, so a gesture can never push
      // a control somewhere its slider could not go.
      NSArray<NSNumber *> *lo = lane.componentMin, *hi = lane.componentMax;
      if (lo.count)
        next = MAX(next, lo.firstObject.doubleValue);
      if (hi.count)
        next = MIN(next, hi.firstObject.doubleValue);
      values[0] = @(next);
    }
    lanes[i] = KKLaneBySettingValuesAtIndex(lane, idx, values);
    live[lane.key] = values;
    changed = YES;
  }
  if (!changed)
    return;
  KKTimeline *updated = [timeline copy];
  updated.lanes = lanes;
  // PREVIEW ONLY, per tick - the write waits for the mouse-up.
  //
  // The same bargain the constants sliders already strike, and for the same
  // reason: a tick's write is the whole timeline as JSON plus a render nudge,
  // through the host, on the main thread, and the picture the grade is judged
  // by is rendered in THIS process from these very numbers. Paying for the
  // round trip 60 times a second only bought a main viewer nobody is looking at
  // while the puck is under the cursor.
  //
  // Safe to defer because the apply is ABSOLUTE: every tick recomputes each
  // control from `_dragStartValues` and this position, never from the previous
  // tick's result, so the last tick's timeline says everything all of them
  // together would have. The base it recomputes from is stable for the same
  // reason - with no write per tick, nothing echoes back into the lanes view
  // mid-gesture, so `currentTimeline` stays the drag's starting point.
  //
  // The scope follows the preview for free: the sampler measures the preview's
  // own processed texture on its command buffer's completion handler, already
  // coalesced to kMinSampleInterval, so a fast drag cannot queue up a readback
  // per tick.
  _pendingPuckCommit = updated;
  _liveDragValues = live;
  [self _pushLivePreviewValues:live];
  [self _refreshReadout];
}

// Derive where the puck must be to explain the controls as they stand.
//
// This is the direction that makes the relationship bi-directional: nothing
// here writes anything, so hand-editing Threshold in the inspector moves the
// puck, and the puck can never claim a position the controls do not support.
- (void)_refreshPuck {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline || !_circles.count)
    return;
  NSString *source = [self _entrySource:timeline];
  [self _applySurfaceSpecIfChanged:source];
  // Resolved on every refresh rather than once at present: the directive is
  // normally typed with the panel already open, and a `visibleby=` choice can
  // be switched while it is.
  BOOL canPick = [self _hasDrivablePicksIn:timeline source:source];
  _pickColorButton.hidden = !canPick;
  if (!canPick && _pickingColor)
    [self _disarmPicking];
  // Present whenever the shader subscribes anything at all, but only ENABLED
  // when the handle you last touched has a subscriber of its own: a click that
  // would write nothing is a click the button has to refuse before you spend
  // it, and hiding it instead would make the button appear and vanish as you
  // move between handles on the same wheel.
  _pickSourceButton.hidden = !canPick;
  BOOL canPickActive =
      canPick && [self _picksForActivePuckIn:timeline source:source].count > 0;
  _pickSourceButton.enabled = canPickActive;
  if (!canPickActive && _pickingSource)
    [self _disarmPicking];
  [self _refreshHeaderButtonTitlesIn:timeline source:source];
  // Nothing measured, nothing to say. A sentence left over from a reference
  // that is gone - the shader changed its ring, the pick was dropped - would
  // describe a problem that may well have been fixed since.
  MirageSurfaceCircleView *hueCircle = [self _hueCircle];
  if (!hueCircle.castAvailable ||
      _pickDeclaration == MirageMemoryColorNeutral || _pickButton.hidden)
    [self _setDeclarationSentence:nil];
  double frac = [self _editFraction];
  NSSet<NSString *> *drivable = [self _drivableKeysIn:timeline fraction:frac];
  // Every ring is refreshed from the SAME tick and the same drivable set. Each
  // one is an independent gesture on its own controls, so nothing here is
  // shared between them but the frame they are both reading.
  for (NSUInteger i = 0; i < [self _ringCount] && i < _circles.count; i++) {
    MirageSurfaceCircleView *circle = _circles[i];
    NSDictionary<NSString *, NSValue *> *responses =
        [self _responsesForRing:i source:source];
    if (!responses.count) {
      circle.xAxisLive = NO;
      circle.yAxisLive = NO;
      circle.pucks = @[ [MirageSurfacePuck new] ];
      continue;
    }
    // Liveness is a property of the DECLARED mapping, not of which lanes
    // happened to resolve this tick. Deriving it from the samples meant one
    // unresolvable control made its whole axis read as dead, which is what
    // dimmed the Cool/Warm labels and crosshair even though the shader mapped
    // them.
    BOOL polar = MirageSurfaceResponsesArePolar(responses);
    BOOL xLive = polar, yLive = polar;
    for (NSValue *boxed in responses.allValues) {
      MirageSurfaceResponse r;
      [boxed getValue:&r];
      if (fabs(r.x) > 0.0)
        xLive = YES;
      if (fabs(r.y) > 0.0)
        yLive = YES;
    }
    circle.polarAxes = polar;
    NSMutableArray<MirageSurfacePuck *> *pucks = [NSMutableArray array];
    for (NSDictionary<NSString *, NSString *> *spec in
         [self _pucksForRing:i source:source]) {
      MirageSurfacePuck *puck = [MirageSurfacePuck new];
      puck.name = spec[@"name"] ?: @"";
      MirageApplyPuckGlyph(puck, spec);
      puck.trackRadius = (CGFloat)[spec[@"track"] doubleValue];
      puck.position = [self _derivePositionForPuck:puck.name
                                          timeline:timeline
                                         responses:responses
                                          drivable:drivable
                                             polar:polar
                                          fraction:frac];
      [pucks addObject:puck];
    }
    circle.xAxisLive = xLive;
    circle.yAxisLive = yLive;
    circle.pucks = pucks;
  }
  // The one place that catches everything else: this runs on every sampled
  // frame while the panel is up, and on the panel showing, on every timeline
  // apply, on -selectSlotInstance: (an undo putting a key back), and on both
  // ends of the add/remove pair - which is every remaining way the active
  // handle can change. Idempotent, so being the last statement of a method
  // called sixty times a second costs a dictionary and a redraw request.
  [self _pushPreviewOverrides];
  [self _refreshReadout];
}

// Derive one puck's position from ITS controls alone.
//
// Split out per puck rather than fitting everything at once: two pucks are two
// independent gestures that happen to share a circle, so mixing their controls
// into one fit would put both of them at the average of the corrections.
- (NSPoint)_derivePositionForPuck:(NSString *)puckName
                         timeline:(KKTimeline *)timeline
                        responses:
                            (NSDictionary<NSString *, NSValue *> *)responses
                         drivable:(NSSet<NSString *> *)drivable
                            polar:(BOOL)polar
                         fraction:(double)frac {
  NSMutableData *samples = [NSMutableData
      dataWithLength:sizeof(MirageSurfaceSample) * responses.count];
  MirageSurfaceSample *buf = samples.mutableBytes;
  int n = 0;
  MirageSurfacePolarFit fit = {0.0, 0, 0.0, 0.0, 0};
  for (KKLane *lane in timeline.lanes) {
    NSString *bare = [self _bareKeyForLane:lane];
    NSValue *boxed = bare ? responses[bare] : nil;
    if (!boxed)
      continue;
    // Same gate as the write side, or the puck would derive from controls the
    // gesture cannot move - it would sit somewhere the visible pair never put
    // it and snap the moment you touched it.
    if (![drivable containsObject:lane.key])
      continue;
    MirageSurfaceResponse r;
    [boxed getValue:&r];
    if (!MirageResponseBelongsToPuck(r, puckName))
      continue;
    NSArray<NSNumber *> *values = [self _valuesForLane:lane fraction:frac];
    if (!values.count)
      continue;
    // The base is the control's own starting value, which is what a zero puck
    // means. A control with no stored base contributes nothing rather than
    // pretending its current value is the origin.
    if (!r.hasBase)
      continue; // no declared origin, so a zero puck would be meaningless
    buf[n].rx = r.x;
    buf[n].ry = r.y;
    double delta;
    if (r.baseIsHue) {
      // A colour lane's value is rgba, and its response is a hue rotation, so
      // the delta is an ANGLE - measured the short way round, or a hue just
      // past the wrap point would throw the fit to the far side of the circle.
      if (values.count < 3)
        continue;
      // Oklab, the same measurement the apply side writes with, or the puck
      // would derive to a bearing the swatch is not actually sitting at.
      double hue = -1.0;
      MirageSurfaceOklabLCh(MAX(0.0, MIN(1.0, values[0].doubleValue)),
                            MAX(0.0, MIN(1.0, values[1].doubleValue)),
                            MAX(0.0, MIN(1.0, values[2].doubleValue)), NULL,
                            NULL, &hue);
      if (hue < 0.0)
        continue; // desaturated: a rotation would be unobservable
      if (polar && fabs(r.a) > 0.0) {
        // The apply side puts the hue AT the bearing, so the derive reads it
        // back the same way: the colour's own hue is the bearing, with no
        // default subtracted out. Wrapped to -180..180 because a bearing is a
        // direction.
        MirageSurfacePolarAddAngle(&fit, fmod(hue + 540.0, 360.0) - 180.0);
        continue;
      }
      delta = MirageSurfaceHueDelta(r.base, hue);
    } else {
      delta = values.firstObject.doubleValue - r.base;
    }
    if (polar) {
      // Distance and bearing are observed separately, then recombined: there is
      // no linear system to solve, because a radial control says nothing about
      // the angle and an angular one says nothing about the distance.
      if (fabs(r.r) > 0.0)
        MirageSurfacePolarAddRadius(
            &fit, MirageSurfaceCurveDeflection(r, r.base, delta, r.r));
      else if (fabs(r.a) > 0.0)
        MirageSurfacePolarAddAngle(&fit, MirageSurfaceAngleForDelta(r, delta));
      continue;
    }
    // Feed the fit a DEFLECTION, not a raw delta: the response curve is cubic,
    // so a linear fit on raw deltas would put the puck in the wrong place
    // everywhere except dead centre and the rim.
    double magnitude = hypot(r.x, r.y);
    buf[n].delta = MirageSurfaceCurveDeflection(r, r.base, delta, magnitude);
    // The fit's rows are already normalised by magnitude, so the observation
    // has to be in the same currency - deflection is, by construction.
    buf[n].delta *= magnitude;
    n++;
  }
  double px = 0.0, py = 0.0;
  if (polar) {
    MirageSurfacePolarResolve(fit, &px, &py);
  } else {
    MirageSurfaceDerivePuck(buf, n, &px, &py);
    // The fit answers in the CONTROL BASIS the apply side stretched into, and
    // the circle draws in the disc. Squeezed back through the same axes, so a
    // control pair sitting at both extremes derives to the rim rather than off
    // the edge of the wheel - and so the puck lands exactly where the drag put
    // it.
    MirageSurfaceAxesToDisc(&px, &py,
                            [self _axesForPuck:puckName
                                     responses:responses
                                      drivable:drivable]);
  }
  return NSMakePoint(px, py);
}

@end
