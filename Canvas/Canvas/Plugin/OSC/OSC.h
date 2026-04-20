/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Constants.h"
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CanvasOSC : KKOnScreenControl

@property(nonatomic, strong) NSMutableArray<KKBezierPath *> *paths;
@property(nonatomic, assign) NSInteger activePathIndex;
@property(nonatomic, strong) KKPointOSC *pathPointOSC;
@property(nonatomic, strong) KKPointOSC *pathHandleOSC;
@property(nonatomic, assign) NSInteger dragIndex;
@property(nonatomic, assign) BOOL dragIsInHandle;
@property(nonatomic, assign) BOOL dragIsOutHandle;
@property(nonatomic, assign) BOOL dragIsNewPoint;
@property(nonatomic, assign) BOOL dragIsPath;
@property(nonatomic, assign) BOOL dragIsMarquee;
@property(nonatomic, assign) BOOL dragIsSelection;
@property(nonatomic, assign) BOOL dragDidDuplicate;
@property(nonatomic, assign) BOOL dragIsRect;
@property(nonatomic, assign) BOOL dragIsEllipse;
@property(nonatomic, assign) BOOL dragIsLine;
@property(nonatomic, assign) simd_float2 dragOrigin;
@property(nonatomic, assign)
    simd_float2 dragAnchor; // initial position for shift-constrain
@property(nonatomic, assign) simd_float2 rectStart;
@property(nonatomic, assign) float dragStartPixelRadius;
@property(nonatomic, assign) NSInteger dragCornerIndex; // 0=TL 1=TR 2=BR 3=BL
@property(nonatomic, assign) CGPoint marqueeStart;
@property(nonatomic, assign) CGPoint marqueeEnd;
@property(nonatomic, strong) NSMutableIndexSet *selectedPoints;
@property(nonatomic, strong) NSMutableIndexSet *selectedPathIndices;
@property(nonatomic, assign) NSInteger lastClickIndex;
@property(nonatomic, assign) CFAbsoluteTime lastClickTime;
@property(nonatomic, strong) NSCursor *penCursor;
@property(nonatomic, strong) NSCursor *penCloseCursor;
@property(nonatomic, strong) NSCursor *penAddCursor;
@property(nonatomic, strong) NSCursor *moveCursor;
@property(nonatomic, strong) NSCursor *editPointsCursor;
@property(nonatomic, strong) NSCursor *penDeleteCursor;
@property(nonatomic, strong) KKToolbar *toolbar;
@property(nonatomic, strong) KKToolbar *pathToolbar;
@property(nonatomic, strong) KKToolbar *gridToolbar;
@property(nonatomic, assign) BOOL gridEnabled;
@property(nonatomic, assign) BOOL gridAdaptive;
@property(nonatomic, assign) BOOL snapToGrid;
@property(nonatomic, assign) NSInteger gridSpacing;
@property(nonatomic, assign) BOOL restoredTool;
@property(nonatomic, assign) BOOL stepperDragging;
@property(nonatomic, assign) BOOL stepperShiftWasDown;
@property(nonatomic, assign) double stepperDragOriginY;
@property(nonatomic, assign) double stepperAccumulatedDelta;
@property(nonatomic, assign) NSInteger stepperDragStartValue;
@property(nonatomic, strong) KKOSCLabel *sizeLabel;
@property(nonatomic, strong) KKRectBorderOSC *borderOSC;
@property(nonatomic, strong) NSArray<KKPointOSC *> *resizeHandleOSCs;
@property(nonatomic, assign) NSInteger dragResizeHandle;
@property(nonatomic, assign) simd_float2 resizeOrigMin;
@property(nonatomic, assign) simd_float2 resizeOrigMax;
@property(nonatomic, assign) float resizeOrigAspect;
@property(nonatomic, strong, nullable) NSArray<NSData *> *resizeOrigSnapshots;
@property(nonatomic, strong, nullable) NSArray<NSNumber *> *resizeOrigIndices;
@property(nonatomic, strong) KKPointOSC *rotateHandleOSC;
@property(nonatomic, assign) BOOL dragIsRotation;
@property(nonatomic, assign) simd_float2 rotateCenter;
@property(nonatomic, assign) float rotateStartAngle;
@property(nonatomic, assign) float rotateDeltaAngle;
@property(nonatomic, assign) simd_float2 rotateOrigMin;
@property(nonatomic, assign) simd_float2 rotateOrigMax;
@property(nonatomic, strong, nullable) NSArray<NSData *> *rotateOrigSnapshots;
@property(nonatomic, strong, nullable) NSArray<NSNumber *> *rotateOrigIndices;
@property(nonatomic, assign) NSInteger imageWidth;
@property(nonatomic, assign) NSInteger imageHeight;
@property(nonatomic, assign) BOOL autoSelect;
@property(nonatomic, assign) CGPoint autoSelectClickOrigin;
@property(nonatomic, assign) BOOL autoSelectPending;
@property(nonatomic, assign) BOOL alignSnappedX;
@property(nonatomic, assign) BOOL alignSnappedY;
@property(nonatomic, assign) float alignSnapValueX; // object-space X
@property(nonatomic, assign) float alignSnapValueY; // object-space Y

@property(nonatomic, assign) NSInteger hoveredPathOp;
@property(nonatomic, strong, nullable) KKBezierPath *previewResultPath;
@property(nonatomic, strong, nullable) id<MTLTexture> previewTexture;
@property(nonatomic, assign) NSInteger previewCachedOp;

- (NSMutableArray<KKBezierPath *> *)readPaths;
- (void)writePaths:(NSArray<KKBezierPath *> *)paths;

/// The raw base64 blob string from the last readPaths call.
@property(nonatomic, copy, nullable) NSString *lastReadBlobString;

/// The blob string that was last written to the store via setPaths:.
/// Compared against lastReadBlobString to skip no-op store writes.
@property(nonatomic, copy, nullable) NSString *storeBlobString;
- (void)syncStrokeParamsToSelection;
- (void)syncStrokeParamsToSelectionWithPrevious:(nullable NSIndexSet *)prevSel;
- (nullable KKBezierPath *)activePath;

@end

NS_ASSUME_NONNULL_END
