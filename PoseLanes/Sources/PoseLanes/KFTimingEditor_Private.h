/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFGapGraph.h"
#import "KFKeyposeMap.h"
#import "KFInspectorClock.h"
#import "KFTimingEditor.h"
#import "KFTimingEditorModel.h"
@import InspectorControls;

// Controls and displayed state shared by the timing editor sources. Each
// category declares its own methods in its own header.
@interface KFTimingEditor ()
@property(weak) KFEffect *plugin;
@property(strong) id<PROAPIAccessing> manager;
@property(strong) ICPopUpButton *easingMenu;
@property(strong) ICPopUpButton *motionMenu;
@property(strong) NSButton *available;
@property(strong) NSButton *seedButton;
@property(strong) NSTextField *gapLabel;
@property(strong) NSNumberFormatter *gapTimeFormatter;
@property(strong) NSTextField *motionLabel;
@property(strong) NSTextField *easingLabel;
@property(strong) KFGapGraph *graph;
@property(strong) KFKeyposeMap *map;
@property(strong) ICInspectorRow *durationRow;
@property(strong) ICInspectorRow *motionRow;
@property(strong) id<FxUndoAPI> scrubUndo;
// The host's frame grid, read once: a retimed keypose lands on a frame, and
// the drag path would otherwise pay a host read per pointer event.
@property CMTime frameDuration;
@property CMTime effectStart;
@property UInt32 displayedParameter;
@property BOOL writingSetting;
@property(copy) NSArray<KFInspectorGap *> *plottedGaps;
@property UInt32 plottedParameter;
@property CGSize plottedSize;
// Pointer inside the Added Motion band: those controls write to the active
// gap's source pose, so the map highlights it while they are in use.
@property BOOL motionHovered;
@property(strong) NSTrackingArea *motionTracking;

- (void)publishGraphParameters:(NSSet<NSNumber *> *)parameters;
- (BOOL)motionControlsEngaged;
@end
