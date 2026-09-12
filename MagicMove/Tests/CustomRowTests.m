/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MMCombinedPose.h"

// Exercise the production row and its attachment/refresh methods.
@interface MMCustomRow : NSView
@property(nonatomic, readonly) NSArray<NSTextField *> *fields;
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager;
- (void)refreshValues;
@end
@interface RowHost : MockHost <FxCustomParameterActionAPI_v4>
@property NSUInteger starts;
@property NSUInteger ends;
@end
@implementation RowHost
- (void)startAction:(id)sender { self.starts++; }
- (void)endAction:(id)sender { self.ends++; }
- (CMTime)currentTime { return kCMTimeZero; }
@end
static void publish(RowHost *host, double x, double scale) {
  host.blobs[@(MMCustomControls)]=[[MMCombinedPose alloc] initWithPositionX:x scale:scale authored:YES];
  MMRefreshCombinedPoseCache(host,kCMTimeZero);
}
static void displayed(MMCustomRow *row,double x,double scale) {
  assert(row.fields[0].enabled && row.fields[1].enabled);
  assert(row.fields[0].stringValue.length && row.fields[1].stringValue.length);
  assert(row.fields[0].doubleValue==x && row.fields[1].doubleValue==scale);
}
int main(void) {
 @autoreleasepool {
  [NSApplication sharedApplication];
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,240,100)
      styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
  window.releasedWhenClosed=NO; // Never order the test window on screen.
  RowHost *host=[RowHost new];
  MMCustomRow *row=[[MMCustomRow alloc] initWithManager:host];
  for (NSTextField *field in row.fields) assert(!field.enabled && !field.stringValue.length);
  [window.contentView addSubview:row];
  NSUInteger reads=host.nativeKeyReads;
  [row refreshValues];
  for (NSTextField *field in row.fields) assert(!field.enabled && !field.stringValue.length);
  assert(host.nativeKeyReads==reads);

  publish(host,37,142);
  reads=host.nativeKeyReads;
  [row refreshValues]; displayed(row,37,142);
  assert(host.nativeKeyReads==reads);

  // A temporary failed snapshot retains the display but makes it uneditable.
  host.failReadParameter=MMCustomControls;
  MMRefreshCombinedPoseCache(host,kCMTimeZero);
  [row refreshValues];
  assert(!row.fields[0].enabled && !row.fields[1].enabled);
  assert(row.fields[0].doubleValue==37 && row.fields[1].doubleValue==142);
  host.failReadParameter=0;
  publish(host,0,100); [row refreshValues]; displayed(row,0,100);
  [row removeFromSuperview];

  // A newly recreated row must not inherit the old row's values or defaults.
  RowHost *other=[RowHost new];
  MMCustomRow *replacement=[[MMCustomRow alloc] initWithManager:other];
  for (NSTextField *field in replacement.fields) assert(!field.enabled && !field.stringValue.length);
  publish(other,0,175); // Cache ready before attachment; no timer turn required.
  reads=other.nativeKeyReads;
  [window.contentView addSubview:replacement];
  displayed(replacement,0,175);
  assert(other.nativeKeyReads==reads);
  assert(host.starts==host.ends && other.starts==other.ends);
  [replacement removeFromSuperview];
  [window close];
  puts("Custom row: empty loading state, delayed values, immediate attachment refresh, zero values, unavailable snapshots and no refresh keyframe reads passed");
 }
}
