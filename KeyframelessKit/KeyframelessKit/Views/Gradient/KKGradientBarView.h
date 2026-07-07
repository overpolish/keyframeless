/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKGradientStop : NSObject <NSCopying>
@property(nonatomic, assign) CGFloat position; // 0.0–1.0
@property(nonatomic, strong) NSColor *color;
@property(nonatomic, assign) CGFloat midpoint; // 0.0–1.0, default 0.5
+ (instancetype)stopWithPosition:(CGFloat)position color:(NSColor *)color;
+ (instancetype)stopWithPosition:(CGFloat)position
                           color:(NSColor *)color
                        midpoint:(CGFloat)midpoint;
@end

@interface KKGradientBarView : NSView

@property(nonatomic, copy) NSArray<KKGradientStop *> *stops;
@property(nonatomic, assign) NSInteger selectedIndex;         // -1 = none
@property(nonatomic, assign) NSInteger selectedMidpointIndex; // -1 = none
@property(nonatomic, assign) BOOL interactionEnabled;

@property(nonatomic, copy, nullable) void (^onStopsChanged)
    (NSArray<KKGradientStop *> *stops);
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;
/// Fires once at the start of a stop or midpoint drag (after the 3px
/// threshold), and once on mouseUp if a drag actually started. Lets the
/// consumer bracket the entire drag in one undo group so per-tick
/// `onStopsChanged` writes coalesce into a single host undo entry.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
/// Fires YES when a stop's shared colour panel is opened and NO when it closes.
/// A bar hosted in a transient popover uses this to suspend the popover's
/// outside-click dismissal while the panel (a separate window) is up.
@property(nonatomic, copy, nullable) void (^onColorEditingChanged)(BOOL editing)
    ;
- (void)setColor:(NSColor *)color forStopAtIndex:(NSInteger)index;
- (void)setPosition:(CGFloat)position forStopAtIndex:(NSInteger)index;
- (void)setMidpoint:(CGFloat)midpoint forStopAtIndex:(NSInteger)index;

- (void)reverseStops;
- (void)distributeStopsEvenly;

@end

NS_ASSUME_NONNULL_END
