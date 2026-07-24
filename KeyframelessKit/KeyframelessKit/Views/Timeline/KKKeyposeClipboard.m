/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKKeyposeClipboard.h"

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimeline.h>

static NSString *const kKKKeyposePBType =
    @"co.overpolish.keyframeless.keyposeValues";
static NSInteger const kKKKeyposePBVersion = 1;

@interface KKKeyposeClipboardEntry ()
@property(nonatomic, copy) NSString *label;
@property(nonatomic) NSInteger valueType;
@property(nonatomic, copy) NSArray<NSNumber *> *values;
@property(nonatomic) BOOL spatialSmooth;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *inHandle;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *outHandle;
@property(nonatomic, copy, nullable) NSData *geometrySnapshot;
@end

@implementation KKKeyposeClipboardEntry

- (NSDictionary *)toDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"label"] = self.label;
  d[@"valueType"] = @(self.valueType);
  d[@"values"] = self.values;
  d[@"spatialSmooth"] = @(self.spatialSmooth);
  if (self.inHandle)
    d[@"inHandle"] = self.inHandle;
  if (self.outHandle)
    d[@"outHandle"] = self.outHandle;
  if (self.geometrySnapshot)
    d[@"geom"] = [self.geometrySnapshot base64EncodedStringWithOptions:0];
  return d;
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  NSString *label = d[@"label"];
  NSArray *values = d[@"values"];
  if (![label isKindOfClass:[NSString class]] ||
      ![values isKindOfClass:[NSArray class]])
    return nil;
  NSString *geomB64 = [d[@"geom"] isKindOfClass:[NSString class]] ? d[@"geom"]
                                                                  : nil;
  // A geometry-lane pose carries no scalar (empty values) - its shape is the
  // payload, so allow an empty values array as long as a snapshot is present.
  if (values.count == 0 && !geomB64)
    return nil;
  KKKeyposeClipboardEntry *e = [[KKKeyposeClipboardEntry alloc] init];
  e.label = label;
  e.valueType = [d[@"valueType"] integerValue];
  e.values = values;
  e.spatialSmooth = [d[@"spatialSmooth"] boolValue];
  e.inHandle =
      [d[@"inHandle"] isKindOfClass:[NSArray class]] ? d[@"inHandle"] : nil;
  e.outHandle =
      [d[@"outHandle"] isKindOfClass:[NSArray class]] ? d[@"outHandle"] : nil;
  e.geometrySnapshot =
      geomB64 ? [[NSData alloc] initWithBase64EncodedString:geomB64 options:0]
              : nil;
  return e;
}

- (BOOL)matchesLane:(KKLane *)lane {
  if (![lane.key isEqualToString:self.label])
    return NO;
  if (lane.valueType != self.valueType)
    return NO;
  NSUInteger laneCount = lane.keyposes.firstObject.values.count;
  return laneCount == 0 || laneCount == self.values.count;
}

- (KKKeyPose *)applyToKeypose:(KKKeyPose *)keypose {
  KKKeyPose *nk = [keypose copy];
  nk.values = self.values;
  nk.spatialSmooth = self.spatialSmooth;
  nk.inHandle = self.inHandle;
  nk.outHandle = self.outHandle;
  nk.geometrySnapshot = self.geometrySnapshot;
  return nk;
}

@end

@implementation KKKeyposeClipboard

+ (KKKeyposeClipboardEntry *)entryForKeypose:(KKKeyPose *)keypose
                                        lane:(KKLane *)lane {
  KKKeyposeClipboardEntry *e = [[KKKeyposeClipboardEntry alloc] init];
  e.label = lane.key;
  e.valueType = lane.valueType;
  e.values = keypose.values;
  e.spatialSmooth = keypose.spatialSmooth;
  e.inHandle = keypose.inHandle;
  e.outHandle = keypose.outHandle;
  e.geometrySnapshot = keypose.geometrySnapshot;
  return e;
}

+ (void)writeEntries:(NSArray<KKKeyposeClipboardEntry *> *)entries {
  if (entries.count == 0)
    return;
  NSMutableArray *arr = [NSMutableArray arrayWithCapacity:entries.count];
  for (KKKeyposeClipboardEntry *e in entries)
    [arr addObject:[e toDictionary]];
  NSDictionary *root = @{@"v" : @(kKKKeyposePBVersion), @"entries" : arr};
  NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                 options:0
                                                   error:nil];
  if (!data)
    return;
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setData:data forType:kKKKeyposePBType];
}

+ (nullable NSArray<KKKeyposeClipboardEntry *> *)readEntries {
  NSData *data =
      [[NSPasteboard generalPasteboard] dataForType:kKKKeyposePBType];
  if (!data)
    return nil;
  id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  NSArray *arr =
      [root isKindOfClass:[NSDictionary class]] ? root[@"entries"] : nil;
  if (![arr isKindOfClass:[NSArray class]])
    return nil;
  NSMutableArray<KKKeyposeClipboardEntry *> *out =
      [NSMutableArray arrayWithCapacity:arr.count];
  for (NSDictionary *d in arr) {
    KKKeyposeClipboardEntry *e = [KKKeyposeClipboardEntry fromDictionary:d];
    if (e)
      [out addObject:e];
  }
  return out.count > 0 ? out : nil;
}

@end
