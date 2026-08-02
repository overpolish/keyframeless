/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

#import "MirageRack.h" // MirageRackPreviewMode

NS_ASSUME_NONNULL_BEGIN

/// One box's worth of rack entry, as the strip DRAWS it. Not a model object:
/// everything here is already resolved (the display name is deduped, the symbol
/// is the entry's `#template` category), so the view never reads a timeline.
@interface MirageRackEntry : NSObject
/// The rack registry id. Opaque - the view only ever hands it back.
@property(nonatomic, copy) NSString *entryID;
/// Deduped display name (`MirageRackDedupedDisplayNames`).
@property(nonatomic, copy) NSString *name;
/// SF Symbol for the entry's template category (`MirageCategorySymbol`).
@property(nonatomic, copy) NSString *symbolName;
/// Resolved at the current playhead - an entry whose Enabled lane is animated
/// reads differently from one keypose to the next.
@property(nonatomic) BOOL enabled;
@end

/// The shader rack: the ordered chain of templates this one Mirage instance
/// runs, drawn left to right as a pipeline - a box per entry, an arrow between
/// them - in a strip between the mini viewer and the parameter rows.
///
/// A DUMB renderer. It holds no timeline, mints no ids and decides no order:
/// every box comes in through -applyEntries:selected: and every gesture leaves
/// through a block. The host owns what any of it means, which is what lets the
/// same gesture be one undo entry there and nothing at all here.
@interface MirageShaderRackView : NSView

/// The strip's fixed height. Fixed because the chain grows SIDEWAYS: a
/// ten-shader rack scrolls horizontally rather than taking another line out of
/// the popover.
+ (CGFloat)stripHeight;

/// Replace the boxes. `selectedEntryID` may name an entry that is gone (the one
/// just removed), in which case nothing is highlighted. `previewMode` /
/// `previewEntryID` are the mini viewer's session-only chain preview, drawn as
/// an accent-tinted button on the box it is about - the view does not own that
/// state any more than it owns the selection.
///
/// `nonSelectableEntryIDs` are the boxes that cannot be selected right now -
/// with a keypose popover open, the entries carrying no keypose at its time.
/// They fade the way a bypassed entry does, swallow the click that would select
/// them, and carry `reason` as their tooltip. Everything ELSE on such a box
/// still works: bypass, preview and remove are not edits of the moment the
/// popover is on. Empty / nil = every box selectable, which is the state
/// between popovers. Pushed WITH the boxes rather than set alongside them, so
/// there is no tick where the strip has one and not the other.
- (void)applyEntries:(NSArray<MirageRackEntry *> *)entries
            selected:(nullable NSString *)selectedEntryID
         previewMode:(MirageRackPreviewMode)previewMode
        previewEntry:(nullable NSString *)previewEntryID
       nonSelectable:(nullable NSSet<NSString *> *)nonSelectableEntryIDs
              reason:(nullable NSString *)reason;

/// Whether the chain is MEASURED to be rendering slower than real time right
/// now: a warning glyph at the strip's trailing edge, with a tooltip saying so.
/// Display state and nothing else - no lane, no parameter, no undo entry - and
/// pushed in like everything else here, since the view has no way to time a
/// render of its own. The host only ever sets it for a real chain: one shader
/// that is slow is just a slow shader, and this warning is about the chain.
@property(nonatomic) BOOL renderingSlowerThanRealTime;

/// A box was clicked. Selection is session UI state - the host stores it, and
/// this phase does nothing else with it.
@property(nonatomic, copy, nullable) void (^onSelectEntry)(NSString *entryID);
/// The box's on/off control was clicked. `enabled` is the state being asked
/// for, not the one being shown.
@property(nonatomic, copy, nullable) void (^onSetEntryEnabled)
    (NSString *entryID, BOOL enabled);
/// A box was dragged along the chain. `index` is the drop line's position in
/// the CURRENT order - the slot it was inserted BEFORE, counted before the box
/// is lifted out (`MirageRackReorderedEntryIDs` applies the shift).
@property(nonatomic, copy, nullable) void (^onMoveEntry)
    (NSString *entryID, NSInteger index);
/// The bin on one of the chain's boxes. Present on EVERY box once there is
/// more than one entry - a single-entry rack has nothing to remove into.
@property(nonatomic, copy, nullable) void (^onRemoveEntry)(NSString *entryID);
/// One of the box's two preview buttons was clicked. `mode` is the one being
/// asked for - never `Off`, since the host is what decides that clicking the
/// mode already running turns it off. Nothing here writes: the preview is
/// session state and Final Cut's viewer keeps showing the whole chain.
@property(nonatomic, copy, nullable) void (^onSetPreviewMode)
    (NSString *entryID, MirageRackPreviewMode mode);
/// The "+" at the end of the chain. `sourceView` is the button, to anchor the
/// template browser to.
@property(nonatomic, copy, nullable) void (^onAddTapped)(NSView *sourceView);

@end

NS_ASSUME_NONNULL_END
