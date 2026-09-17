/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
#import "KFInspectorClock.h"

// Posted when the inspector's selection or graphed properties change, so rows
// and panels can update their presentation without polling.
FOUNDATION_EXPORT NSNotificationName const KFInspectorPresentationChanged;

// Base class for an FxPlug effect: the API manager, document attachment, the
// inspector state the views read, one refresh clock and one main-run-loop tick.
// Subclasses declare the FxPlug protocols and provide rendering, parameter
// registration and view construction.
@interface KFEffect : NSObject
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)manager;
// FxPlug guarantees host API readiness only after document attachment, so
// timers and cache publishing start here rather than at parameter creation.
- (void)pluginInstanceAddedToDocument;
// The host's parameter-changed callback. The base implementation accepts the
// change; subclasses answer for their own parameters.
- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error;

// Frame dimensions the inspector converts percent-of-image values to pixels
// with, measured from the image callbacks.
@property(atomic) CGSize inspectorImageSize;
// Measures the frame from one image callback. `deliveredPixels` is the size of
// the image the host actually handed over, which is the precision of the
// measurement: the host renders previews and thumbnails of the same frame at
// its own scales and rounds their bounds to whole pixels, so scaling an 84
// pixel thumbnail back up places the frame no better than about 2%. A coarse
// measurement therefore never displaces a finer one, and only a size further
// out than both measurements' rounding can explain counts as a new frame.
- (void)publishInspectorImageSize:(CGSize)size measuredFrom:(CGSize)deliveredPixels;
@property(atomic) UInt32 activeInspectorParameterID;
@property(atomic, copy) NSSet<NSNumber *> *graphedInspectorParameters;

// On-screen control visibility toggles, if the effect has any. The playhead
// nudge stays silent when every one of them is off.
@property(nonatomic, copy) NSArray<NSNumber *> *onScreenControlVisibilityParameters;

// Lazily created; one shared 10Hz refresh clock for this instance's views. It
// also carries the playhead nudge that brings on-screen controls back.
- (KFInspectorClock *)inspectorClock;

// Repeats `tick` on the main run loop inside a host action, at the rate the
// host's own keyframe editing needs. One timer per effect; later calls are
// ignored. Default run loop only: a host action opened inside an AppKit
// tracking loop is what the menu paths deliberately avoid.
- (void)startHostTicks:(void (^)(id<FxCustomParameterActionAPI_v4> action))tick;
@end
