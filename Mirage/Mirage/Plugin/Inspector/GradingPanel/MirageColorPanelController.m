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

@implementation MirageColorPanelController

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView {
  if ((self = [super init])) {
    _lanesView = lanesView;
    _wellRowMask = -1;
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
  }
  return self;
}

- (void)invalidate {
  [self _endPuckDragReason:@"invalidate"];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self _stopSampling];
  [_panel hidePanel];
}

- (void)dealloc {
  [self _endPuckDragReason:@"dealloc"];
  [self _disarmPicking];
  [self _dropShortcutMonitors];
  [NSNotificationCenter.defaultCenter removeObserver:self];
  _measuredMini.onProcessedFrameReady = nil;
  _measuredMini.onCompareStateChanged = nil;
}

- (void)setSurfaceEnabled:(BOOL)surfaceEnabled {
  if (_surfaceEnabled == surfaceEnabled)
    return;
  _surfaceEnabled = surfaceEnabled;
  // A recompile that adds or drops the directive must take effect NOW. The
  // directive is normally typed with the code popover already open, so waiting
  // for the next popover-open notification meant closing and reopening to see
  // the panel at all - and dropping it left a stale panel on screen.
  if (surfaceEnabled) {
    [self _showIfPopoverOpen];
  } else {
    [self _endPuckDragReason:@"panel hidden"];
    [self _stopSampling];
    [_panel hidePanel];
  }
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
  NSString *source = [MiragePlugin shaderSourceFromTimeline:timeline];
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
  if (!self.surfaceEnabled)
    return;
  // The window may not exist yet (cold boot), in which case the popover's
  // content view is what eventually acquires one.
  if (!_parentWindow)
    _parentWindow = _popoverContentView.window;
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
  [self _refreshPuck];
  [self _startSampling];
  // After the sampling starts, not before: a fresh preview makes
  // -_startSampling tear the previous one down, and the shortcuts installed
  // ahead of it would go with it.
  [self _installShortcutMonitors];
}

// Split the preview: graded left of the divider, ungraded right of it.
//
// Handed straight to the mini viewer, which owns the state for the length of
// the session and nothing longer. It is not a lane, not a parameter and not
// part of the UI state blob on purpose - an honoured FxPlug write is one undo
// entry, so a divider the user drags would bury the grade they actually want to
// step back.
- (void)_toggleCompareSplit:(id)sender {
  KKMiniViewerView *mini = _measuredMini;
  if (!mini.compareAvailable)
    return;
  mini.compareSplitEnabled = !mini.compareSplitEnabled;
  [self _refreshCompareButtons];
}

- (void)_setCompareBypass:(BOOL)held {
  KKMiniViewerView *mini = _measuredMini;
  if (!mini.compareAvailable)
    return;
  mini.compareBypassing = held;
  [self _refreshCompareButtons];
}

// Read the tint back off the preview rather than keeping a flag here: the mini
// viewer is rebuilt with the popover, so a remembered toggle would light a
// button for a split that no longer exists. A generator has no ungraded frame
// at all, so both buttons go away rather than sitting there doing nothing.
- (void)_refreshCompareButtons {
  KKMiniViewerView *mini = _measuredMini;
  BOOL available = mini.compareAvailable;
  _splitButton.hidden = !available;
  _beforeButton.hidden = !available;
  _splitButton.contentTintColor = (available && mini.compareSplitEnabled)
                                      ? NSColor.accentMatchingHost
                                      : NSColor.secondaryLabelColor;
  _beforeButton.contentTintColor = (available && mini.compareBypassing)
                                       ? NSColor.accentMatchingHost
                                       : NSColor.secondaryLabelColor;
}

// The three compare keys, live for as long as the panel is on screen.
//
// ONE monitor, and a LOCAL one, because a shortcut that fires without also
// being consumed is worse than no shortcut: M flipped the matte AND reached
// FCP, which took it as "add marker" - and B and S went the same way to the
// blade and the host's own bindings. Only a local monitor can return nil, and
// only a local monitor sees a key at all when this process holds the keyboard.
//
// What puts it there is the inspector's -miniGrabsKeyFocusOnClick, the same
// opt-in Canvas makes so a bare Delete removes a layer rather than the effect:
// a click in the preview makes the popover key, and from then on FCP delivers
// the letter here first. That is the house answer to this exact problem and it
// is reused rather than re-invented - see KKMiniViewerView's own note on why a
// GLOBAL monitor can only watch a key go past on its way to the host.
//
// So there is no global monitor here any more. It was the observe-only half of
// a pair, it could never swallow anything, and keeping it would have meant two
// paths for one key - which is also what the timestamp de-duplication in the
// handler existed to paper over.
//
// Installed once the panel is actually showing and dropped the moment it is
// not, so a letter typed anywhere in FCP with no Color panel up is nobody's
// business but FCP's.
- (void)_installShortcutMonitors {
  if (_shortcutMonitor)
    return;
  __weak typeof(self) weak = self;
  NSEventMask keys = NSEventMaskKeyDown | NSEventMaskKeyUp;
  _shortcutMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:keys
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(weak) s = weak;
                                     if (s && [s _handleShortcutEvent:e])
                                       return nil; // ours: don't also type it
                                     return e;
                                   }];
}

- (void)_dropShortcutMonitors {
  MirageDropMonitor(&_shortcutMonitor);
  // A bypass the keyboard is holding cannot survive the monitors that would
  // release it: the key-up would arrive with nothing listening and leave the
  // preview permanently ungraded.
  [self _releaseKeyBypass];
}

- (void)_releaseKeyBypass {
  if (!_bypassHeldByKey)
    return;
  _bypassHeldByKey = NO;
  [self _setCompareBypass:NO];
}

// One bare letter each: B holds the bypass the way the button does, S flips the
// split, M flips the shader's selection switch.
//
// Every gate here is about NOT taking a key that was meant for something else.
// The panel has to be on screen; a modifier means the user is reaching for a
// command, not a compare; a text object having focus means they are typing;
// and a latched drag or an open write group means a gesture is mid-flight, so a
// second write would land inside the first one's undo group. In each of those
// the event is returned untouched rather than consumed. Escape is not ours at
// all, so Set from clip still disarms on it exactly as before.
- (BOOL)_handleShortcutEvent:(NSEvent *)event {
  NSString *ch = event.charactersIgnoringModifiers.lowercaseString;
  if (event.type == NSEventTypeKeyUp) {
    // Nothing else here is press-and-hold, so a key-up is only ever the end of
    // one - and it is honoured whatever the gates say now, since what it ends
    // began when they all passed.
    if (!_bypassHeldByKey || ![ch isEqualToString:@"b"])
      return NO;
    [self _releaseKeyBypass];
    return YES;
  }
  if (!_panel.isVisible)
    return NO;
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
              NSEventModifierFlagOption | NSEventModifierFlagShift |
              NSEventModifierFlagFunction))
    return NO;
  if (MirageTextEditingInProgress())
    return NO;
  if (_puckDragActive || _writeGroupOpen)
    return NO;
  NSButton *button = nil;
  if ([ch isEqualToString:@"b"])
    button = _beforeButton;
  else if ([ch isEqualToString:@"s"])
    button = _splitButton;
  else if ([ch isEqualToString:@"m"])
    button = _selectionButton;
  // A key whose button this shader does not offer is not this panel's key.
  if (!button || button.hidden)
    return NO;
  // Held keys repeat. The press is consumed either way - it is ours - but only
  // the first one does anything, or a leaned-on S would strobe the preview.
  if (event.isARepeat)
    return YES;
  if (button == _beforeButton) {
    _bypassHeldByKey = YES;
    [self _setCompareBypass:YES];
  } else if (button == _splitButton) {
    [self _toggleCompareSplit:nil];
  } else {
    [self _toggleShowSelection:nil];
  }
  return YES;
}

// Whether this shader offers a selection switch at all. The DECLARATION alone,
// with no lane to look for: the control is panel-owned session state now, so
// there never is one.
- (BOOL)_declaresSelectionToggleIn:(NSString *)source {
  return MirageSurfaceSelectionToggleForSource(source).length > 0;
}

// Present only for a shader that declares the switch, and tinted from the
// PANEL'S OWN state.
//
// That state is an ivar and not a lane, which is the whole change: this button
// answers "what am I looking at", exactly as Before and Split do, and those
// were never parameters. As a parameter it spent an undo entry per press - so
// stepping back through a grade walked through every glance at the matte - and
// it persisted, so a project reopened later came up showing a grey diagnostic
// instead of the shot.
//
// Nothing to reconcile, either. There is no inspector checkbox and no keyframe
// for this any more, so the ivar cannot disagree with a second version of the
// truth the way a remembered flag beside a lane would have.
- (void)_refreshSelectionButtonIn:(KKTimeline *)timeline
                           source:(NSString *)source {
  _selectionButton.hidden = ![self _declaresSelectionToggleIn:source];
  if (_selectionButton.hidden)
    return;
  _selectionButton.contentTintColor = _showSelectionActive
                                          ? NSColor.accentMatchingHost
                                          : NSColor.secondaryLabelColor;
}

// Flip the switch: NO write, no write group, no undo entry, nothing persisted.
//
// Just the ivar and a push into the preview, which is the same shape the
// active-key feed has and the same shape Split has. The two pushes go through
// one re-assert so neither can be left behind by a path that clears overrides.
- (void)_toggleShowSelection:(id)sender {
  KKTimeline *timeline = _lanesView.currentTimeline;
  NSString *source =
      timeline ? [MiragePlugin shaderSourceFromTimeline:timeline] : @"";
  if (![self _declaresSelectionToggleIn:source])
    return;
  _showSelectionActive = !_showSelectionActive;
  [self _pushPreviewOverrides];
  [self _refreshSelectionButtonIn:timeline source:source];
}

/// YES when `responder` is a text object that would have taken the keystroke.
/// A field editor answers for whichever control it is currently serving, so
/// NSTextField, NSSearchField and the code editor are all one test.
static BOOL MirageRespondsAsEditor(NSResponder *responder) {
  return [responder isKindOfClass:[NSText class]] &&
         ((NSText *)responder).isEditable;
}

/// YES when something in this process is taking typed text.
///
/// The three shortcuts are BARE letters, so this is the whole reason they are
/// safe: the code editor, the shader browser's search field and every inspector
/// text field are one keystroke away from the panel, and a stray "s" splitting
/// the preview instead of landing in the source would be unforgivable.
///
/// The key window is asked first and taken as the answer when there is one. A
/// popover in the ViewBridge process routinely leaves an editable text view as
/// some other window's first responder long after that window stopped receiving
/// keys, so scanning every window unconditionally would disable the shortcuts
/// for the rest of the session.
static BOOL MirageTextEditingInProgress(void) {
  NSWindow *key = NSApp.keyWindow;
  if (key)
    return MirageRespondsAsEditor(key.firstResponder);
  for (NSWindow *window in NSApp.windows)
    if (window.isVisible && MirageRespondsAsEditor(window.firstResponder))
      return YES;
  return NO;
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
      [kind isEqualToString:@"osc"] || [kind isEqualToString:@"appliesTo"])
    return;
  NSWindow *popoverWindow = note.userInfo[@"window"];
  if (![popoverWindow isKindOfClass:[NSWindow class]])
    popoverWindow = nil;
  _popoverContentView = note.userInfo[@"contentView"];
  // A cold boot can deliver this before the popover has a window at all. Keep
  // the content view and resolve the window from it, rather than treating a
  // window-less open as "no popover" - that was why the first popover after
  // launch never got its panel.
  if (!popoverWindow && !_popoverContentView)
    return;
  NSValue *cardVal = note.userInfo[@"contentRect"];
  _parentWindow = popoverWindow;
  _openCard = cardVal ? cardVal.rectValue
                      : (popoverWindow ? popoverWindow.frame : NSZeroRect);
  _openFraction = [note.userInfo[@"fraction"] doubleValue];
  // Resolve rather than trust the pushed flag: this is the path that runs
  // before -applyTimeline: ever has.
  _surfaceEnabled = [self _resolveSurfaceEnabledFromLanes];
  [self _showIfPopoverOpen];
}

// The mini viewer lives inside the popover's own content view, so it is found
// by walking that hierarchy rather than being handed over: the notification
// carries the content view, and the panel is a separate window with no other
// route to it.
KKMiniViewerView *MirageFindMiniViewer(NSView *root) {
  if (!root)
    return nil;
  if ([root isKindOfClass:[KKMiniViewerView class]])
    return (KKMiniViewerView *)root;
  for (NSView *sub in root.subviews) {
    KKMiniViewerView *found = MirageFindMiniViewer(sub);
    if (found)
      return found;
  }
  return nil;
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
  if (!mini || mini == _measuredMini)
    return;
  [self _stopSampling];
  _measuredMini = mini;
  __weak typeof(self) weak = self;
  mini.onProcessedFrameReady = ^{
    [weak _frameReady];
  };
  // The feed's first frame lands well after the panel is built, so the compare
  // buttons only learn there IS an ungraded frame from this edge.
  mini.onCompareStateChanged = ^{
    [weak _refreshCompareButtons];
  };
  [self _refreshCompareButtons];
  [self _sampleOnce]; // the frame already on screen shouldn't wait for the next
}

- (void)_stopSampling {
  [self _disarmPicking];
  [self _dropShortcutMonitors];
  _measuredMini.onProcessedFrameReady = nil;
  // Cleared before the bypass is dropped, so releasing it can't call back into
  // a panel that is already tearing down. A bypass still held when the popover
  // closed would otherwise leave the preview ungraded with no button to
  // release.
  _measuredMini.onCompareStateChanged = nil;
  _measuredMini.compareBypassing = NO;
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
  MirageScopeReading *reading = [_sampler readTexture:graded
                                               device:mini.device
                                             binCount:kToneBinCount
                                              minStop:kRingMinStop
                                              maxStop:kRingMaxStop];
  if (!reading.sampleCount)
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
  if (!_panel.isVisible)
    return;
  [self _refreshPuck];
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
                            source:[MiragePlugin
                                       shaderSourceFromTimeline:timeline]];
  [self _refreshPuck];
}

- (void)_popoverDidClose:(NSNotification *)note {
  [self _endPuckDragReason:@"the popover closed"];
  [self _stopSampling];
  // A declaration is a statement about the shot being graded, so it does not
  // outlive the popover it was made in. Nor does the matte: it is what you were
  // looking at while you worked, and the next session starts on the picture -
  // the same reason the mini's own split and bypass come back off, theirs by
  // being torn down with the view.
  _showSelectionActive = NO;
  _pickDeclaration = MirageMemoryColorNeutral;
  [self _setDeclarationSentence:nil];
  _parentWindow = nil;
  _popoverContentView = nil;
  _openCard = NSZeroRect;
  [_panel hidePanel];
}

@end
