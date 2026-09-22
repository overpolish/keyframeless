/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
@import PluginHost;
#import <assert.h>

@interface MockHost
    : NSObject <PROAPIAccessing, FxTimingAPI_v4, FxKeyframeAPI_v3, FxParameterRetrievalAPI_v6,
                FxParameterSettingAPI_v5, FxParameterCreationAPI_v5, FxUndoAPI>
@property NSMutableDictionary *lanes;
@property NSMutableDictionary *blobs;
@property NSMutableDictionary *editors;
@property(weak) KFEffect *plugin;
// Parameters whose reads fail until something registers a value, so a suite can
// check how a caller copes with an unavailable host setting.
@property NSSet<NSNumber *> *strictReadParameters;
@property NSUInteger mutations;
@property UInt32 failBlobOnce;
@property BOOL failMoveOnce;
@property BOOL failAddOnce;
@property BOOL ignorePluginMoveIndex;
@property BOOL deferCallbacks;
@property NSMutableArray *pendingCallbacks;
@property NSMutableDictionary *definitions;
// Parameter IDs in the order the plugin registered them. The Motion template
// generator publishes the visible controls in this order, so a suite can pin
// the inspector layout the host will show.
@property NSMutableArray<NSNumber *> *registrationOrder;
@property NSMutableDictionary *flags;
@property NSMutableDictionary *staticValues;
@property CMTime effectStart;
@property CMTime effectDuration;
@property CMTime frameDuration;
@property NSSet<NSString *> *missingProtocols;
@property UInt32 failReadParameter;
@property NSUInteger hostWrites;
@property NSUInteger nativeKeyReads;
@property NSUInteger undoGroupsStarted;
@property NSUInteger undoGroupsEnded;
@property NSUInteger undoDepth;
@property NSUInteger flagWrites;
@property NSUInteger blobWrites;
- (NSMutableArray *)lane:(NSUInteger)p;
- (BOOL)drainCallbacks;
@end

CMTime TestTime(double t);
