/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Plugin_Private.h"
#import "Constants.h"
#import "MMInspectorHeader.h"
#import <Cocoa/Cocoa.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (CustomRow)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  // Rows read the instance's caches, so their tokens must be live first.
  [self publishViewCaches];
  if (parameterID == MMHeaderControls) return [[MMInspectorHeader alloc] initWithManager:self.apiManager];
  if (parameterID == MMTimingControls) return [[KFTimingEditor alloc] initWithEffect:self];
  KFPropertyLane *lane = KFPropertyLaneForParameter(parameterID);
  if (!lane) return nil;
  // A single-component property gets a slider; the rest get one field per axis.
  if (lane.componentCount == 1) return [[KFScalarRow alloc] initWithEffect:self lane:lane];
  return [[KFVectorRow alloc] initWithEffect:self lane:lane];
}
@end

#pragma clang diagnostic pop
