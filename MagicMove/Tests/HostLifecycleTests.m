/* SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MMParameterData.h"

static void DrainMainQueue(void) {
  [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
int main(void) {
  @autoreleasepool {
    MagicMovePlugin *plugin;
    __weak MockHost *weakHost;
    @autoreleasepool {
      MockHost *host=[MockHost new]; weakHost=host;
      plugin=[[MagicMovePlugin alloc] initWithAPIManager:host];
      assert(plugin.apiManager==host);
      assert(plugin.durationTimer==nil); // Detached library/drag instances stay idle.
    }
    assert(weakHost==nil && plugin.apiManager==nil);
    [plugin pluginInstanceAddedToDocument]; DrainMainQueue();
    NSTimer *timer=plugin.durationTimer;
    assert(timer && timer.valid);
    [plugin pluginInstanceAddedToDocument]; DrainMainQueue();
    assert(plugin.durationTimer==timer); // Repeated attachment cannot duplicate polling.
    __weak MagicMovePlugin *weakPlugin=plugin; plugin=nil;
    assert(weakPlugin==nil && !timer.valid);

    plugin=[[MagicMovePlugin alloc] initWithAPIManager:nil];
    assert([plugin createViewForParameterID:UINT32_MAX]==nil);
    assert([plugin classesForCustomParameterID:UINT32_MAX].count==0);
    FxRect rect={0}; NSError *error=nil;
    assert(![plugin destinationImageRect:&rect sourceImages:@[] destinationImage:[FxImageTile new]
      pluginState:nil atTime:kCMTimeZero error:&error]);
    assert(error);

    // This fixture was encoded by the real v1 framework, not this implementation.
    NSString *fixtures=[[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Fixtures"];
    NSData *archive=[NSData dataWithContentsOfFile:[fixtures stringByAppendingPathComponent:@"LegacyTimingBlob.archive"]];
    assert(archive.length>0); error=nil;
    KKDataBlob *decoded=[NSKeyedUnarchiver unarchivedObjectOfClass:KKDataBlob.class fromData:archive error:&error];
    assert(decoded && !error && [decoded.stringValue isEqualToString:@"[{\"time\":2,\"duration\":0.3}]"]);
    NSMutableData *mutable=[decoded.data mutableCopy];
    KKDataBlob *blob=[KKDataBlob blobWithData:mutable]; [mutable setLength:0];
    assert([blob isEqual:decoded] && blob.hash==decoded.hash);
    assert([[blob copy] isEqual:blob]);
    KKDataBlob *right=[KKDataBlob blobWithString:@"right"];
    id<FxCustomParameterInterpolation_v2> interpolation=(id)blob;
    assert([interpolation interpolateBetween:right withWeight:0.49]==blob);
    assert([interpolation interpolateBetween:right withWeight:0.5]==right);
    NSData *roundtrip=[NSKeyedArchiver archivedDataWithRootObject:blob requiringSecureCoding:YES error:&error];
    assert([[NSKeyedUnarchiver unarchivedObjectOfClass:KKDataBlob.class fromData:roundtrip error:&error] isEqual:blob]);
    assert([[KKDataBlob blobWithData:nil].data isEqual:NSData.data]);
    puts("HostLifecycle: detached/attached lifetime, weak manager, unknown controls, missing input and historical archive compatibility passed");
  }
}
