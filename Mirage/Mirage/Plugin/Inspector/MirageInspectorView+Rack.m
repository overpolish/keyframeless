/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The shader rack strip between the mini viewer and the parameter rows: what
// the boxes say, and the session-only chain preview they arm.
//
// The strip is a dumb renderer - it is handed a row array and paints it. What
// the user can DO to the chain lives in MirageInspectorView+RackMutations.m,
// and which entry is selected in MirageInspectorView+RackSelection.m.

#import "MirageInspectorView_Private.h"

#import "Constants.h"
#import "MirageCategory.h"
#import "MirageInspectorChrome.h" // MirageFindMiniViewer
#import "MirageLocalCatalog.h"
#import "MirageLocalized.h"
#import "MirageRack.h"
#import "MirageShaderRackView.h"

#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKPluginInstanceState.h>
#import <KeyframelessKit/KKPopoverKeepAlive.h>

@implementation MirageInspectorView (Rack)

// One strip per popover: the popover owns the view and drops it on close, so
// `_rackView` is weak and the next open builds a fresh one. Populated here
// rather than by the caller - by the time the popover asks, the lanes view is
// holding the timeline the chain is derived from.
- (NSView *)buildRackStrip {
  MirageShaderRackView *rack =
      [[MirageShaderRackView alloc] initWithFrame:NSZeroRect];
  __weak typeof(self) weak = self;
  rack.onSelectEntry = ^(NSString *entryID) {
    [weak _rackSelectEntry:entryID persist:YES];
  };
  rack.onSetEntryEnabled = ^(NSString *entryID, BOOL enabled) {
    [weak _rackSetEntry:entryID enabled:enabled];
  };
  rack.onMoveEntry = ^(NSString *entryID, NSInteger index) {
    [weak _rackMoveEntry:entryID toIndex:index];
  };
  rack.onRemoveEntry = ^(NSString *entryID) {
    [weak _rackRemoveEntry:entryID];
  };
  rack.onAddTapped = ^(NSView *sourceView) {
    [weak _rackAddFromView:sourceView];
  };
  rack.onSetPreviewMode = ^(NSString *entryID, MirageRackPreviewMode mode) {
    [weak _rackSetPreviewMode:mode entry:entryID];
  };
  _rackView = rack;
  // A new popover is a new session, and the preview always starts on the whole
  // chain - the same fresh start the compare row's split and matte get by being
  // torn down with the view they live on.
  [self _rackSetPreviewMode:MirageRackPreviewModeOff entry:nil];
  [self _observeKeyposePopoverLifecycle];
  [self refreshRack];
  return rack;
}

// The strip is the popover's own accessory, so it is BUILT while the popover is
// still being presented - the lanes view hasn't recorded which keypose it is on
// yet, and -openKeyposePopoverLayerKeys therefore answers "none open" to the
// refresh above. The open signal is what fires once that state is real. An
// in-place keypose <-> constants switch keeps the same strip and never reopens,
// so it announces itself on the NAVIGATE signal instead - the same one arrowing
// between keyposes uses. Scoped to THIS inspector's lanes view by
// `object`, the way the compare row and the browser scope theirs. Re-registered
// per strip, so the remove is what keeps a second popover from doubling it.
- (void)_observeKeyposePopoverLifecycle {
  NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
  for (NSNotificationName name in @[
         KKStaticValuesPopoverDidOpenNotification,
         KKStaticValuesPopoverDidCloseNotification,
         // Arrowing between keyposes keeps the popover open but moves its
         // time, and the gray set is a function of that time.
         KKStaticValuesPopoverDidNavigateNotification
       ]) {
    [nc removeObserver:self name:name object:self.basicLanesView];
    [nc addObserver:self
           selector:@selector(_keyposePopoverLifecycleChanged:)
               name:name
             object:self.basicLanesView];
  }
}

- (void)_keyposePopoverLifecycleChanged:(NSNotification *)note {
  // Rack preview is panel chrome, not project state. If the panel closes while
  // Solo / Up to Here is armed, restore both viewers immediately instead of
  // leaving Final Cut's main viewer on a preview with no visible way to clear
  // it. Navigation/open notifications only need the ordinary rack refresh.
  if ([note.name isEqualToString:KKStaticValuesPopoverDidCloseNotification]) {
    [self _rackSetPreviewMode:MirageRackPreviewModeOff entry:nil];
    return;
  }
  [self refreshRack];
}

- (void)refreshRack {
  // The ordinary state between popovers, not a fault: the strip lives in the
  // popover, so there is nothing to refresh while it is closed.
  if (!_rackView)
    return;
  KKTimeline *timeline = self.basicLanesView.currentTimeline;
  if (!timeline)
    return;
  NSArray<NSString *> *entryIDs = MirageRackEntryIDs(timeline);
  NSArray<MirageRackEntry *> *rows = [self _rackRowsForTimeline:timeline
                                                       entryIDs:entryIDs];
  [self _reconcileRackSelectionAgainstEntryIDs:entryIDs];

  NSString *selected = self.selectedRackEntryID ?: entryIDs.firstObject;
  NSSet<NSString *> *blocked = [self _nonSelectableRackEntriesAmong:entryIDs
                                                           selected:selected];
  NSString *reason =
      blocked.count
          ? RLoc(@"No keypose at the current frame",
                 @"Mirage rack: tooltip on a grayed shader box while a keypose "
                 @"popover is open on a time that shader has no keypose at.")
          : nil;

  [_rackView applyEntries:rows
                 selected:selected
              previewMode:_rackPreviewMode
             previewEntry:_rackPreviewEntryID
            nonSelectable:blocked
                   reason:reason];
}

// One box's worth of display state per entry, in chain order. Everything here
// is derived - the name from the code lane's save name, the glyph from what the
// source parses as, the tick from the Enabled lane at the playhead - so a row
// array is a snapshot the strip can paint without asking anything back.
- (NSArray<MirageRackEntry *> *)_rackRowsForTimeline:(KKTimeline *)timeline
                                            entryIDs:(NSArray<NSString *> *)
                                                         entryIDs {
  NSString *fallback =
      RLoc(@"Shader", @"Generic GLSL code lane display name (the code editor's "
                      @"caption).");
  NSArray<NSString *> *displayNames = MirageRackDisplayNames(
      timeline, entryIDs, kMirageCodeLaneLabel, fallback);
  double frac = [self playheadFractionForRack];
  NSMutableArray<MirageRackEntry *> *rows =
      [NSMutableArray arrayWithCapacity:entryIDs.count];
  for (NSUInteger i = 0; i < entryIDs.count; i++) {
    NSString *entryID = entryIDs[i];
    MirageRackEntry *row = [[MirageRackEntry alloc] init];
    row.entryID = entryID;
    row.name = displayNames[i];
    NSString *source =
        MirageRackCodeLaneForEntry(timeline, entryID, kMirageCodeLaneLabel)
            .codeString;
    row.symbolName = MirageCategorySymbol(MirageCategoryForSource(
        source.length ? source : MirageCustomDefaultShaderSource()));
    row.enabled = MirageRackEntryEnabledAtFraction(timeline, entryID, frac);
    [rows addObject:row];
  }
  return rows;
}

// The selection and the preview, healed against the registry in hand. Both can
// be pointing at an entry the timeline no longer describes (or does not
// describe YET), and neither is allowed to leave the strip talking about
// nothing.
- (void)_reconcileRackSelectionAgainstEntryIDs:(NSArray<NSString *> *)entryIDs {
  // A selection the host restored ahead of the blob that describes it: the
  // registry has caught up now, so adopt it before the fallback below can call
  // it stale. Memory only - the value came out of the param.
  if (_pendingRackSelectionID.length &&
      [entryIDs containsObject:_pendingRackSelectionID]) {
    NSString *pending = _pendingRackSelectionID;
    _pendingRackSelectionID = nil;
    [self _rackSelectEntry:pending persist:NO];
  }
  // A selection pointing at an entry that is gone (the one just removed, or a
  // blob from an undo) falls back to the first, so the rack is never talking
  // about nothing. NOT persisted: nobody asked for this move, and writing it
  // would put a phantom entry on the undo stack right behind the one the user
  // is walking back through.
  if (self.selectedRackEntryID.length &&
      ![entryIDs containsObject:self.selectedRackEntryID])
    [self _rackSelectEntry:entryIDs.firstObject persist:NO];
  // A preview pointing at an entry that is gone would truncate the chain with
  // no button anywhere to say so, so it goes back to the whole chain.
  if (_rackPreviewEntryID.length &&
      ![entryIDs containsObject:_rackPreviewEntryID])
    [self _rackSetPreviewMode:MirageRackPreviewModeOff entry:nil];
}

// A keypose popover edits ONE moment, so the entries with no keypose there are
// not selectable for as long as it is up - the same gate -_rackSelectEntry:
// persist: refuses the click on, drawn. The kit names the entries that CAN be
// edited and returns an empty set when no keypose popover is open, which is the
// ordinary state and grays nothing.
- (NSSet<NSString *> *)_nonSelectableRackEntriesAmong:
                           (NSArray<NSString *> *)entryIDs
                                             selected:(NSString *)selected {
  NSSet<NSString *> *editable =
      [self.basicLanesView openKeyposePopoverLayerKeys];
  if (!editable.count)
    return nil;
  NSMutableSet<NSString *> *blocked = [NSMutableSet set];
  for (NSString *entryID in entryIDs)
    if (![editable containsObject:entryID] &&
        ![entryID isEqualToString:selected ?: @""])
      [blocked addObject:entryID];
  return blocked;
}

// Both viewers' chain preview. NOT a write: no lane, no parameter, no undo
// entry and nothing persisted. It rides the same per-instance session state as
// the compare row's split and matte, so compact mode can show the result in
// Final Cut's main viewer while the mini stays in exact sync.
//
// One mode at a time across the whole rack: arming either one on any box
// disarms whatever was running, and asking for the mode already running on that
// box turns it off.
- (void)_rackSetPreviewMode:(MirageRackPreviewMode)mode
                      entry:(NSString *)entryID {
  BOOL same = (mode == _rackPreviewMode) &&
              [(entryID ?: @"") isEqualToString:_rackPreviewEntryID ?: @""];
  MirageRackPreviewMode next = (mode == MirageRackPreviewModeOff || same)
                                   ? MirageRackPreviewModeOff
                                   : mode;
  NSString *nextEntry = (next == MirageRackPreviewModeOff) ? nil : entryID;
  BOOL localUnchanged =
      next == _rackPreviewMode &&
      [(nextEntry ?: @"") isEqualToString:_rackPreviewEntryID ?: @""];
  KKPluginInstanceState *session = KKInstanceStateForAPI(_thumbAPIManager);
  BOOL sharedUnchanged = session.mirageRackPreviewMode == next &&
                         [(session.mirageRackPreviewEntryID
                               ?: @"") isEqualToString:nextEntry ?: @""];
  if (localUnchanged && sharedUnchanged)
    return;
  _rackPreviewMode = next;
  _rackPreviewEntryID = [nextEntry copy];
  _miniViewerRenderer.rackPreviewMode = next;
  _miniViewerRenderer.rackPreviewEntryID = nextEntry;
  session.mirageRackPreviewMode = next;
  session.mirageRackPreviewEntryID = nextEntry;
  // The preview is a PAUSED Metal view, so it holds its last frame until
  // someone marks it.
  [MirageFindMiniViewer(_rackView.window.contentView ?: _rackView)
      setNeedsDisplay:YES];
  // A session-state change does not itself invalidate Final Cut's cached
  // frame. Use the same non-undo render nudge as the main-viewer compare row.
  if (self.onBoundaryPreviewNeedsRender)
    self.onBoundaryPreviewNeedsRender();
  // Re-drives the boxes so the tint - and which boxes carry the pair at all -
  // follows the mode. Cannot recurse: the entry it just stored is one the
  // registry holds, and clearing stores none at all.
  [self refreshRack];
}

- (double)playheadFractionForRack {
  return _playheadFraction;
}

@end
