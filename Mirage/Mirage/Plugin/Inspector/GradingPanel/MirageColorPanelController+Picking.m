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

/// Escape's virtual key code. Hard-coded because it is a hardware constant, not
/// a layout-dependent character.
static const unsigned short kEscapeKeyCode = 53;

/// The sampler button's title for what the patch is being declared to be.
static NSString *MirageSampleTitle(MirageMemoryColor kind) {
  switch (kind) {
  case MirageMemoryColorSkin:
    return RLoc(@"Sample skin",
                @"Color panel button that samples a patch of skin "
                @"to measure how far off it is.");
  case MirageMemoryColorFoliage:
    return RLoc(
        @"Sample foliage",
        @"Color panel button that samples a patch of grass or leaves to "
        @"measure how far off it is.");
  case MirageMemoryColorSky:
    return RLoc(@"Sample sky",
                @"Color panel button that samples a patch of clear "
                @"sky to measure how far off it is.");
  case MirageMemoryColorNeutral:
    break;
  }
  return RLoc(@"Sample grey", @"Color panel button that samples a "
                              @"patch which ought to be neutral, "
                              @"to measure the frame's cast.");
}

static NSString *MirageSampleTooltip(MirageMemoryColor kind) {
  switch (kind) {
  case MirageMemoryColorSkin:
    return RLoc(
        @"Click a face in the frame. The cross shows how far the skin is "
        @"from where skin belongs - drag the puck the other way until it "
        @"centres.",
        @"Tooltip for the Color panel's sampler when it is set to skin.");
  case MirageMemoryColorFoliage:
    return RLoc(
        @"Click grass or leaves in the frame. The cross shows how far they "
        @"are from where foliage belongs - drag the puck the other way "
        @"until it centres.",
        @"Tooltip for the Color panel's sampler when it is set to "
        @"foliage.");
  case MirageMemoryColorSky:
    return RLoc(
        @"Click clear sky in the frame. Sky varies more than anything else "
        @"you can sample, so treat this one as approximate - drag the puck "
        @"the other way until the cross centres.",
        @"Tooltip for the Color panel's sampler when it is set to sky, "
        @"warning that the reading is only approximate.");
  case MirageMemoryColorNeutral:
    break;
  }
  return RLoc(
      @"Click something in the frame that should be grey. The cross shows "
      @"how far off it is - drag the puck the other way until it centres.",
      @"Tooltip for the Color panel's grey-reference sampler.");
}

@implementation MirageColorPanelController (Picking)

// The sampler is a PULL-DOWN, not a toggle: one button, four things the patch
// can be declared to be.
//
// A row of declarations, or a second button beside the sampler, was the obvious
// shape and the wrong one - the header had just been cleared of exactly that,
// and choosing what you are about to sample is the same gesture as arming the
// sampler, not a separate mode to set first.
- (void)_showPickMenu:(id)sender {
  NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
  for (NSNumber *boxed in @[
         @(MirageMemoryColorNeutral), @(MirageMemoryColorSkin),
         @(MirageMemoryColorFoliage), @(MirageMemoryColorSky)
       ]) {
    MirageMemoryColor kind = (MirageMemoryColor)boxed.integerValue;
    NSMenuItem *item =
        [[NSMenuItem alloc] initWithTitle:MirageSampleTitle(kind)
                                   action:@selector(_choosePickDeclaration:)
                            keyEquivalent:@""];
    item.target = self;
    item.tag = kind;
    item.toolTip = MirageSampleTooltip(kind);
    item.state = (kind == _pickDeclaration) ? NSControlStateValueOn
                                            : NSControlStateValueOff;
    [menu addItem:item];
  }
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0.0, NSHeight(_pickButton.bounds))
                          inView:_pickButton];
}

// Choosing ALWAYS arms, and always drops the previous reference.
//
// The pick is held as a POSITION and re-measured every frame, so leaving it in
// place would have the same pixels judged against a region they were never
// picked for - the cross would jump to a confident reading of a patch nobody
// declared.
- (void)_choosePickDeclaration:(NSMenuItem *)item {
  _pickDeclaration = (MirageMemoryColor)item.tag;
  _sampler.pickUV = NSMakePoint(-1.0, -1.0);
  [self _hueCircle].castAvailable = NO;
  [self _setDeclarationSentence:nil];
  [self _armPicking];
  [self _refreshPuck];
}

// Arm the picker. The next click anywhere in the mini viewer samples that
// point.
//
// Caught with an event monitor rather than by hooking the mini viewer: the
// preview already owns its clicks for OSC handles, and a picker that fought
// that would break dragging. Monitors are also the only thing that reliably
// sees this process's mouse stream.
- (void)_armPicking {
  [self _disarmPicking];
  _picking = YES;
  _pickButton.contentTintColor = NSColor.accentMatchingHost;
  [self _installPickMonitors];
}

// The colour eyedropper. Same click, a different question: what the shader's
// `pick=` controls should be aimed at, rather than what should be neutral.
- (void)_toggleColorPicking:(id)sender {
  BOOL wasArmed = _pickingColor;
  [self _disarmPicking];
  if (wasArmed)
    return;
  _pickingColor = YES;
  _pickColorButton.contentTintColor = NSColor.accentMatchingHost;
  [self _installPickMonitors];
}

// Click-to-pick: one click in the preview aims the active puck at a colour.
//
// One-shot and self-cancelling, like the other two - the click disarms,
// pressing the button again disarms, and Escape disarms - because an arming
// state you can forget you are in turns the next ordinary click on the preview
// into a parameter write nobody asked for.
- (void)_togglePickFromClip:(id)sender {
  BOOL wasArmed = _pickingSource;
  [self _disarmPicking];
  if (wasArmed)
    return;
  _pickingSource = YES;
  _pickSourceButton.contentTintColor = NSColor.accentMatchingHost;
  [self _installPickMonitors];
}

- (void)_installPickMonitors {
  __weak typeof(self) weak = self;
  // BOTH monitors. A click on the mini viewer does not necessarily reach this
  // process as a locally-dispatched event - the inspector's clicks are
  // forwarded and re-sent - so the local monitor alone saw nothing at all.
  _pickMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(weak) s = weak;
                                     if (!s)
                                       return e;
                                     if ([s _handlePickEvent:e])
                                       return nil; // consumed: don't also grab
                                                   // a handle
                                     return e;
                                   }];
  _pickGlobalMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                             handler:^(NSEvent *e) {
                                               [weak _handlePickEvent:e];
                                             }];
  NSEventMask moved = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged;
  _pickCursorMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:moved
                                            handler:^NSEvent *(NSEvent *e) {
                                              [weak _updatePickCursor];
                                              return e;
                                            }];
  _pickCursorGlobalMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:moved
                                             handler:^(NSEvent *e) {
                                               [weak _updatePickCursor];
                                             }];
  _pickKeyMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(weak) s = weak;
                                     if (s && e.keyCode == kEscapeKeyCode) {
                                       [s _disarmPicking];
                                       return nil; // consumed: don't also close
                                                   // the popover
                                     }
                                     return e;
                                   }];
  _pickKeyGlobalMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                             handler:^(NSEvent *e) {
                                               if (e.keyCode == kEscapeKeyCode)
                                                 [weak _disarmPicking];
                                             }];
  [self _updatePickCursor];
}

/// Crosshair while the pointer is over the picture, the ordinary arrow
/// elsewhere. Set from the event stream rather than from a tracking area,
/// because the mini viewer's own cursor handling does not run for a panel in
/// another window.
- (void)_updatePickCursor {
  if (!_picking && !_pickingColor && !_pickingSource)
    return;
  KKMiniViewerView *mini = MirageFindMiniViewer(_popoverContentView);
  if ([mini pointerOverCanvas])
    [NSCursor.crosshairCursor set];
  else
    [NSCursor.arrowCursor set];
}

- (void)_disarmPicking {
  BOOL wasArmed = _picking || _pickingColor || _pickingSource;
  _picking = NO;
  _pickingColor = NO;
  _pickingSource = NO;
  _pickButton.contentTintColor = NSColor.secondaryLabelColor;
  _pickColorButton.contentTintColor = NSColor.secondaryLabelColor;
  _pickSourceButton.contentTintColor = NSColor.secondaryLabelColor;
  MirageDropMonitor(&_pickMonitor);
  MirageDropMonitor(&_pickGlobalMonitor);
  MirageDropMonitor(&_pickCursorMonitor);
  MirageDropMonitor(&_pickCursorGlobalMonitor);
  MirageDropMonitor(&_pickKeyMonitor);
  MirageDropMonitor(&_pickKeyGlobalMonitor);
  if (wasArmed)
    [NSCursor.arrowCursor set];
}

- (BOOL)_handlePickEvent:(NSEvent *)event {
  if (!_picking && !_pickingColor && !_pickingSource)
    return NO;
  KKMiniViewerView *mini = MirageFindMiniViewer(_popoverContentView);
  if (!mini.window) {
    KKLogWarn(@"[Pick] no mini viewer in the popover content view");
    return NO;
  }
  // Screen point from the CGEvent: a global monitor's event has no window, and
  // a forwarded one's window is not necessarily the one the cursor is over.
  NSPoint screen;
  CGEventRef cg = event.CGEvent;
  if (cg) {
    CGPoint global = CGEventGetLocation(cg);
    NSScreen *primary = NSScreen.screens.firstObject;
    screen = NSMakePoint(global.x, NSMaxY(primary.frame) - global.y);
  } else if (event.window) {
    screen = [event.window convertPointToScreen:event.locationInWindow];
  } else {
    screen = event.locationInWindow;
  }
  NSPoint inView =
      [mini convertPoint:[mini.window convertPointFromScreen:screen]
                fromView:nil];
  // A click on the row of chrome the preview carries is that row's, not a
  // reading of the pixel behind it. Left alone and still armed, so pressing
  // Before mid-pick does what the button says and the next click in the picture
  // still picks.
  if (MiragePointInMiniChrome(mini, inView))
    return NO;
  CGRect content = [mini contentRectInViewPoints];
  if (!NSPointInRect(inView, content))
    return NO; // clicked outside the image: leave the click alone and stay
               // armed
  // Both the view and the processed texture are bottom-origin, so this maps
  // across without a flip.
  NSPoint uv = NSMakePoint((inView.x - content.origin.x) / content.size.width,
                           (inView.y - content.origin.y) / content.size.height);
  if (_pickingSource) {
    // The SOURCE pixel, not the processed one. Aiming a control at the effect's
    // own output makes the target a moving object: the write changes the grade,
    // the grade changes the pixel that was clicked, and re-picking the same
    // spot walks the value further every time. The clip's untouched footage is
    // the only fixed thing to measure against.
    [self _pickFromSourceAtUV:uv inMini:mini];
    [self _disarmPicking];
    return YES;
  }
  if (_pickingColor) {
    _sampler.probeUV = uv;
    _pendingColorPick = YES;
  } else {
    _sampler.pickUV = uv;
  }
  // Measure before disarming, so the write and the refresh happen while the
  // gesture is still the current one. A pick clicked before the first frame has
  // rendered stays pending and lands on the next one.
  [self _sampleOnce];
  [self _disarmPicking];
  return YES;
}

/// Read the clip's own pixel under the click and aim the active puck at it.
///
/// Measured here and written later: the readback is a blit this monitor can do
/// safely, but the parameter write cannot happen inside event dispatch - see
/// -_schedulePickWrite:activePuckOnly:.
- (void)_pickFromSourceAtUV:(NSPoint)uv inMini:(KKMiniViewerView *)mini {
  id<MTLTexture> source = mini.sourceTexture;
  if (!source || !mini.device) {
    KKLogWarn(@"[Pick] the preview has no source frame to sample");
    return;
  }
  if (!_sampler)
    _sampler = [MirageScopeSampler new];
  NSArray<NSNumber *> *rgb = [_sampler probeTexture:source
                                             device:mini.device
                                               atUV:uv];
  if (rgb.count < 3) {
    KKLogWarn(@"[Pick] the source frame could not be sampled at the click");
    return;
  }
  [self _schedulePickWrite:rgb activePuckOnly:YES];
}

// A measured pick writes on the NEXT turn of the run loop, never where it was
// measured.
//
// Both routes into the measurement are the wrong moment to mutate the timeline
// from. The click's own `_sampleOnce` runs synchronously inside an NSEvent
// monitor, part-way through dispatching the very mouse-down that armed the
// picker, and the sampler reads the probe on that same call - so the common
// case wrote a parameter from inside event dispatch. The slow case runs off the
// mini viewer's frame-ready callback instead. FCP reported a caught exception
// from inside our own "Adjust Mirage" action - FFChannelChangeContext
// willSetChannel: through FFChannelAction lockChannels - which is what its
// channel lock raises when a parameter write re-enters it. Handing the write to
// the main queue costs a frame nobody can see and makes it an ordinary edit
// again.
- (void)_schedulePickWrite:(NSArray<NSNumber *> *)rgb
            activePuckOnly:(BOOL)activePuckOnly {
  if (_pickWriteInFlight) {
    KKLogWarn(@"[Pick] a colour write is already in flight, dropping this one");
    return;
  }
  _pickWriteInFlight = YES;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_pickWriteInFlight = NO;
    // The popover can close between the measurement and this block, and its
    // controller outlives it.
    if (!s->_panel.isVisible) {
      KKLogInfo(@"[Pick] the panel closed before the colour write, dropped");
      return;
    }
    // The click that armed the pick can land while a puck drag is still open -
    // the drag's mouse-up may have gone to another application - and opening
    // the pick's group inside that one is the nesting FCP's channel lock raises
    // on.
    [s _endPuckDragReason:@"an eyedropper write arrived"];
    [s _applyPickedRGB:rgb activePuckOnly:activePuckOnly];
  });
}

// Write the sampled colour into every control that subscribed with `pick=`.
//
// One undo group for the whole set, like a puck drag: the click was one
// gesture, and a shader mapping hue, saturation and a swatch would otherwise
// cost three steps back to undo one action.
- (void)_applyPickedRGB:(NSArray<NSNumber *> *)rgb
         activePuckOnly:(BOOL)activePuckOnly {
  KKTimeline *timeline = _lanesView.currentTimeline;
  if (!timeline || rgb.count < 3)
    return;
  NSString *source = [self _entrySource:timeline];
  // Same conversion and the same per-property writes either way. Only WHICH
  // subscribers the gesture reaches differs: the eyedropper aims every one of
  // them, and click-to-pick aims the handle the user last touched.
  NSDictionary<NSString *, NSNumber *> *picks =
      activePuckOnly ? [self _picksForActivePuckIn:timeline source:source]
                     : [self _picksInSource:source];
  if (activePuckOnly)
    KKLogInfo(@"[Pick] click-to-pick reaches %lu of the shader's %lu pick= "
              @"control(s)",
              (unsigned long)picks.count,
              (unsigned long)[self _picksInSource:source].count);
  if (!picks.count)
    return;
  double r = rgb[0].doubleValue, g = rgb[1].doubleValue, b = rgb[2].doubleValue;
  // Oklab, so a picked hue means the same angle the wheel's ring paints and the
  // templates rotate in - measured on the display-encoded probe, which is what
  // the helper takes. Saturation is Oklab chroma as a fraction of 0.33, the
  // most colourful thing Rec.709 can show, which is the convention the shader
  // templates' own saturation now uses.
  double L = 0.0, chroma = 0.0, hue = -1.0;
  MirageSurfaceOklabLCh(r, g, b, &L, &chroma, &hue);
  double saturation = MAX(0.0, MIN(1.0, chroma / 0.33));
  // Rec.709 luma, on the display-encoded components it is defined for.
  double luma = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  // The same weights on the LINEAR components, for a control the shader
  // consumes as light rather than as a code value. Two kinds because only the
  // shader knows which space its number lives in, and picking the wrong one is
  // a visible error rather than a rounding: a face sampled at display 0.55 is
  // linear 0.26, so a contrast pivot in `pivot * pow(c / pivot, k)` handed the
  // display number sits about a stop above the grey the user clicked and
  // rotates the image around it. A threshold compared against encoded pixels,
  // as Film Halation's is, wants the display number and stays on `pick=luma`.
  // The decode is the shared sRGB one, never a local pow(2.2): the toe below
  // 0.04045 is where a hand-rolled curve and this one disagree most, which is
  // exactly where shadow pivots get picked.
  double lumaLinear = 0.2126 * MirageSRGBDecode(r) +
                      0.7152 * MirageSRGBDecode(g) +
                      0.0722 * MirageSRGBDecode(b);
  double frac = [self _editFraction];
  NSSet<NSString *> *drivable = [self _drivableKeysIn:timeline fraction:frac];
  NSMutableArray<KKLane *> *lanes = [timeline.lanes mutableCopy];
  NSUInteger written = 0;
  BOOL changed = NO;
  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKLane *lane = lanes[i];
    NSString *bare = [self _bareKeyForLane:lane];
    NSNumber *boxed = bare ? picks[bare] : nil;
    if (!boxed || ![drivable containsObject:lane.key])
      continue; // gated off by a visibleby= rule, so not part of this gesture
    NSArray<NSNumber *> *current = KKTimelineLaneValueAtFraction(lane, frac);
    if (!current.count)
      continue;
    NSInteger idx = KKLaneNearestKeyposeIndex(lane, frac);
    if (idx == NSNotFound)
      continue;
    NSArray<NSNumber *> *lo = lane.componentMin, *hi = lane.componentMax;
    NSMutableArray<NSNumber *> *values = [current mutableCopy];
    switch ((MirageSurfacePickKind)boxed.integerValue) {
    case MirageSurfacePickKindColor:
      if (values.count < 3) {
        KKLogInfo(@"[Pick] %@ asked for pick=color but is not a colour control",
                  lane.key);
        continue;
      }
      // Components past the third are the author's - an alpha the pick has no
      // opinion about.
      values[0] = @(r);
      values[1] = @(g);
      values[2] = @(b);
      break;
    case MirageSurfacePickKindHue: {
      if (hue < 0.0) {
        KKLogInfo(@"[Pick] the patch is neutral, so it has no hue to give %@",
                  lane.key);
        continue;
      }
      // Wrapped to the control's own convention rather than clamped: a hue is
      // circular, so clamping 350 into a -180..180 control would land on 180 -
      // the opposite colour - instead of on -10.
      BOOL signedHue = lo.count && lo.firstObject.doubleValue < 0.0;
      values[0] = @(signedHue ? fmod(hue + 540.0, 360.0) - 180.0 : hue);
      break;
    }
    case MirageSurfacePickKindSaturation:
    case MirageSurfacePickKindLuma:
    case MirageSurfacePickKindLumaLinear: {
      double next = saturation;
      if (boxed.integerValue == MirageSurfacePickKindLuma)
        next = luma;
      else if (boxed.integerValue == MirageSurfacePickKindLumaLinear)
        next = lumaLinear;
      // All three are measured 0..1 - saturation as Oklab chroma over 0.33 -
      // and a control declaring a max well above that is holding percent. Read
      // off the declared range rather than from the directive kind, so a
      // `#float max=100` behaves like the `#percent` it is.
      if (hi.count && hi.firstObject.doubleValue > 1.5)
        next *= 100.0;
      if (lo.count)
        next = MAX(next, lo.firstObject.doubleValue);
      if (hi.count)
        next = MIN(next, hi.firstObject.doubleValue);
      values[0] = @(next);
      break;
    }
    case MirageSurfacePickKindNone:
      continue;
    }
    lanes[i] = KKLaneBySettingValuesAtIndex(lane, idx, values);
    written++;
    changed = YES;
  }
  if (!changed)
    return;
  KKTimeline *updated = [timeline copy];
  updated.lanes = lanes;
  // Logged on both sides on purpose. If the channel-lock exception comes back,
  // the question is whether one of these writes was still open when it was
  // raised, and a "beginning" with no "done" answers it - as does neither line,
  // which would say the picker had nothing to do with it.
  KKLogInfo(@"[Pick] colour write beginning, %lu lane(s)",
            (unsigned long)written);
  [self _beginWriteGroup:@"eyedropper"];
  if (self.onTimelineMutated)
    self.onTimelineMutated(updated);
  [self _endWriteGroup:@"eyedropper"];
  KKLogInfo(@"[Pick] colour write done, %lu lane(s)", (unsigned long)written);
  [self _refreshPuck];
}

/// YES when this shader has a `pick=` control the eyedropper could actually
/// write. Same visibility gate as the puck: a control a `visibleby=` rule has
/// hidden is not part of the gesture, and a picker that writes only invisible
/// controls would look broken.
- (BOOL)_hasDrivablePicksIn:(KKTimeline *)timeline source:(NSString *)source {
  NSDictionary<NSString *, NSNumber *> *picks = [self _picksInSource:source];
  if (!picks.count)
    return NO;
  NSSet<NSString *> *drivable = [self _drivableKeysIn:timeline
                                             fraction:[self _editFraction]];
  for (NSString *key in picks)
    if ([drivable containsObject:key])
      return YES;
  return NO;
}

/// Title both pickers for what they actually do in THIS shader.
///
/// The grey one is a measurement and always says so. The write picker names the
/// control it is pointed at - "Pick Pivot", "Pick Target Hue" - because that is
/// the only honest label: the same button sets a luminance in one shader and a
/// hue in the next, so any fixed wording would be wrong somewhere. With several
/// subscribers there is no single name to borrow, so it falls back to the
/// generic.
- (void)_refreshHeaderButtonTitlesIn:(KKTimeline *)timeline
                              source:(NSString *)source {
  // The grey reference feeds the cast cross, which only the hue ring draws - so
  // it is offered whenever a hue ring is declared, whichever of the two it is.
  // The wedge under that ring is gated by the same fact, and placed by
  // -_applyPanelLayout so it sits below the wheel it belongs to.
  BOOL hueRing =
      MirageColorSurfaceDeclaresRing(source, MirageColorSurfaceRingHue);
  _pickButton.hidden = !hueRing;
  if (_pickButton.hidden && _picking)
    [self _disarmPicking];
  // Both come from the declaration, so the one button says what it is about to
  // measure rather than making the choice something you have to remember
  // making.
  _pickButton.title = MirageSampleTitle(_pickDeclaration);
  _pickButton.toolTip = MirageSampleTooltip(_pickDeclaration);

  if (!_pickColorButton.hidden) {
    NSArray<NSString *> *labels = [self _pickTargetLabelsIn:timeline
                                                     source:source];
    _pickColorButton.title =
        labels.count == 1
            ? [NSString
                  stringWithFormat:RLoc(@"Pick %@",
                                        @"Color panel button that sets one "
                                        @"named control from a colour "
                                        @"clicked in the frame. %@ is that "
                                        @"control's name."),
                                   labels.firstObject]
            : RLoc(@"Pick from frame",
                   @"Color panel button that sets several "
                   @"controls at once from a colour clicked "
                   @"in the frame.");
    _pickColorButton.toolTip = RLoc(
        @"Click a color in the frame to set this shader's controls from it.",
        @"Tooltip for the Color panel's sampler that writes controls.");
  }
  // The add/remove pair reads the same two facts this method is already
  // holding - what the shader declares and what the project has - so it is
  // refreshed from here rather than from its own pass over both.
  [self _refreshSlotButtonsIn:timeline source:source];
  [self _layoutHeaderButtons];
  // The in-well row is the one part of this panel whose PRESENCE moves the well
  // and the panel around it, so it is re-laid-out when its button set changes
  // and not on every sampled frame - which is how often this method runs.
  NSInteger mask = (_addSlotButton.hidden ? 0 : 1) |
                   (_removeSlotButton.hidden ? 0 : 2) |
                   (_pickSourceButton.hidden ? 0 : 4);
  if (mask != _wellRowMask) {
    _wellRowMask = mask;
    [self _applyPanelLayout];
  }
}

/// Inspector labels of the controls the eyedropper would write, in lane order.
- (NSArray<NSString *> *)_pickTargetLabelsIn:(KKTimeline *)timeline
                                      source:(NSString *)source {
  NSDictionary<NSString *, NSNumber *> *picks = [self _picksInSource:source];
  if (!picks.count)
    return @[];
  NSSet<NSString *> *drivable = [self _drivableKeysIn:timeline
                                             fraction:[self _editFraction]];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (KKLane *lane in timeline.lanes) {
    NSString *bare = [self _bareKeyForLane:lane];
    if (!bare || !picks[bare])
      continue;
    if (![drivable containsObject:lane.key])
      continue;
    [labels addObject:lane.label.length ? lane.label : bare];
  }
  return labels;
}

/// The ring whose `activePuck` click-to-pick answers to.
///
/// The hue wheel when there is one, for the same reason the cast cross and the
/// memory-colour wedge bind there: a picked colour is a hue, and a tonal ramp
/// has nowhere to put one. Otherwise the first declared circle, which is the
/// only one a single-surface shader has.
- (NSUInteger)_pickRingIndex {
  for (NSUInteger i = 0; i < [self _ringCount] && i < _circles.count; i++)
    if ([self _ringAtIndex:i] == MirageColorSurfaceRingHue)
      return i;
  return 0;
}

/// The `pick=` controls the ACTIVE puck owns, in the shape the write path
/// takes.
///
/// `puck=` is the pairing, and it is the ONLY pairing. A subscriber declaring
/// it answers to that handle and no other, whether or not it also declares a
/// `surface=` - which is what lets a three-slot shader keep a target hue and
/// the centre it is measured from on the same handle even though only one of
/// them is draggable.
///
/// A subscriber that names no puck in a shader that names pucks is left OUT. It
/// looks harsh next to "write everything", and it is the whole point: the
/// eyedropper's write-all is a different gesture and still does exactly that. A
/// click on one handle that silently also wrote the other two handles' controls
/// would fill every slot with the same colour, and the author would have no way
/// to tell it to stop. A shader that names no puck at all has one unnamed
/// handle every control belongs to, so nothing is narrowed there.
- (NSDictionary<NSString *, NSNumber *> *)
    _picksForActivePuckIn:(KKTimeline *)timeline
                   source:(NSString *)source {
  NSDictionary<NSString *, NSNumber *> *picks = [self _picksInSource:source];
  if (!picks.count)
    return @{};
  NSUInteger ringIndex = [self _pickRingIndex];
  NSUInteger activePuck =
      ringIndex < _circles.count ? _circles[ringIndex].activePuck : 0;
  NSString *puckName =
      [self _puckNameAtIndex:activePuck ring:ringIndex source:source] ?: @"";
  NSDictionary<NSString *, NSString *> *puckNames =
      [self _puckNamesInSource:source];
  BOOL named = puckNames.count > 0;
  NSSet<NSString *> *drivable = [self _drivableKeysIn:timeline
                                             fraction:[self _editFraction]];
  NSMutableDictionary<NSString *, NSNumber *> *out =
      [NSMutableDictionary dictionary];
  for (NSString *key in picks) {
    if (![drivable containsObject:key])
      continue; // gated off by a visibleby= rule, so not part of this gesture
    NSString *declared = puckNames[key];
    if (!declared.length) {
      if (named)
        continue; // named pucks exist and this control joined none of them
    } else if (![declared isEqualToString:puckName]) {
      continue;
    }
    out[key] = picks[key];
  }
  return out;
}

@end
