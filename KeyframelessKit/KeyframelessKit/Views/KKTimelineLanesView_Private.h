/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

@protocol KKMiniCanvasDelegate;

static const CGFloat kRowHeight = 28.0;
static const CGFloat kFooterH = 32.0;
static const CGFloat kCheckSize = 12.0;
static const CGFloat kCheckRadius = 3.0;
static const CGFloat kSearchH = 28.0;
static const CGFloat kPopoverW = 180.0;
// Wider variant for the static-values popover when it hosts the mini canvas,
// so the preview is legible before in-canvas zoom exists.
static const CGFloat kCanvasPopoverW = 420.0;
static const NSInteger kMaxSummaryLabels = 2;

NS_ASSUME_NONNULL_BEGIN

@interface _KKLVPopoverContentView : NSView
@end

@interface _KKSearchFieldCell : NSSearchFieldCell
@end

@interface _KKSearchField : NSSearchField
@end

@interface _KKManageRow : NSView
@property(nonatomic, copy) NSString *rowLabel;
@property(nonatomic) BOOL checked;
@property(nonatomic, copy, nullable) void (^onToggle)(void);
@end

@interface _KKManagePopoverView : NSView <NSSearchFieldDelegate>
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                checkedLabels:(NSSet<NSString *> *)checked
                     onToggle:(void (^)(NSString *label))onToggle;
- (void)updateCheckedLabels:(NSSet<NSString *> *)checked;
- (nullable NSView *)rowViewForLabel:(NSString *)label;
+ (CGFloat)heightForLaneCount:(NSInteger)count;
@end

@interface _KKStaticValueRow : NSView
@property(nonatomic, copy) NSString *laneLabel;
/// New constant values for the lane (Float: [v]; Crop: [w,h,x,y]).
@property(nonatomic, copy, nullable) void (^onValue)
    (NSArray<NSNumber *> *values);
/// Bracket a continuous slider drag so the host coalesces it to one undo /
/// one persist (mirrors the mini canvas).
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
/// Per-component display scale (display = stored × scale). Used so crop
/// fields show pixels while the model stays normalized. nil/≤0 == raw.
@property(nonatomic, copy, nullable) double (^componentScale)(NSInteger idx);
- (instancetype)initWithLane:(KKLane *)lane;
/// Set the displayed values (skips a field currently being edited).
- (void)applyValues:(NSArray<NSNumber *> *)values;
- (void)applyLane:(KKLane *)lane;
/// Re-render fields/slider from the stored values (e.g. after the display
/// scale changes when the feed resolves its media size).
- (void)refreshDisplay;
+ (CGFloat)heightForLane:(KKLane *)lane;
@end

@interface _KKStaticValuesPopoverView : NSView
@property(nonatomic, weak, nullable) NSPopover *popover;
- (instancetype)
     initWithLanes:(NSArray<KKLane *> *)lanes
    descriptorPath:(nullable NSString *)descriptorPath
        clipAspect:(CGFloat)clipAspect
    canvasDelegate:(nullable id<KKMiniCanvasDelegate>)canvasDelegate
     onHandleValue:(nullable void (^)(NSString *label,
                                      NSArray<NSNumber *> *values))onHandleValue
       onDragBegin:(nullable void (^)(void))onDragBegin
         onDragEnd:(nullable void (^)(void))onDragEnd;
- (void)updateUnoptedLanes:(NSArray<KKLane *> *)lanes;
+ (CGFloat)heightForLanes:(NSArray<KKLane *> *)lanes
           descriptorPath:(nullable NSString *)descriptorPath
               clipAspect:(CGFloat)clipAspect;
@end

@interface _KKDropdownTrigger : NSView
@property(nonatomic, copy, nullable) NSArray<NSString *> *selectedLabels;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

@interface _KKLaneRow : NSView
@property(nonatomic, copy) NSString *laneLabel;
@end

NS_ASSUME_NONNULL_END
