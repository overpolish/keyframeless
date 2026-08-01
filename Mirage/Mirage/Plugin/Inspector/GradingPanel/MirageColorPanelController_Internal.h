/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKFloatingPanel.h>
#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKPaddedScrollView.h>

#import "MirageColorPanelController.h"
#import "MirageColorSurfaceProps.h"
#import "MirageInspectorChrome.h"
#import "MirageScopeSampler.h"
#import "MirageSurfaceCircleView.h"
#import "MirageSurfaceResponse.h"

static const CGFloat kReadoutFontSize = 11.0;

// Defined in +Readout.m and +PuckWrite.m respectively, and exported rather than
// static because each of them is read from a category that does not own it.
FOUNDATION_EXPORT NSString *_Nullable MirageDeclarationSentence(
    MirageMemoryColor kind, NSPoint cast);
FOUNDATION_EXPORT NSString *_Nonnull MirageReadoutPlaceholder(void);
FOUNDATION_EXPORT BOOL MirageResponseBelongsToPuck(
    MirageSurfaceResponse r, NSString *_Nullable puckName);

NS_ASSUME_NONNULL_BEGIN

@interface MirageColorPanelController () {
@package
  KKFloatingPanel *_panel;
  NSWindow *_parentWindow;
  NSView *_popoverContentView;
  NSRect _openCard;
  /// The fraction the popover reported at open. A fallback only - see
  /// -_editFraction, which is what everything actually reads.
  double _openFraction;
  /// Control values as they stood when the drag began, keyed by lane key. The
  /// puck writes absolute positions, so these are not what the new values are
  /// computed from - they supply the "before" number in the readout, and a
  /// colour's own saturation and brightness while only its hue is being driven.
  NSDictionary<NSString *, NSArray<NSNumber *> *> *_dragStartValues;
  /// YES between onDragBegin and its onDragEnd. The host wraps those in an undo
  /// group, and FCP RAISES from FFChannelAction lockChannels if a second group
  /// opens inside the first - so this is a structural guard, not bookkeeping: a
  /// begin can never fire twice without an intervening end.
  BOOL _writeGroupOpen;
  /// YES while a puck drag is in progress. Separate from _writeGroupOpen
  /// because the panel's other writes (recentre, eyedropper) open the same
  /// group without being a gesture that can lose its mouse-up.
  BOOL _puckDragActive;
  NSUInteger _puckDragIndex;
  /// Which declared surface the open drag belongs to, so the log names the ring
  /// and the OTHER ring's view can be dropped without touching this one.
  NSUInteger _puckDragRing;
  /// The source the ring and axis labels were last built from, so a recompile
  /// rebuilds them and an unchanged frame does not re-parse every tick.
  NSString *_lastSpecSource;
  /// The declared rings, in declaration order: index 0 is the circle on top.
  NSArray<NSNumber *> *_ringKinds;
  __weak KKTimelineLanesView *_lanesView;
  /// One circle per surface the grammar allows, built once and shown as the
  /// source asks. Built up front rather than on demand because a recompile can
  /// add a ring under an open panel, and rebuilding the hierarchy there would
  /// tear down the very view a latched drag is still holding.
  NSArray<MirageSurfaceCircleView *> *_circles;
  /// The container both circles live in. Sized by -_applyPanelLayout, which is
  /// the only thing in this panel that sets a frame.
  NSView *_well;
  NSView *_body;
  KKPanelDragHandleView *_header;
  KKPaddedScrollView *_readoutScroll;
  NSStackView *_readoutStack;
  NSTextField *_readoutHint;
  NSButton *_pickButton;
  NSButton *_pickColorButton;
  /// Arms the click-to-pick gesture: one click in the preview aims the ACTIVE
  /// puck's `pick=` controls at whatever colour was clicked.
  NSButton *_pickSourceButton;
  /// Adds an instance of the shader's `#slots` group, and removes the selected
  /// one. Hidden entirely for a shader that declares no repeatable group, which
  /// is every shader written before the directive existed.
  NSButton *_addSlotButton;
  NSButton *_removeSlotButton;
  /// Which of the in-well row's three buttons were showing when the panel was
  /// last laid out, as a bitmask. The row's HEIGHT is a function of that set,
  /// and the well and the panel are sized around it - so the set changing is a
  /// re-layout rather than a re-frame, while the refresh that computes it runs
  /// on every sampled frame. Starts at -1: no mask, not "all hidden".
  NSInteger _wellRowMask;
  /// Whether the matte is showing, for THIS popover session. Not a lane and not
  /// persisted - it says what is on screen right now, the way
  /// `compareSplitEnabled` does, and it resets when the popover closes.
  ///
  /// PUSHED IN, and owned by the mini viewer's compare row: the switch lives
  /// with the preview, where every template has one, and the panel only
  /// composes it with the active key (see -_pushPreviewOverrides, which asserts
  /// both).
  BOOL _showSelectionActive;
  /// Armed: the next click in the mini viewer picks the reference patch.
  BOOL _picking;
  /// What the next picked patch is declared to be. An ivar rather than a
  /// default: it is a statement about THIS shot, so a fresh popover starts at
  /// Neutral rather than silently measuring a face against grass someone
  /// sampled last week.
  MirageMemoryColor _pickDeclaration;
  /// The plain-language reading of the current declared pick, or nil. Held so
  /// it can be CLEARED - a sentence describing a cast that has since been
  /// corrected is worse than no sentence at all.
  NSString *_declarationSentence;
  /// Armed: the next click picks a colour for the shader's `pick=` controls.
  /// Only one of the two can be armed - they consume the same click and mean
  /// different things by it, so arming either disarms the other.
  BOOL _pickingColor;
  /// A colour pick that has been clicked but not yet measured. The patch is
  /// read out of the next rendered frame, which may not have arrived when the
  /// click did.
  BOOL _pendingColorPick;
  /// A measured pick whose write has been scheduled but not performed yet. A
  /// second pick cannot be clicked in that window, but the sampler can satisfy
  /// the same pending pick twice if a frame lands between the two, and two
  /// writes racing into one action scope is the shape of the crash this defers
  /// around.
  BOOL _pickWriteInFlight;
  /// Armed: the next click in the preview reads the SOURCE pixel under it and
  /// aims the active puck's `pick=` controls at that colour. A third armed
  /// state rather than a mode on the eyedropper, since the three consume the
  /// same click and mean different things by it - arming any one disarms the
  /// others.
  BOOL _pickingSource;
  id _pickMonitor;
  id _pickGlobalMonitor;
  /// While armed, the pointer over the preview says so. The mini viewer's own
  /// cursor rects never fire for it inside a ViewBridge popover, so the cursor
  /// is pushed from the same monitor stream every other gesture in this panel
  /// is driven by.
  id _pickCursorMonitor;
  id _pickCursorGlobalMonitor;
  /// Escape disarms. Local and global for the reason the click monitors are
  /// both: a popover this panel does not own gets the key events, and neither
  /// monitor alone sees the whole stream.
  id _pickKeyMonitor;
  id _pickKeyGlobalMonitor;
  MirageScopeSampler *_sampler;
  __weak KKMiniViewerView *_measuredMini;
  NSTimeInterval _lastSampleTime;
  BOOL _samplePending;
  /// When the previous puck-drag tick started, so the log reports the rate the
  /// gesture is actually managing rather than only the cost of one write.
  /// The timeline the LAST tick of the open drag computed, held until the drag
  /// ends and it becomes the gesture's one write. Nil when nothing has moved,
  /// so a drag that never left the spot commits nothing at all.
  KKTimeline *_pendingPuckCommit;
  /// What that same tick would have committed, keyed by lane. Read by
  /// -_valuesForLane: so the readout, the derive and the preview are all
  /// describing the position under the cursor rather than the one the timeline
  /// still holds. Dropped with the renderer's overrides when the drag ends.
  NSDictionary<NSString *, NSArray<NSNumber *> *> *_liveDragValues;
  /// The preview overrides as they currently stand in the renderer - the key
  /// number, whether the matte is showing, and the fraction they were keyed at.
  /// Nil for "nothing pushed".
  ///
  /// Not a cache of a value that lives elsewhere: it is the record of what was
  /// asserted, and it exists so the assert can be a no-op when nothing moved.
  /// Pushing sets the preview needing display, and the push site runs on every
  /// sampled frame - which is itself driven by frames - so an unconditional
  /// push would be a redraw loop that never settles.
  NSNumber *_pushedActiveKey;
  BOOL _pushedSelection;
  double _pushedActiveKeyFraction;
}

- (void)_showIfPopoverOpen;
- (void)_showIfPopoverOpenAttempt:(NSInteger)attempt;
- (BOOL)_resolveSurfaceEnabledFromLanes;
- (NSSet<NSString *> *)_drivableKeysIn:(KKTimeline *)timeline
                              fraction:(double)frac;
- (double)_editFraction;
- (NSArray<NSNumber *> *)_valuesForLane:(KKLane *)lane fraction:(double)frac;
- (void)_startSampling;
- (void)_stopSampling;
- (void)_frameReady;
- (void)_sampleOnce;
- (void)_popoverDidOpen:(NSNotification *)note;
- (void)_popoverDidClose:(NSNotification *)note;

@end

// Panel construction, the ring set the panel is sized from, and every frame in
// it. Implemented in MirageColorPanelController+Layout.m.
@interface MirageColorPanelController (Layout)
- (NSUInteger)_ringCount;
- (MirageColorSurfaceRing)_ringAtIndex:(NSUInteger)index;
- (nullable MirageSurfaceCircleView *)_hueCircle;
- (void)_applyPanelLayout;
- (void)_applySurfaceSpecIfChanged:(NSString *)source;
- (void)_pushSurfaceSpec;
- (void)_resolveRingsFromLanes;
- (_MirageFirstMouseButton *)_iconButtonNamed:(nullable NSString *)symbol
                                        label:(nullable NSString *)label
                                       action:(nullable SEL)action;
- (_MirageFirstMouseButton *)_headerButtonWithAction:(SEL)action;
- (void)_layoutHeaderButtons;
- (KKFloatingPanel *)_ensurePanel;
@end

// The strip of buttons inside the well: what it is made of, how tall it is and
// where its buttons sit. Implemented in MirageColorPanelController+WellRow.m.
@interface MirageColorPanelController (WellRow)
- (void)_buildWellRowInWell:(NSView *)well;
- (CGFloat)_wellRowHeight;
- (void)_layoutWellRowInRect:(NSRect)row;
@end

// The three armed picks, their monitors and the writes they schedule.
// Implemented in MirageColorPanelController+Picking.m.
@interface MirageColorPanelController (Picking)
- (void)_showPickMenu:(id)sender;
- (void)_choosePickDeclaration:(NSMenuItem *)item;
- (void)_armPicking;
- (void)_toggleColorPicking:(id)sender;
- (void)_togglePickFromClip:(id)sender;
- (void)_installPickMonitors;
- (void)_updatePickCursor;
- (void)_disarmPicking;
- (BOOL)_handlePickEvent:(NSEvent *)event;
- (void)_pickFromSourceAtUV:(NSPoint)uv inMini:(KKMiniViewerView *)mini;
- (void)_schedulePickWrite:(NSArray<NSNumber *> *)rgb
            activePuckOnly:(BOOL)activePuckOnly;
- (void)_applyPickedRGB:(NSArray<NSNumber *> *)rgb
         activePuckOnly:(BOOL)activePuckOnly;
- (BOOL)_hasDrivablePicksIn:(KKTimeline *)timeline source:(NSString *)source;
- (void)_refreshHeaderButtonTitlesIn:(KKTimeline *)timeline
                              source:(NSString *)source;
- (NSArray<NSString *> *)_pickTargetLabelsIn:(KKTimeline *)timeline
                                      source:(NSString *)source;
- (NSUInteger)_pickRingIndex;
- (NSDictionary<NSString *, NSNumber *> *)
    _picksForActivePuckIn:(KKTimeline *)timeline
                   source:(NSString *)source;
@end

// The write-group lifecycle, the puck drag it brackets, and the apply/derive
// pair. Implemented in MirageColorPanelController+PuckWrite.m.
@interface MirageColorPanelController (PuckWrite)
- (void)_focusLeftPanel:(NSNotification *)note;
- (void)_windowResignedKey:(NSNotification *)note;
- (void)_resetMappedControlsForPuck:(NSUInteger)puckIndex
                               ring:(NSUInteger)ringIndex;
- (void)_beginWriteGroup:(NSString *)reason;
- (void)_endWriteGroup:(NSString *)reason;
- (void)_pushLivePreviewValues:
    (NSDictionary<NSString *, NSArray<NSNumber *> *> *)values;
- (void)_clearLivePreviewValues;
- (void)_pushPreviewOverrides;
- (NSInteger)_activeKeyNumber;
- (void)_redrawPreview;
- (void)_beginPuckDrag:(NSUInteger)puckIndex ring:(NSUInteger)ringIndex;
- (void)_endPuckDragReason:(NSString *)reason;
- (void)_endPuckDragReason:(NSString *)reason keepingRing:(NSUInteger)keepRing;
- (nullable NSString *)_puckNameAtIndex:(NSUInteger)index
                                   ring:(NSUInteger)ringIndex
                                 source:(NSString *)source;
- (MirageSurfaceAxisSet)_axesForPuck:(NSString *)puckName
                           responses:
                               (NSDictionary<NSString *, NSValue *> *)responses
                            drivable:(NSSet<NSString *> *)drivable;
- (void)_applyPuckTo:(NSPoint)position
                puck:(NSUInteger)puckIndex
                ring:(NSUInteger)ringIndex;
- (void)_refreshPuck;
- (NSPoint)_derivePositionForPuck:(NSString *)puckName
                         timeline:(KKTimeline *)timeline
                        responses:
                            (NSDictionary<NSString *, NSValue *> *)responses
                         drivable:(NSSet<NSString *> *)drivable
                            polar:(BOOL)polar
                         fraction:(double)frac;
@end

// `#slots`: the crossing from what the source declares to what this project has
// stamped, and the add/remove pair that changes it. Implemented in
// MirageColorPanelController+Slots.m.
@interface MirageColorPanelController (Slots)
- (NSDictionary<NSString *, NSValue *> *)_responsesForRing:(NSUInteger)ringIndex
                                                    source:(NSString *)source;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)
    _pucksForRing:(NSUInteger)ringIndex
           source:(NSString *)source;
- (NSDictionary<NSString *, NSNumber *> *)_picksInSource:(NSString *)source;
- (NSDictionary<NSString *, NSString *> *)_puckNamesInSource:(NSString *)source;
- (nullable NSString *)_addableSlotGroupInSource:(NSString *)source;
- (nullable NSDictionary<NSString *, NSString *> *)_activeSlotPuckInSource:
    (NSString *)source;
- (void)_selectSlotPuckForInstance:(nullable NSString *)instanceID
                            source:(NSString *)source;
- (void)_addSlotInstance:(nullable id)sender;
- (void)_removeSlotInstance:(nullable id)sender;
- (void)_refreshSlotButtonsIn:(nullable KKTimeline *)timeline
                       source:(NSString *)source;
@end

// What the readout says: the rows, the empty state and the declaration
// sentence. Implemented in MirageColorPanelController+Readout.m.
@interface MirageColorPanelController (Readout)
- (void)_setReadoutRows:(NSArray<NSDictionary<NSString *, id> *> *)rows;
- (void)_setDeclarationSentence:(nullable NSString *)sentence;
- (void)_refreshReadout;
@end

NS_ASSUME_NONNULL_END
