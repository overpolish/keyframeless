/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
@import OSCControls;

// Viewer control: the transformed image's outline with eight scale handles.
// Dragging anywhere else in the viewer moves the image, so an image whose
// handles left the viewer can still be dragged back (like Transform in FCP).
// Every drag tick is ONE host write per lane, grouped into one undo entry.
@interface MagicMoveOSC : NSObject <FxOnScreenControl_v4>
@property(nonatomic, weak, readonly) id<PROAPIAccessing> apiManager;
@property(nonatomic, readonly) NSInteger hoveredHandle;
@property(nonatomic, readonly) BOOL dragging;
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;
// Rendered footprint at `time`; NO when the host cannot supply the parameters.
- (BOOL)boxPoseAtTime:(CMTime)time pose:(OSCBoxPose *)pose;
- (CGSize)imageSize;
- (BOOL)canvasHandlesAtTime:(CMTime)time handles:(CGPoint[OSCBoxHandleCount])handles;
@end
