/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "Constants.h"
#import "MMDestinations.h"
#import "Plugin_Private.h"
#import <Foundation/Foundation.h>
#import <assert.h>

@interface MockHost
    : NSObject <PROAPIAccessing, FxTimingAPI_v4, FxKeyframeAPI_v3, FxParameterRetrievalAPI_v6,
                FxParameterSettingAPI_v5, FxParameterCreationAPI_v5, FxUndoAPI>
@property NSMutableDictionary *lanes;
@property NSMutableDictionary *blobs;
@property NSMutableDictionary *editors;
@property BOOL linked;
@property(weak) MagicMovePlugin *plugin;
@property NSUInteger mutations;
@property UInt32 failBlobOnce;
@property BOOL failMoveOnce;
@property BOOL failAddOnce;
@property BOOL ignorePluginMoveIndex;
@property BOOL deferCallbacks;
@property NSMutableArray *pendingCallbacks;
@property NSMutableDictionary *definitions;
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
void TestChange(MockHost *h, UInt32 p, double t);
void TestAdd(MockHost *h, UInt32 p, double t, double v);
void TestMove(MockHost *h, UInt32 p, NSUInteger i, double t);
NSData *TestData(MockHost *h, UInt32 p, UInt32 d);
void TestFailedMove(MockHost *h, double t);
void TestLinkPose(MockHost *h, UInt32 editor, double t, BOOL enabled);
void TestRemovePose(MockHost *h, UInt32 property, NSUInteger index, double t);
