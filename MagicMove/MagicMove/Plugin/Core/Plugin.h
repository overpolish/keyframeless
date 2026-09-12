/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Per-parameter cache and editor state; the host persists each lane separately.
@interface MMTimingLane : NSObject
@property(nonatomic) UInt32 valueID;
@property(nonatomic) UInt32 durationID;
@property(nonatomic) UInt32 dataID;
@property(nonatomic) UInt32 availableTimeID;
@property(nonatomic) UInt32 easingID;
@property(nonatomic) UInt32 addedMotionID;
@property(nonatomic, copy) NSNumber *publishedAddedMotion;
@property(nonatomic, copy) NSNumber *addedMotionEnabled;
@property(atomic, copy) NSNumber *publishedEasing;
@property(nonatomic) UInt32 linkEditorID;
@property(nonatomic) UInt32 matchEditorID;
@property(nonatomic) BOOL matchEnabled;
@property(atomic, copy) NSNumber *publishedMatch;
@property(atomic, copy) NSData *durationSnapshot;
@property(atomic, copy) NSData *publishedDestinations;
@property(atomic) NSUInteger durationGeneration;
// In-memory associations while native editing is active; no host writes.
@property(atomic, copy) NSData *pendingDestinations;
@property(atomic) CMTime pendingTime;
@property(nonatomic) BOOL durationEditorKnown;
@property(nonatomic) BOOL durationEditorEnabled;
@property(nonatomic) BOOL editorAvailableTime;
@property(nonatomic) BOOL linkEditorEnabled;
@property(nonatomic) BOOL linkEditorValue;
@property(nonatomic) double durationEditorValue;
// Last successful transient host writes survive snapshot/display invalidation.
// Delayed notifications for these values are display echoes, not user edits.
@property(atomic, copy) NSNumber *publishedLinkValue;
@property(atomic, copy) NSNumber *publishedAvailableValue;
@property(atomic, copy) NSNumber *publishedDurationValue;
- (void)publishDurationSnapshot:(NSData *)data generation:(NSUInteger)generation;
@end

@class MMLinkEdit;

@interface MagicMovePlugin : KKPlugin <FxTileableEffect, FxCustomParameterViewHost_v2>
@property(atomic) BOOL syncingDuration;
@property(atomic) NSUInteger activeNativeCallbacks;
@property(atomic) BOOL hasPendingNativeEdits;
@property(atomic, strong) MMLinkEdit *pendingLinkEdit;
@property(nonatomic, strong) NSTimer *durationTimer;
@property(nonatomic, copy) NSNumber *publishedCombinedEasing;
@property(nonatomic, copy) NSNumber *combinedEasingEnabled;
@property(nonatomic, copy) NSNumber *publishedCombinedAddedMotion;
@property(nonatomic, copy) NSNumber *combinedAddedMotionEnabled;
@property(nonatomic, copy, readonly) NSArray<MMTimingLane *> *timingLanes;
- (void)startDurationRefresh;
- (void)refreshDurationAtTime:(CMTime)time;
@end
