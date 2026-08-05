/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageInspectorChrome.h"

#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKTokens.h>

@implementation _MirageFirstMouseButton {
  BOOL _holding;
  id _holdMonitor;
  id _holdGlobalMonitor;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

// Press-and-hold, because "show me it without the effect" is a comparison you
// make WHILE looking - the release matters as much as the press, and an
// action-on-click button has no release to offer.
//
// The release is caught with monitors rather than -mouseUp:, for the same
// reason the colour circle's drag is: the windows these buttons live in never
// become key, so the up routinely arrives forwarded or global and the button's
// own tracking never sees it. A missed release would leave the preview stuck
// showing the ungraded frame.
- (void)mouseDown:(NSEvent *)event {
  if (!self.onHoldChanged) {
    [super mouseDown:event];
    return;
  }
  if (_holding)
    return;
  _holding = YES;
  self.onHoldChanged(YES);
  __weak _MirageFirstMouseButton *weak = self;
  _holdMonitor =
      [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                            handler:^NSEvent *(NSEvent *e) {
                                              [weak _endHold];
                                              return e;
                                            }];
  _holdGlobalMonitor =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                             handler:^(NSEvent *e) {
                                               [weak _endHold];
                                             }];
}

- (void)_endHold {
  [self _removeHoldMonitors];
  if (!_holding)
    return;
  _holding = NO;
  if (self.onHoldChanged)
    self.onHoldChanged(NO);
}

- (void)_removeHoldMonitors {
  MirageDropMonitor(&_holdMonitor);
  MirageDropMonitor(&_holdGlobalMonitor);
}

- (void)dealloc {
  [self _removeHoldMonitors];
}
@end

@implementation _MirageMiniChromeChip

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

// Swallow a press that lands on the chip's background rather than on one of its
// buttons, so the gap between two icons is not a hole into the preview.
- (void)mouseDown:(NSEvent *)event {
}

@end

BOOL MiragePointInMiniChrome(KKMiniViewerView *mini, NSPoint pointInView) {
  for (NSView *sub in mini.subviews)
    if ([sub isKindOfClass:[_MirageMiniChromeChip class]] && !sub.isHidden &&
        NSPointInRect(pointInView, sub.frame))
      return YES;
  return NO;
}

_MirageFirstMouseButton *MirageMakeIconButton(NSString *symbol, NSString *label,
                                              id target, SEL action) {
  _MirageFirstMouseButton *button =
      [_MirageFirstMouseButton buttonWithTitle:@"" target:target action:action];
  button.bezelStyle = NSBezelStyleAccessoryBarAction;
  button.bordered = NO;
  button.font = [NSFont systemFontOfSize:KKFontSizeSM];
  button.contentTintColor = NSColor.secondaryLabelColor;
  if (!symbol.length)
    return button;
  button.image = [NSImage imageWithSystemSymbolName:symbol
                           accessibilityDescription:label];
  button.imagePosition = NSImageOnly;
  button.accessibilityLabel = label;
  return button;
}

NSString *MirageWithShortcut(NSString *tooltip, NSString *key) {
  if (!tooltip.length || !key.length)
    return tooltip;
  return [NSString stringWithFormat:@"%@ (%@)", tooltip, key];
}

void MirageDropMonitor(__strong id *slot) {
  if (!slot || !*slot)
    return;
  [NSEvent removeMonitor:*slot];
  *slot = nil;
}

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

/// YES when `responder` is a text object that would have taken the keystroke.
/// A field editor answers for whichever control it is currently serving, so
/// NSTextField, NSSearchField and the code editor are all one test.
static BOOL MirageRespondsAsEditor(NSResponder *responder) {
  return [responder isKindOfClass:[NSText class]] &&
         ((NSText *)responder).isEditable;
}

// The key window is the whole answer. Typing goes to the first responder of the
// window that holds the keyboard and nowhere else, so a text object in any
// other window is not editing however much it looks it - and a popover in the
// ViewBridge process routinely leaves an editable text view as some other
// window's first responder long after that window stopped receiving keys.
// Scanning those windows (which is what the no-key-window case used to do) read
// a browser panel's search field as an edit in progress and disabled the
// compare shortcuts for the rest of the session.
BOOL MirageTextEditingInProgress(void) {
  NSWindow *key = NSApp.keyWindow;
  return key ? MirageRespondsAsEditor(key.firstResponder) : NO;
}
