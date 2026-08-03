/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageMiniCompareControls.h"

#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <QuartzCore/QuartzCore.h>

#import "MirageInspectorChrome.h"
#import "MirageLocalized.h"
#import "MirageSurfaceResponse.h" // MirageSurfaceSelectionToggleForSource
#import "Plugin_Private.h"        // +shaderSourceFromTimeline:

/// One button, and the gap between two. Matched to the Color panel's header
/// icons so the two clusters read as the same control at the same size.
static const CGFloat kButtonSize = 18.0;

/// The row's own insets inside its chip, and the chip's inset from the
/// preview's top-left corner. The chip is styled as a CAPSULE matching the
/// popover's size/render pills (height 22, radius = height/2, 8pt end padding
/// per KKPillToggleRowView's grouped metrics), so the preview chrome and the
/// popover chrome read as one family.
static const CGFloat kChipInsetY = 2.0;
static const CGFloat kChipPadX = 8.0;
static const CGFloat kEdgeInset = KKPaddingSM;

@implementation MirageMiniCompareControls {
  __weak KKTimelineLanesView *_lanesView;
  __weak KKMiniViewerView *_mini;
  NSView *_popoverContentView;
  _MirageMiniChromeChip *_chip;
  _MirageFirstMouseButton *_beforeButton;
  NSButton *_splitButton;
  NSButton *_selectionButton;
  BOOL _showSelectionActive;
  /// B, S and M, watched LOCALLY only - a global monitor cannot consume, and a
  /// shortcut Final Cut also acts on is worse than none. The inspector's
  /// -miniGrabsKeyFocusOnClick is what makes the local one see them at all.
  id _shortcutMonitor;
  /// YES while the B key - rather than the mouse - is holding the bypass on.
  /// The key-up that would release it can be delivered to another application,
  /// so this is what lets every teardown path drop a bypass the keyboard put on
  /// without also cancelling one the mouse is still holding.
  BOOL _bypassHeldByKey;
}

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView {
  if ((self = [super init])) {
    _lanesView = lanesView;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self
           selector:@selector(_popoverDidOpen:)
               name:KKStaticValuesPopoverDidOpenNotification
             object:lanesView];
    [nc addObserver:self
           selector:@selector(_popoverDidClose:)
               name:KKStaticValuesPopoverDidCloseNotification
             object:lanesView];
    // The key-up that would release a keyboard-held bypass goes to whichever
    // application just took focus, so a B held while clicking away would leave
    // the preview permanently unprocessed.
    [nc addObserver:self
           selector:@selector(_focusLeftApp:)
               name:NSApplicationDidResignActiveNotification
             object:nil];
  }
  return self;
}

- (void)invalidate {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self _teardown];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [self _teardown];
}

- (BOOL)showSelectionActive {
  return _showSelectionActive;
}

- (void)_popoverDidOpen:(NSNotification *)note {
  NSView *content = note.userInfo[@"contentView"];
  if (![content isKindOfClass:[NSView class]])
    return;
  _popoverContentView = content;
  KKMiniViewerView *mini = MirageFindMiniViewer(content);
  // A popover with no preview in it - a structural one, or a lane the plugin
  // publishes no descriptor for - gets no row and no shortcuts. There is
  // nothing for either to act on.
  if (!mini)
    return;
  // In the notification turn, like both companion panels. This was deferred a
  // tick, guarded on `_popoverContentView` still being this content view - and
  // that guard cannot hold: the popover instance is reused across opens, so an
  // outgoing popover's close callback can run around an incoming open, and the
  // close nils exactly the view the guard tests. A late close inside that one
  // tick dropped the row entirely. Three buttons is not worth a guard that can
  // be wrong.
  [self _installInMini:mini];
  // AFTER the install: it teardowns the previous row on its way in, and the
  // teardown clears this.
  _popoverContentView = content;
}

- (void)_popoverDidClose:(NSNotification *)note {
  [self _teardown];
}

- (void)_focusLeftApp:(NSNotification *)note {
  [self _releaseKeyBypass];
}

// Everything this row put on screen or on the event stream, undone.
//
// The matte goes with it: it is what you were looking at while you worked, and
// the next session starts on the picture - the same reason the mini's own split
// and bypass come back off, theirs by being torn down with the view.
- (void)_teardown {
  [self _dropShortcutMonitor];
  KKMiniViewerView *mini = _mini;
  mini.onCompareStateChanged = nil;
  mini.compareBypassing = NO;
  _mini = nil;
  [_chip removeFromSuperview];
  _chip = nil;
  _beforeButton = nil;
  _splitButton = nil;
  _selectionButton = nil;
  _popoverContentView = nil;
  if (!_showSelectionActive)
    return;
  _showSelectionActive = NO;
  if (self.onSelectionChanged)
    self.onSelectionChanged(NO);
}

- (void)_installInMini:(KKMiniViewerView *)mini {
  if (_mini == mini && _chip.superview == mini) {
    [self _refreshControls];
    return;
  }
  [self _teardown];
  _mini = mini;

  _MirageMiniChromeChip *chip =
      [[_MirageMiniChromeChip alloc] initWithFrame:NSZeroRect];
  chip.wantsLayer = YES;
  // Dark enough to keep a secondary-label icon legible over a blown-out frame,
  // translucent enough that it reads as chrome ON the picture rather than as a
  // hole punched in it.
  chip.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.55].CGColor;
  // Capsule: radius = half the chip height, matching the sm/md/lg size pill.
  chip.layer.cornerRadius = (kButtonSize + 2.0 * kChipInsetY) / 2.0;
  // Pinned to the top-left: the preview grows downward and rightward with the
  // popover's size pill, and the left corner keeps clear of the divider handle,
  // which parks at the split fraction toward the right.
  chip.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
  _chip = chip;

  __weak typeof(self) weak = self;
  _MirageFirstMouseButton *before = MirageMakeIconButton(
      @"eye",
      RLoc(@"Before", @"Color panel button held down to see "
                      @"the frame without the effect "
                      @"applied."),
      nil, NULL);
  before.toolTip = MirageWithShortcut(
      RLoc(@"Hold to see the frame without this effect.",
           @"Tooltip for the Color panel's hold-to-bypass button."),
      @"B");
  before.onHoldChanged = ^(BOOL held) {
    [weak _setCompareBypass:held];
  };
  [chip addSubview:before];
  _beforeButton = before;

  NSButton *split =
      MirageMakeIconButton(@"rectangle.split.2x1",
                           RLoc(@"Split", @"Color panel button that splits the "
                                          @"preview: the graded frame on the "
                                          @"left, the original on the right."),
                           self, @selector(_toggleCompareSplit:));
  split.toolTip = MirageWithShortcut(
      RLoc(@"Show the graded frame beside the original. Drag the divider in "
           @"the preview to move the split.",
           @"Tooltip for the Color panel's split-preview toggle."),
      @"S");
  [chip addSubview:split];
  _splitButton = split;

  NSButton *selection = MirageMakeIconButton(
      @"circle.dashed",
      RLoc(@"Show Selection", @"Color panel button that shows the shader's "
                              @"selection - its matte - instead of the graded "
                              @"picture."),
      self, @selector(_toggleShowSelection:));
  selection.toolTip = MirageWithShortcut(
      RLoc(@"Show this shader's selection instead of the graded picture.",
           @"Tooltip for the Color panel's show-selection toggle."),
      @"M");
  [chip addSubview:selection];
  _selectionButton = selection;

  [mini addSubview:chip];
  // The feed's first frame lands well after the popover is built, so the
  // compare buttons only learn there IS an ungraded frame from this edge.
  mini.onCompareStateChanged = ^{
    [weak _refreshControls];
  };
  [self _refreshControls];
  [self _installShortcutMonitor];
}

- (void)timelineDidChange {
  if (_chip)
    [self _refreshControls];
}

/// The shader source the row's one shader-dependent button is a function of.
- (NSString *)_source {
  KKTimeline *timeline = _lanesView.currentTimeline;
  return timeline ? [MiragePlugin shaderSourceFromTimeline:timeline] : @"";
}

/// Whether this shader offers a selection switch at all. The DECLARATION alone,
/// with no lane to look for: the control is session state, so there never is
/// one.
- (BOOL)_declaresSelectionToggle {
  return MirageSurfaceSelectionToggleForSource([self _source]).length > 0;
}

// Which buttons the row is showing, how they are tinted, and how wide that
// makes it.
//
// The compare pair reads its tint back off the preview rather than from a flag
// here: the mini viewer is rebuilt with the popover, so a remembered toggle
// would light a button for a split that no longer exists. A generator has no
// ungraded frame at all, so both go away rather than sitting there doing
// nothing - and a template with neither an ungraded frame nor a selection
// switch shows no row at all rather than an empty chip.
- (void)_refreshControls {
  KKMiniViewerView *mini = _mini;
  if (!_chip || !mini)
    return;
  BOOL available = mini.compareAvailable;
  _splitButton.hidden = !available;
  _beforeButton.hidden = !available;
  _selectionButton.hidden = ![self _declaresSelectionToggle];
  _splitButton.contentTintColor = (available && mini.compareSplitEnabled)
                                      ? NSColor.accentMatchingHost
                                      : NSColor.secondaryLabelColor;
  _beforeButton.contentTintColor = (available && mini.compareBypassing)
                                       ? NSColor.accentMatchingHost
                                       : NSColor.secondaryLabelColor;
  _selectionButton.contentTintColor = _showSelectionActive
                                          ? NSColor.accentMatchingHost
                                          : NSColor.secondaryLabelColor;

  CGFloat x = kChipPadX;
  NSUInteger shown = 0;
  for (NSButton *button in @[ _beforeButton, _splitButton, _selectionButton ]) {
    if (button.hidden)
      continue;
    button.frame = NSMakeRect(x, kChipInsetY, kButtonSize, kButtonSize);
    // 9pt between buttons puts icon centres ~27pt apart, the same rhythm the
    // grouped pill's abutting 8+icon+8 segments produce.
    x += kButtonSize + 9.0;
    shown++;
  }
  _chip.hidden = (shown == 0);
  if (!shown)
    return;
  CGFloat width = x - 9.0 + kChipPadX;
  CGFloat height = kButtonSize + 2.0 * kChipInsetY;
  // Rounded rather than laid out from a fractional canvas size: the preview's
  // bounds follow the popover's width, and a half-pixel origin would soften
  // every icon on the row.
  NSRect bounds = mini.bounds;
  _chip.frame =
      NSMakeRect(round(NSMinX(bounds) + kEdgeInset),
                 round(NSMaxY(bounds) - height - kEdgeInset), width, height);
}

// Split the preview: processed left of the divider, untouched right of it.
//
// Handed straight to the mini viewer, which owns the state for the length of
// the session and nothing longer. It is not a lane, not a parameter and not
// part of the UI state blob on purpose - an honoured FxPlug write is one undo
// entry, so a divider the user drags would bury the edit they actually want to
// step back.
- (void)_toggleCompareSplit:(id)sender {
  KKMiniViewerView *mini = _mini;
  if (!mini.compareAvailable)
    return;
  mini.compareSplitEnabled = !mini.compareSplitEnabled;
  [self _refreshControls];
}

- (void)_setCompareBypass:(BOOL)held {
  KKMiniViewerView *mini = _mini;
  if (!mini.compareAvailable)
    return;
  mini.compareBypassing = held;
  [self _refreshControls];
}

// Flip the switch: NO write, no write group, no undo entry, nothing persisted.
//
// Just the flag and a push into the preview. The push itself is the Color
// panel's, because the same override channel carries the panel's active key and
// the two have to be asserted together - this owns WHETHER the matte shows, the
// panel owns which key it is about, and there is one re-assert for both.
- (void)_toggleShowSelection:(id)sender {
  if (![self _declaresSelectionToggle])
    return;
  _showSelectionActive = !_showSelectionActive;
  if (self.onSelectionChanged)
    self.onSelectionChanged(_showSelectionActive);
  // The preview is a PAUSED Metal view, so it holds its last frame until
  // someone marks it.
  [_mini setNeedsDisplay:YES];
  [self _refreshControls];
}

// The three compare keys, live for as long as the row is on the preview.
//
// ONE monitor, and a LOCAL one, because a shortcut that fires without also
// being consumed is worse than no shortcut: M flipped the matte AND reached
// Final Cut, which took it as "add marker" - and B and S went the same way to
// the blade and the host's own bindings. Only a local monitor can return nil,
// and only a local monitor sees a key at all when this process holds the
// keyboard.
//
// What puts it there is the inspector's -miniGrabsKeyFocusOnClick, the same
// opt-in Canvas makes so a bare Delete removes a layer rather than the effect:
// a click in the preview makes the popover key, and from then on Final Cut
// delivers the letter here first. See KKMiniViewerView's own note on why a
// GLOBAL monitor can only watch a key go past on its way to the host.
//
// Any window of ours will do - the browser or Color panel beside the popover
// counts, since a keyDown reaches a local monitor whichever of our windows is
// key (its `window` is the ViewBridge host window in every case, which is why
// nothing here gates on it). The keyboard being in the PROCESS is the whole
// requirement; the gates below are about the user's intent, not the window.
//
// Installed with the row and dropped with it, so a letter typed anywhere in
// Final Cut with no preview open is nobody's business but Final Cut's. This is
// the only installation: the Color panel used to own an identical one, and two
// monitors for one key is two chances to consume it twice.
- (void)_installShortcutMonitor {
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

- (void)_dropShortcutMonitor {
  MirageDropMonitor(&_shortcutMonitor);
  // A bypass the keyboard is holding cannot survive the monitor that would
  // release it: the key-up would arrive with nothing listening and leave the
  // preview permanently unprocessed.
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
// A modifier means the user is reaching for a command, not a compare; a text
// object having focus means they are typing; and the host's own gesture gate
// (a latched puck drag, an open write group) means a gesture is mid-flight, so
// a second write would land inside the first one's undo group. In each of those
// the event is returned untouched rather than consumed. Escape is not ours at
// all, so the Color panel's Set from clip still disarms on it exactly as
// before.
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
  if (!_chip || _chip.hidden || !_mini)
    return NO;
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
              NSEventModifierFlagOption | NSEventModifierFlagShift |
              NSEventModifierFlagFunction))
    return NO;
  if (MirageTextEditingInProgress())
    return NO;
  if (self.shortcutsSuppressed && self.shortcutsSuppressed())
    return NO;
  NSButton *button = nil;
  if ([ch isEqualToString:@"b"])
    button = _beforeButton;
  else if ([ch isEqualToString:@"s"])
    button = _splitButton;
  else if ([ch isEqualToString:@"m"])
    button = _selectionButton;
  // A key whose button this template does not offer is not this row's key.
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

@end
