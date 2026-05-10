/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <os/lock.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

typedef NS_OPTIONS(NSUInteger, KKStoreChange) {
  KKStoreChangeNone = 0,
  KKStoreChangePaths = 1 << 0,
  KKStoreChangeSelection = 1 << 1,
  KKStoreChangeVisibility = 1 << 2,
  KKStoreChangePathProps = 1 << 3,
  KKStoreChangeCollapse = 1 << 4,
  KKStoreChangeSolo = 1 << 5,
  KKStoreChangeEditing = 1 << 6,
  KKStoreChangeExpanded = 1 << 7,
};

/// Immutable snapshot of the store state. Safe to read from any thread.
@interface KKCanvasStoreSnapshot : NSObject

@property(nonatomic, copy, readonly) NSArray<KKBezierPath *> *paths;
@property(nonatomic, copy, readonly) NSIndexSet *selectedIndices;
@property(nonatomic, readonly) BOOL soloActive;
@property(nonatomic, readonly) BOOL isEditing;
@property(nonatomic, readonly) BOOL isDragging;
@property(nonatomic, copy, readonly) NSSet<NSString *> *collapsedGroupIDs;

// Selected path derived properties.
@property(nonatomic, readonly) BOOL hasSelectedPath;
@property(nonatomic, readonly) BOOL selectedPathOpen;
@property(nonatomic, readonly) BOOL selectedPathHasJoins;
@property(nonatomic, readonly) BOOL strokeEnabled;
@property(nonatomic, readonly) BOOL fillEnabled;
@property(nonatomic, readonly) BOOL sketchEnabled;
@property(nonatomic, readonly) BOOL transformEnabled;
@property(nonatomic, readonly) BOOL strokeExpanded;
@property(nonatomic, readonly) BOOL fillExpanded;
@property(nonatomic, readonly) BOOL sketchExpanded;
@property(nonatomic, readonly) BOOL transformExpanded;
@property(nonatomic, readonly) uint8_t lineCap;
@property(nonatomic, readonly) uint8_t lineJoin;
@property(nonatomic, readonly) uint8_t strokeStyle;
@property(nonatomic, readonly) uint8_t startMarker;
@property(nonatomic, readonly) uint8_t endMarker;
@property(nonatomic, readonly) uint8_t fillStyle;
@property(nonatomic, readonly) NSInteger selectedLineCap;
@property(nonatomic, readonly) NSInteger selectedLineJoin;
@property(nonatomic, readonly) NSInteger selectedStrokeStyle;
@property(nonatomic, readonly) NSInteger selectedStartMarker;
@property(nonatomic, readonly) NSInteger selectedEndMarker;
@property(nonatomic, readonly) NSInteger selectedFillStyle;
@property(nonatomic, readonly) BOOL forceShow;
@property(nonatomic, readonly) uint8_t strokeColorMode;
@property(nonatomic, readonly) uint8_t fillColorMode;
@property(nonatomic, readonly) uint8_t strokeGradientType;
@property(nonatomic, readonly) uint8_t fillGradientType;

@end

typedef void (^KKStoreObserverBlock)(KKCanvasStoreSnapshot *snapshot,
                                     KKStoreChange changes);

/// Reactive state store for a single Canvas plugin instance.
///
/// Thread-safe. Producers write via performBatch:. Consumers register
/// observers with a change mask — only notified when relevant state changes.
/// Notifications are coalesced and delivered on the main thread.
@interface KKCanvasStore : NSObject

- (instancetype)initWithUUID:(NSString *)uuid;

@property(nonatomic, copy, readonly) NSString *uuid;

/// Returns an immutable snapshot of current state. Thread-safe.
- (KKCanvasStoreSnapshot *)snapshot;

/// Batch multiple mutations. Diffs before/after and notifies observers.
/// Thread-safe — acquires internal lock for the duration of the block.
- (void)performBatch:(void (^)(void))block;

// --- Mutators (call inside performBatch: only) ---
- (void)setPaths:(NSArray<KKBezierPath *> *)paths;
- (void)setSelectedIndices:(NSIndexSet *)indices;
- (void)setSoloActive:(BOOL)active;
- (void)setEditing:(BOOL)editing;
- (void)setDragging:(BOOL)dragging;
- (void)setCollapsedGroupIDs:(NSSet<NSString *> *)ids;
- (void)setStrokeExpanded:(BOOL)expanded;
- (void)setFillExpanded:(BOOL)expanded;
- (void)setSketchExpanded:(BOOL)expanded;
- (void)setTransformExpanded:(BOOL)expanded;
- (void)setForceShow:(BOOL)forceShow;
- (void)setStrokeEnabled:(BOOL)enabled;
- (void)setFillEnabled:(BOOL)enabled;
- (void)setSketchEnabled:(BOOL)enabled;
- (void)setTransformEnabled:(BOOL)enabled;
- (void)setStrokeColorMode:(uint8_t)mode;
- (void)setFillColorMode:(uint8_t)mode;
- (void)setStrokeGradientType:(uint8_t)t;
- (void)setFillGradientType:(uint8_t)t;

/// Updates cached style properties from the first selected non-group path.
/// Also updates lineCap/lineJoin/strokeStyle/markers/fillStyle caches.
- (void)syncSelectedPathProperties;

// --- Observation ---
/// Register an observer. Always called on main thread.
/// Returns an opaque token — caller must call removeObserver: to unregister.
- (id)addObserverForChanges:(KKStoreChange)mask
                      block:(KKStoreObserverBlock)block;
- (void)removeObserver:(id)token;

@end

NS_ASSUME_NONNULL_END
