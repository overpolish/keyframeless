/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageColorPanelController.h"

#import <KeyframelessKit/KKFloatingPanel.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKPaddedScrollView.h>
#import <KeyframelessKit/KKPluginInstanceState.h>
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <QuartzCore/QuartzCore.h>

#import "Constants.h" // MirageCustomDefaultShaderSource
#import "MirageColorPanelController_Internal.h"
#import "MirageColorSurfaceProps.h"
#import "MirageLocalized.h"
#import "MirageRack.h" // entry ids, lane-key scope, scoped `#slots` groups
#import "MirageScopeSampler.h"
#import "MirageSurfaceCircleView.h"
#import "MirageSurfaceResponse.h"
#import "Plugin_Private.h" // +shaderSourceFromTimeline:

static const NSTimeInterval kShowRetryDelay = 0.1;

/// Floor between measurements. The mini viewer can render faster than a blit +
/// readback is worth doing, so frames are coalesced to this rate - fast enough
/// to read as live under the cursor, cheap enough to ignore.
static const NSTimeInterval kMinSampleInterval = 0.05;
static const NSUInteger kToneBinCount = 96;

/// The luminance span the ring's distribution covers, in stops around middle
/// grey. Wider below than above: shadows carry more of the interesting range.
static const double kRingMinStop = -7.0;
static const double kRingMaxStop = 5.0;

/// Primary editors are themselves KKFloatingPanel children of the stable
/// inspector/anchor window. The Color surface must be their SIBLING, not their
/// child: siblings retain the same above-FCP ordering, while dragging one does
/// not translate the other.
static NSWindow *MirageColorPanelHostWindow(NSWindow *editorWindow) {
  return editorWindow.parentWindow ?: editorWindow;
}

@implementation MirageColorPanelController

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView
                       apiManager:(id)apiManager {
  if ((self = [super init])) {
    _lanesView = lanesView;
    _apiManager = apiManager;
    // The persisted rack selection is seeded into the per-instance state
    // before the inspector is constructed. Start on that same entry: the
    // subclass's first -applyTimeline: runs from super-init, before this
    // controller exists, so waiting for that push left the first editor open
    // resolving the sentinel shader. A second open happened to work only
    // because the rack refresh had corrected the controller by then.
    _selectedRackEntryID = [MirageRackEntryIDOrSentinel(
        KKInstanceStateForAPI(apiManager).selectedRackEntryID) copy];
    _wellRowMask = -1;
    _userVisible = YES;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self
           selector:@selector(_popoverDidOpen:)
               name:KKStaticValuesPopoverDidOpenNotification
             object:lanesView];
    [nc addObserver:self
           selector:@selector(_popoverDidClose:)
               name:KKStaticValuesPopoverDidCloseNotification
             object:lanesView];
    // Focus leaving the panel is the user's own repro for the crash: drag a
    // puck, click into another app, come back and drag again. The mouse-up went
    // to that other app, so neither the view's monitors nor mouseUp ever closed
    // the undo group, and the next drag opened a second group inside it.
    [nc addObserver:self
           selector:@selector(_focusLeftPanel:)
               name:NSApplicationDidResignActiveNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(_windowResignedKey:)
               name:NSWindowDidResignKeyNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(_mainViewerPickRequested:)
               name:kMirageViewerPickDidRequestNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(_oscCanvasAvailabilityChanged:)
               name:kMirageOSCPositionNotification
             object:nil];
  }
  return self;
}

- (void)invalidate {
  [self _endPuckDragReason:@"invalidate"];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self _stopSampling];
  _lanesView.editorMiniViewerFramesRequired = NO;
  [_panel hidePanel];
}

- (void)dealloc {
  [self _endPuckDragReason:@"dealloc"];
  [self _disarmPicking];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  _measuredMini.onProcessedFrameReady = nil;
}

// Whether the matte is showing. Owned by the compare row on the preview, which
// is where the switch lives now - this is the panel's copy, and it exists only
// so the one push that asserts the preview's overrides can carry both it and
// the active key the pucks decide.
- (BOOL)showSelectionActive {
  return _showSelectionActive;
}

- (void)setShowSelectionActive:(BOOL)showSelectionActive {
  if (_showSelectionActive == showSelectionActive)
    return;
  _showSelectionActive = showSelectionActive;
  [self _pushPreviewOverrides];
}

- (void)reassertPreviewOverrides {
  [self _pushPreviewOverrides];
}

// A gesture that owns the keyboard is mid-flight: a bare-letter shortcut taken
// now would write inside the open undo group. Asked by the compare row, which
// has no other way to know - and only ever true while this panel is being
// dragged in.
- (BOOL)gestureInFlight {
  return _puckDragActive || _writeGroupOpen;
}

- (void)setSelectedRackEntryID:(NSString *)entryID {
  NSString *next = MirageRackEntryIDOrSentinel(entryID);
  if ([next isEqualToString:MirageRackEntryIDOrSentinel(_selectedRackEntryID)])
    return;
  // A drag belongs to the entry it started on. Ending it here rather than
  // letting it land on the new entry's lanes is the same rule the popover
  // close applies.
  [self _endPuckDragReason:@"the selected shader changed"];
  // Preview overrides are keyed only by the author-facing control label. If
  // the old shader had a selection switch and the new one does not, merely
  // pushing the new shader's (empty) set cannot retract the old value: it
  // would keep forcing the upstream shader to render its matte. Selection is
  // a hard ownership boundary, so drop the old entry's overrides first.
  [self _clearLivePreviewValues];
  _selectedRackEntryID = [next copy];
  // Force the spec rebuild: the ring set is cached against the SOURCE it was
  // built from, and two entries running the same template have the same source
  // while meaning different lanes.
  _lastSpecSource = nil;
  // Through the setter, so an entry with no `#color-surface` hides the panel
  // and one that has it shows it - the same two branches a recompile takes.
  self.surfaceEnabled = [self _resolveSurfaceEnabledFromLanes];
  if (_surfaceEnabled && _panel.isVisible) {
    [self _resolveRingsFromLanes];
    [self _refreshPuck];
  }
  [self _pushPreviewOverrides];
}

- (void)setSurfaceEnabled:(BOOL)surfaceEnabled {
  if (_surfaceEnabled == surfaceEnabled) {
    // Timeline/application order is not guaranteed on a fresh apply: the
    // editor can open while the outgoing shader is still current, then the new
    // grading timeline arrives with the availability bit already YES. Treat an
    // idempotent YES as a chance to fulfil a missing visible panel rather than
    // requiring the whole editor to be closed and reopened.
    if (surfaceEnabled && !_panel.isVisible)
      [self _showIfPopoverOpen];
    return;
  }
  _surfaceEnabled = surfaceEnabled;
  if (self.onSurfaceAvailabilityChanged)
    self.onSurfaceAvailabilityChanged(surfaceEnabled);
  // A recompile that adds or drops the directive must take effect NOW. The
  // directive is normally typed with the code popover already open, so waiting
  // for the next popover-open notification meant closing and reopening to see
  // the panel at all - and dropping it left a stale panel on screen.
  if (surfaceEnabled) {
    [self _showIfPopoverOpen];
  } else {
    [self _endPuckDragReason:@"panel hidden"];
    [self _stopSampling];
    _lanesView.editorMiniViewerFramesRequired = NO;
    [_panel hidePanel];
  }
}

- (void)setUserVisible:(BOOL)userVisible {
  if (_userVisible == userVisible)
    return;
  _userVisible = userVisible;
  if (!userVisible) {
    [self _endPuckDragReason:@"panel toggled off"];
    [self _stopSampling];
    _lanesView.editorMiniViewerFramesRequired = NO;
    [_panel hidePanel];
  } else {
    [self _showIfPopoverOpen];
  }
}

- (NSString *)_entrySource:(KKTimeline *)timeline {
  if (!timeline)
    return MirageCustomDefaultShaderSource();
  return [MiragePlugin shaderSourceFromTimeline:timeline
                                   forRackEntry:_selectedRackEntryID];
}

- (NSString *)_bareKeyForLane:(KKLane *)lane {
  if (!lane.key.length)
    return nil;
  NSString *owner = nil, *bare = nil;
  MirageRackParseLaneKey(lane.key, &owner, &bare);
  return
      [owner isEqualToString:MirageRackEntryIDOrSentinel(_selectedRackEntryID)]
          ? bare
          : nil;
}

- (NSString *)_scopedSlotGroup:(NSString *)groupName {
  return MirageRackScopedSlotGroupName(
      MirageRackEntryIDOrSentinel(_selectedRackEntryID), groupName);
}

// The live timeline with the selected entry's `#slots` registry presented under
// BARE group names.
//
// The grammar expansions (MirageSlotSurface.h) ask the registry "how many
// instances of the group this source declares", and the source declares
// `Colours` - the scope is the rack's, not the shader's. Re-keying the registry
// once here means those helpers keep taking one timeline and answering in bare
// keys, which is exactly the half of the boundary -_bareKeyForLane: works in.
// Lanes are deliberately not carried: nothing downstream of this reads them.
//
// The sentinel's registry is already bare, so it is handed back untouched -
// a project that has never been racked does not allocate a thing.
- (KKTimeline *)_entryScopedRegistry {
  KKTimeline *timeline = _lanesView.currentTimeline;
  NSString *entryID = MirageRackEntryIDOrSentinel(_selectedRackEntryID);
  if (!timeline || [entryID isEqualToString:kMirageRackSentinelEntryID])
    return timeline;
  NSMutableDictionary<NSString *, NSArray<NSString *> *> *bare =
      [NSMutableDictionary dictionary];
  [timeline.slotGroups
      enumerateKeysAndObjectsUsingBlock:^(
          NSString *group, NSArray<NSString *> *ids, BOOL *stop) {
        if ([group isEqualToString:kMirageRackGroupName])
          return; // the rack's own registry is not one of the shader's groups
        NSString *owner = nil, *bareName = nil;
        MirageRackParseLaneKey(group, &owner, &bareName);
        if ([owner isEqualToString:entryID] && bareName.length)
          bare[bareName] = ids;
      }];
  KKTimeline *view = [KKTimeline timeline];
  view.slotGroups = bare;
  return view;
}

// Read the opt-in straight from the lanes view's current timeline.
//
// The pushed -setSurfaceEnabled: cannot be relied on at popover-open time:
// -applyTimeline: has not necessarily run yet, and on a cold boot it has not
// run at ALL by the time the first popover opens, so the flag was still NO and
// the panel never appeared. The lanes view always has a timeline by then - it
// is drawing the very lane whose popover this is - so resolving here needs no
// ordering assumption.
- (BOOL)_resolveSurfaceEnabledFromLanes {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline)
    return _surfaceEnabled; // nothing better to go on
  NSString *source = [self _entrySource:timeline];
  MirageColorSurfaceSpace space = MirageColorSurfaceSpaceInvalid;
  MirageColorSurfaceError error = MirageColorSurfaceErrorNone;
  return MirageColorSurfaceForSource(source, &space, &error) &&
         error == MirageColorSurfaceErrorNone;
}

// The open popover is tracked regardless of the opt-in, so this can present
// without one having to reopen.
- (void)_showIfPopoverOpen {
  [self _showIfPopoverOpenAttempt:0];
}

// Waits for the popover window to actually BE on screen, retrying rather than
// checking once. The first time a popover opens its views are built from
// scratch, so it is routinely still invisible when the open notification fires
// - checking `isVisible` once just returned, and the panel then never appeared
// until something else re-triggered it (toggling the directive off and on).
// MirageBrowserController retries for exactly the same reason. Bounded, so a
// popover that never appears stops the chain instead of polling forever.
- (void)_showIfPopoverOpenAttempt:(NSInteger)attempt {
  static const NSInteger kMaxAttempts = 100; // ~10s at kShowRetryDelay
  if (!self.surfaceEnabled || !self.userVisible)
    return;
  // The window may not exist yet (cold boot), in which case the popover's
  // content view is what eventually acquires one.
  if (!_parentWindow)
    _parentWindow = MirageColorPanelHostWindow(_popoverContentView.window);
  if (!_parentWindow || !_parentWindow.isVisible) {
    if (!_popoverContentView || attempt + 1 >= kMaxAttempts) {
      if (_popoverContentView)
        KKLogWarn(@"[Color] popover never became visible, no panel");
      return;
    }
    NSView *pending = _popoverContentView;
    __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kShowRetryDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     __strong typeof(weak) s = weak;
                     // A different popover took over, or this one closed.
                     if (!s || s->_popoverContentView != pending)
                       return;
                     [s _showIfPopoverOpenAttempt:attempt + 1];
                   });
    return;
  }
  NSRect card = _openCard;
  NSView *cv = _popoverContentView;
  if (cv.window) {
    NSRect live = [cv.window convertRectToScreen:[cv convertRect:cv.bounds
                                                          toView:nil]];
    if (!NSIsEmptyRect(live))
      card = live;
  }
  if (NSIsEmptyRect(card))
    return;
  [self _resolveRingsFromLanes];
  KKFloatingPanel *panel = [self _ensurePanel];
  panel.appearance = _parentWindow.appearance;
  [panel showBesideCard:card ofWindow:_parentWindow];
  // A vectorscope is a real pixel consumer. Compact mode normally tears down
  // the hidden mini's frame pipeline; opt it back in only while this companion
  // panel is actually visible, then release it again on every hide/close path.
  _lanesView.editorMiniViewerFramesRequired = YES;
  [self _refreshPuck];
  [self _startSampling];
}

// Which mapped controls the puck may touch: the ones the inspector is currently
// showing.
//
// A `visibleby=` gate is what lets one puck serve a three-way tool - Shadows,
// Midtones and Highlights each own their pair of balance controls, and a
// #choice picks which pair is on screen. Without this the puck would drive all
// three at once and the derive would average them, so the wheel would show a
// position none of the three ranges actually holds.
//
// Resolved at the open fraction rather than from first keyposes, since the
// choice itself can be animated.
- (NSSet<NSString *> *)_drivableKeysIn:(KKTimeline *)timeline
                              fraction:(double)frac {
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *values =
      [NSMutableDictionary dictionary];
  for (KKLane *lane in timeline.lanes) {
    if (!lane.key.length)
      continue;
    NSArray<NSNumber *> *at = KKTimelineLaneValueAtFraction(lane, frac);
    if (at.count)
      values[lane.key] = at;
  }
  return KKConditionalVisibleLaneKeys(timeline.lanes, values);
}

/// The clip fraction every read and write here is measured at.
///
/// Asked of the lanes view each time rather than captured when the popover
/// opened. Both things that set it move without the popover reopening: keypose
/// navigation walks between keyposes in place, and the playhead moves whenever
/// the user scrubs. Holding the open-time value meant an animated control was
/// read at a time the user had long since left - the ring's scope tracked the
/// playhead (it measures the rendered frame) while the puck sat still on the
/// opening frame's values, so the two disagreed about the same moment.
- (double)_editFraction {
  KKTimelineLanesView *lanes = _lanesView;
  double live = lanes ? lanes.staticPopoverEditFraction : _openFraction;
  return MAX(0.0, MIN(1.0, live));
}

/// This lane's current values, preferring the mini-viewer renderer's reading.
///
/// A constants slider drag makes NO FxPlug write until mouse-up, on purpose:
/// one undo entry per drag rather than one per tick. So the committed timeline
/// the derive reads does not move while the slider does, and the puck used to
/// sit still until release. The renderer holds the in-flight value as a live
/// override for exactly that window - it is how the preview updates live - and
/// its accessor falls back to the timeline when there is no override, so asking
/// it is right in both states.
///
/// Only asked when the renderer is looking at the SAME fraction as the panel:
/// the override is fraction-keyed, and a renderer parked on another keypose
/// would answer about a moment this puck is not showing.
- (NSArray<NSNumber *> *)_valuesForLane:(KKLane *)lane fraction:(double)frac {
  // An open puck drag is the panel's own in-flight value, and it wins outright.
  // It writes once, on mouse-up, so the committed timeline holds the position
  // the drag STARTED from for the whole gesture - reading it here would freeze
  // the readout and spring the derived puck back to where it was grabbed. Not
  // routed through the renderer's override for this: that one is fraction-keyed
  // against the RENDERER's edit fraction, and this panel asks at its own.
  NSArray<NSNumber *> *dragging =
      lane.key.length ? _liveDragValues[lane.key] : nil;
  if (dragging.count)
    return dragging;
  KKMiniViewerRenderer *mini =
      (KKMiniViewerRenderer *)_lanesView.miniViewerDelegate;
  if (lane.key.length && [mini isKindOfClass:[KKMiniViewerRenderer class]] &&
      fabs(mini.editFraction - frac) < 1e-4) {
    NSArray<NSNumber *> *values = [mini valuesForLabel:lane.key];
    if (values.count)
      return values;
  }
  return KKTimelineLaneValueAtFraction(lane, frac);
}

- (void)_popoverDidOpen:(NSNotification *)note {
  // The surface measures colour, so it belongs beside the popovers where values
  // are edited. The manage / filter / osc / appliesTo popovers are structural,
  // and the browser skips them for the same reason.
  NSString *kind = note.userInfo[@"kind"];
  if ([kind isEqualToString:@"manage"] || [kind isEqualToString:@"filter"] ||
      [kind isEqualToString:@"osc"] || [kind isEqualToString:@"appliesTo"]) {
    return;
  }
  NSWindow *popoverWindow = note.userInfo[@"window"];
  if (![popoverWindow isKindOfClass:[NSWindow class]])
    popoverWindow = nil;
  _popoverContentView = note.userInfo[@"contentView"];
  // A cold boot can deliver this before the popover has a window at all. Keep
  // the content view and resolve the window from it, rather than treating a
  // window-less open as "no popover" - that was why the first popover after
  // launch never got its panel.
  if (!popoverWindow && !_popoverContentView) {
    return;
  }
  NSValue *cardVal = note.userInfo[@"contentRect"];
  // The editor panel and Color surface are peers under the same stable host.
  // Attaching Color directly to the editor made it follow every editor drag;
  // making it top-level fixed that movement but lost the ordering that keeps
  // plugin panels above Final Cut.
  _parentWindow = MirageColorPanelHostWindow(popoverWindow);
  _openCard = cardVal ? cardVal.rectValue
                      : (popoverWindow ? popoverWindow.frame : NSZeroRect);
  _openFraction = [note.userInfo[@"fraction"] doubleValue];
  // Resolved and shown HERE, in the notification turn.
  //
  // This was deferred a tick to keep the directive parse and the panel build
  // off the turn that puts the popover up, guarded on `_popoverContentView`
  // still being the view captured above. The guard is unsound: the popover
  // INSTANCE is reused across opens, so a same-anchor swap runs the outgoing
  // popover's close callback around the incoming open - and -_popoverDidClose:
  // nils `_popoverContentView` for whichever popover it is told about. One late
  // close inside that one tick cancelled the show, and the panel silently never
  // appeared again.
  //
  // Cheap enough to owe nothing to the defer: the directive parse is a
  // fast-rejected regex, the ring spec is cached against the source it was
  // built from, and -_showIfPopoverOpenAttempt: still waits (off this turn) for
  // the popover window to be visible before anything is put on screen. The
  // first scope measurement, which is the expensive half, stays deferred.
  // Resolve rather than trust the pushed flag: this is the path that runs
  // before -applyTimeline: ever has.
  _surfaceEnabled = [self _resolveSurfaceEnabledFromLanes];
  if (self.onSurfaceAvailabilityChanged)
    self.onSurfaceAvailabilityChanged(_surfaceEnabled);
  [self _showIfPopoverOpen];
}

/// The part of the frame the preview is actually showing, in 0..1 bottom-left
/// frame coordinates.
///
/// Derived rather than asked for: the mini already publishes where it draws the
/// image (`contentRectInViewPoints`, which honours zoom and pan), and what is
/// on screen is that rect clipped to the view's own bounds. Zoomed out, the
/// content sits entirely inside the bounds and this is the whole frame, which
/// is what keeps an untouched preview drawing exactly one cloud.
///
/// The geometry itself lives in MirageScopeVisibleUVRect, which takes the two
/// rects rather than the view: a preview that has not been laid out is the case
/// that has to answer "whole frame", and it is not reachable from a test with a
/// real mini viewer in it.
static NSRect MirageVisibleUVRectOfMini(KKMiniViewerView *mini) {
  if (!mini)
    return NSMakeRect(0.0, 0.0, 1.0, 1.0);
  return MirageScopeVisibleUVRect([mini contentRectInViewPoints], mini.bounds);
}

// Measure when the PREVIEW says it has a new frame, rather than on a timer.
//
// The timer version froze for the duration of a parameter drag and only caught
// up on mouse-up: an NSTimer in the default run-loop mode does not fire while
// the mouse is down. The mini viewer is already re-rendering live throughout
// the drag, so its own completion is both the correct trigger and free.
- (void)_startSampling {
  if (!_sampler)
    _sampler = [MirageScopeSampler new];
  KKMiniViewerView *mini = MirageFindMiniViewer(_popoverContentView);
  if (!mini)
    return;
  if (mini != _measuredMini) {
    // This reset also tears down the availability poll, so the poll MUST be
    // installed after it. Installing it before this line produced a timer that
    // was cancelled in the same call and made availability update only when a
    // puck happened to trigger an unrelated refresh.
    [self _stopSampling];
    _measuredMini = mini;
    __weak typeof(self) weak = self;
    mini.onProcessedFrameReady = ^{
      [weak _frameReady];
    };
    // The frame already on screen shouldn't wait for the next one - but it
    // shouldn't be measured in the turn that is still putting the panel up
    // either. Next tick: the popover gets the main thread back first.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong typeof(weakSelf) s = weakSelf;
      if (s && s->_measuredMini == mini)
        [s _sampleOnce];
    });
  }

  // The OSC-position notification catches the enable edge, but deselecting the
  // clip simply stops draw ticks: there is no "OSC disappeared" event. Match
  // the Help window's live guide gate with the same one-second freshness poll.
  if (!_presentationAvailabilityTimer) {
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    _presentationAvailabilityTimer = timer;
    __weak typeof(self) weakAvailability = self;
    dispatch_source_set_event_handler(timer, ^{
      [weakAvailability presentationContextDidChange];
    });
    dispatch_source_set_timer(
        timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
        NSEC_PER_SEC, (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_resume(timer);
  }
}

- (void)_stopSampling {
  [self _disarmPicking];
  if (_presentationAvailabilityTimer)
    dispatch_source_cancel(_presentationAvailabilityTimer);
  _presentationAvailabilityTimer = nil;
  _measuredMini.onProcessedFrameReady = nil;
  // The compare state - and the bypass a held button or key put on - belongs to
  // the row on the preview, which is torn down by the same popover close this
  // is. Nothing to release here.
  _measuredMini = nil;
  _samplePending = NO;
}

// Coalesce: the preview can present faster than a readback is worth doing, and
// a burst during a drag must not queue up one measurement per frame.
- (void)_frameReady {
  if (_samplePending)
    return;
  NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
  NSTimeInterval since = now - _lastSampleTime;
  if (since >= kMinSampleInterval) {
    [self _sampleOnce];
    return;
  }
  _samplePending = YES;
  __weak typeof(self) weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)((kMinSampleInterval - since) * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s->_samplePending = NO;
        [s _sampleOnce];
      });
}

- (void)_sampleOnce {
  if (!_sampler)
    _sampler = [MirageScopeSampler new];
  // Pushed here rather than at the menu, since the sampler is built lazily and
  // the declaration can be chosen before the first frame ever arrives.
  _sampler.pickDeclaration = _pickDeclaration;
  _lastSampleTime = NSDate.timeIntervalSinceReferenceDate;
  if (!_panel.isVisible) {
    [self _stopSampling];
    return;
  }
  // Before the frame guards, not after them. A slider drag moves the puck via
  // the renderer's live values, and that has to happen even on a tick where the
  // scope reading comes back empty or the texture is not ready - otherwise the
  // puck goes back to only moving on mouse-up whenever the frame says nothing.
  [self _refreshPuck];
  KKMiniViewerView *mini =
      _measuredMini ?: MirageFindMiniViewer(_popoverContentView);
  id<MTLTexture> graded = mini.processedTexture;
  if (!graded || !mini.device)
    return; // nothing rendered yet; the axis keeps its "waiting" state
  // Re-read every tick rather than watching for a zoom. The mini fires
  // onProcessedFrameReady on every DRAW - a pan or a wheel-zoom forces one - so
  // the scope already follows the framing, and `onViewTransformChanged` belongs
  // to the joyride guide, which would lose its "try zooming" step if this took
  // it.
  _sampler.visibleUVRect = MirageVisibleUVRectOfMini(mini);
  // Asked for, not waited on. The measurement is a GPU blit plus a walk over
  // tens of thousands of pixels, and it is driven by the preview's own frame
  // callback - done synchronously it took a slice of the main thread out of
  // every frame, right where the popover is trying to composite. The reading
  // comes back on the main thread a beat later and lands exactly as it did.
  __weak typeof(self) weak = self;
  [_sampler readTextureAsync:graded
                      device:mini.device
                    binCount:kToneBinCount
                     minStop:kRingMinStop
                     maxStop:kRingMaxStop
                  completion:^(MirageScopeReading *reading) {
                    [weak _applyScopeReading:reading];
                  }];
}

- (void)_applyScopeReading:(MirageScopeReading *)reading {
  if (!reading.sampleCount || !_panel.isVisible)
    return;
  if (_pendingColorPick && reading.probedRGB.count >= 3) {
    _pendingColorPick = NO;
    _sampler.probeUV = NSMakePoint(-1.0, -1.0);
    [self _schedulePickWrite:reading.probedRGB activePuckOnly:NO];
  }
  // The cast is a hue, so it goes to the wheel. With no wheel declared it goes
  // to the one circle there is, which is where it went before a second was
  // possible.
  MirageSurfaceCircleView *castCircle =
      [self _hueCircle] ?: _circles.firstObject;
  castCircle.chromaCast = reading.chromaCast;
  // The sampler already withdrew this when the reference patch left the zoomed
  // region, so the cross, the cloud, the readout and the declaration sentence
  // all describe the same pixels. Nothing here has to decide that a second
  // time.
  castCircle.castAvailable = reading.castAvailable;
  [self _setDeclarationSentence:(_pickDeclaration != MirageMemoryColorNeutral &&
                                 reading.castAvailable)
                                    ? MirageDeclarationSentence(
                                          _pickDeclaration, reading.chromaCast)
                                    : nil];
  // ONE measurement, handed to every circle: the chroma cloud and the luma
  // histogram both come out of the same frame, and each ring draws the one it
  // paints and ignores the other. Sampling per ring would read the same texture
  // twice to arrive at the same two numbers.
  for (NSUInteger i = 0; i < [self _ringCount] && i < _circles.count; i++) {
    [_circles[i] applyChromaCloud:reading.chromaBins
                           region:reading.chromaBinsVisible
                        angleBins:reading.chromaAngleBins
                       radiusBins:reading.chromaRadiusBins];
    [_circles[i] applyToneCloud:reading.toneBins
                         region:reading.toneBinsVisible];
  }
}

// Called on every timeline apply, so a recompile refreshes the ring, the labels
// and the puck even when the opt-in flag itself did not change.
- (void)timelineDidChange {
  // A cold-open editor can precede the first fully-applied timeline. Recheck
  // the source here so that arrival can reveal both the header toggle and the
  // companion panel in place, without requiring the editor to be reopened.
  self.surfaceEnabled = [self _resolveSurfaceEnabledFromLanes];
  if (_panel.isVisible)
    [self _refreshPuck];
}

- (void)presentationContextDidChange {
  if (_panel.isVisible)
    [self _refreshPuck];
}

- (void)_oscCanvasAvailabilityChanged:(NSNotification *)note {
  [self presentationContextDidChange];
}

// The selection move the add and remove buttons make, asked for from outside:
// an undo has put an instance back, and the panel should be talking about it
// exactly as it would have been if the user had never removed it.
//
// The source is re-read here rather than passed in - the caller is the
// inspector, which knows the timeline and has no business knowing that the
// selection is keyed off the shader's puck declarations. The refresh afterwards
// carries the new selection into the readout and into the remove/eyedropper
// buttons, all of which are statements about the ACTIVE handle.
- (void)selectSlotInstance:(NSString *)instanceID {
  if (!instanceID.length)
    return;
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline)
    return;
  [self _selectSlotPuckForInstance:instanceID
                            source:[self _entrySource:timeline]];
  [self _refreshPuck];
}

- (void)_popoverDidClose:(NSNotification *)note {
  NSView *closingContent = note.userInfo[@"contentView"];
  if (closingContent && _popoverContentView &&
      closingContent != _popoverContentView)
    return;
  [self _endPuckDragReason:@"the popover closed"];
  [self _stopSampling];
  _lanesView.editorMiniViewerFramesRequired = NO;
  // A declaration is a statement about the shot being graded, so it does not
  // outlive the popover it was made in. The matte does not either, and it is
  // reset through the SETTER by the row that owns it - so the reset carries a
  // push that takes the override back out of the preview, whichever of the two
  // observers the close reaches first.
  _pickDeclaration = MirageMemoryColorNeutral;
  [self _setDeclarationSentence:nil];
  _parentWindow = nil;
  _popoverContentView = nil;
  _openCard = NSZeroRect;
  [_panel hidePanel];
}

@end
