/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageBrowserController.h"
#import "MirageBrowserView.h"
#import <KeyframelessKit/KKCompanionPanelController.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPopoverKeepAlive.h> // popover open/close notifications
#import <KeyframelessKit/KKTimeline.h>
#import <QuartzCore/QuartzCore.h>

// Panel sits beside the popover card, ordered behind it; height matches the
// card (KKCompanionPanelController).
static const CGFloat kPanelWidth = 300.0;

@implementation MirageBrowserController {
  KKCompanionPanelController *_panelController;
  MirageBrowserView *_browser;
  __weak NSView *_attachedContentView;
}

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView {
  if ((self = [super init])) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self
           selector:@selector(_popoverDidOpen:)
               name:KKStaticValuesPopoverDidOpenNotification
             object:lanesView];
    [nc addObserver:self
           selector:@selector(_popoverDidClose:)
               name:KKStaticValuesPopoverDidCloseNotification
             object:lanesView];
    [nc addObserver:self
           selector:@selector(_sidebarVisibilityChanged:)
               name:KKStaticValuesSidebarVisibilityDidChangeNotification
             object:lanesView];
  }
  return self;
}

- (void)invalidate {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  self.onSelectEntry = nil;
  self.onPublishEntry = nil;
  self.onDeleteEntry = nil;
  [_panelController hide];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)reload {
  [_browser reload];
}

- (void)refreshLocal {
  [_browser refreshLocal];
}

// The panel itself (chrome, placement, entrance, the child-window
// relationship) comes from the kit; this only builds the browser inside it.
- (KKCompanionPanelController *)_ensurePanelController {
  if (_panelController)
    return _panelController;
  __weak typeof(self) weak = self;
  KKCompanionPanelController *pc =
      [[KKCompanionPanelController alloc] initWithPanelWidth:kPanelWidth
                                                      logTag:@"Browser"];
  pc.contentBuilder = ^NSView * {
    __strong typeof(weak) s = weak;
    if (!s)
      return nil;
    MirageBrowserView *content =
        [[MirageBrowserView alloc] initWithFrame:NSZeroRect];
    // Applying a template is the end of the browser's turn: the user's next
    // move is on the preview, so the keyboard goes back to the popover with it,
    // ending any search-field edit on the way. The compare shortcuts no longer
    // depend on this (they take a panel-keyed process too), but the caret does:
    // leaving it in Search would swallow the very next letter typed.
    content.onSelectEntry = ^(MirageCatalogEntry *e) {
      __strong typeof(weak) inner = weak;
      if (!inner)
        return;
      if (inner.onSelectEntry)
        inner.onSelectEntry(e);
      [inner->_panelController returnKeyFocusToPopover];
    };
    content.onPublishEntry = ^(MirageCatalogEntry *e) {
      __strong typeof(weak) inner = weak;
      if (inner.onPublishEntry)
        inner.onPublishEntry(e);
    };
    content.onDeleteEntry = ^(MirageCatalogEntry *e) {
      __strong typeof(weak) inner = weak;
      if (inner.onDeleteEntry)
        inner.onDeleteEntry(e);
    };
    content.onRenameEntry = ^(MirageCatalogEntry *e, NSString *name) {
      __strong typeof(weak) inner = weak;
      if (inner.onRenameEntry)
        inner.onRenameEntry(e, name);
    };
    s->_browser = content;
    return content;
  };
  // -reload is itself the deferral: it coalesces onto one drain a turn later
  // (MirageBrowserView -_setNeedsRebuildAfterDelay:), so the panel still
  // arrives on time and empty and fills in on the next tick. Asked for
  // unconditionally here - the attach only happens for a popover that is on
  // screen, so there is no stale case to guard, and a guard that could be wrong
  // is what left the gallery blank.
  pc.onDidAttach = ^{
    __strong typeof(weak) s = weak;
    if (s)
      [s->_browser reload];
  };
  _panelController = pc;
  return pc;
}

- (void)_popoverDidOpen:(NSNotification *)note {
  NSNumber *sidebarVisible = note.userInfo[@"sidebarVisible"];
  if (sidebarVisible && !sidebarVisible.boolValue) {
    [_panelController hide];
    return;
  }
  // The browser rides the two popovers where a shader is being worked on:
  // constants (the code editor / controls) and keypose. Both, because the user
  // switches template from either - and because a constants <-> keypose switch
  // happens IN PLACE, with no open notification of its own, so a panel that
  // only knew one of the two would vanish the moment they flipped. The
  // structural popovers - the animated dropdown ("manage"), the lane filter
  // ("filter"), OSC and applies-to - carry no shader and get nothing.
  NSString *kind = note.userInfo[@"kind"];
  if (![kind isEqualToString:@"constants"] &&
      ![kind isEqualToString:@"keypose"]) {
    return;
  }
  NSWindow *popoverWindow = note.userInfo[@"window"];
  NSView *contentView = note.userInfo[@"contentView"];
  // A cold boot can deliver this before the popover has a window at all, and
  // bailing here was one of the two ways the browser failed to appear on the
  // first open. The content view is enough to wait on - it is what acquires the
  // window - so only give up when there is neither.
  if (![popoverWindow isKindOfClass:[NSWindow class]])
    popoverWindow = nil;
  if (!popoverWindow && ![contentView isKindOfClass:[NSView class]]) {
    return;
  }
  NSValue *cardVal = note.userInfo[@"contentRect"];
  NSRect card = cardVal ? cardVal.rectValue : popoverWindow.frame;
  // Attached HERE, in the notification turn, deliberately.
  //
  // This used to be deferred a tick behind a counter bumped by every open AND
  // every close, to keep the panel build off the turn that puts the popover up.
  // The counter cannot tell a close that belongs to THIS popover from one
  // arriving late for the previous one - and the popover instance is reused
  // across opens, so a same-anchor swap runs the outgoing popover's close
  // callback around the incoming open. One late close inside that one tick
  // bumped the counter and the panel silently never appeared again.
  //
  // Nothing is lost by attaching synchronously: the gallery build (the ~300ms
  // that motivated the defer) is coalesced onto its own later drain by
  // -reload, and the panel's own show path already waits for the popover
  // window to be visible before it puts anything on screen.
  [[self _ensurePanelController] openBesideCard:card
                                  popoverWindow:popoverWindow
                             popoverContentView:contentView];
  _attachedContentView = contentView;
}

- (void)_sidebarVisibilityChanged:(NSNotification *)note {
  if (![note.userInfo[@"visible"] boolValue]) {
    [_panelController hide];
    return;
  }
  [self _popoverDidOpen:note];
}

- (void)_popoverDidClose:(NSNotification *)note {
  NSView *closingContent = note.userInfo[@"contentView"];
  if (closingContent && _attachedContentView &&
      closingContent != _attachedContentView)
    return;
  _attachedContentView = nil;
  [_panelController hide];
}

@end
