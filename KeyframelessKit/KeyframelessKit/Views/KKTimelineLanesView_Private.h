/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

static const CGFloat kRowHeight = 28.0;
static const CGFloat kFooterH = 32.0;
static const CGFloat kCheckSize = 12.0;
static const CGFloat kCheckRadius = 3.0;
static const CGFloat kSearchH = 28.0;
static const CGFloat kPopoverW = 180.0;
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
- (instancetype)initWithLabel:(NSString *)label;
@end

@interface _KKStaticValuesPopoverView : NSView
@property(nonatomic, weak, nullable) NSPopover *popover;
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes;
- (void)updateUnoptedLanes:(NSArray<KKLane *> *)lanes;
+ (CGFloat)heightForLanes:(NSArray<KKLane *> *)lanes;
@end

@interface _KKDropdownTrigger : NSView
@property(nonatomic, copy, nullable) NSArray<NSString *> *selectedLabels;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

@interface _KKLaneRow : NSView
@property(nonatomic, copy) NSString *laneLabel;
@end

NS_ASSUME_NONNULL_END
