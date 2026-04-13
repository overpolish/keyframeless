/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Constants.h"
#import <KeyframelessKit/KeyframelessKit.h>

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
@property(nonatomic, strong) KKOSCLabel *sizeLabel;
@property(nonatomic, strong) KKRectBorderOSC *borderOSC;
@property(nonatomic, strong) NSArray<KKPointOSC *> *resizeHandleOSCs;
@property(nonatomic, assign) NSInteger dragResizeHandle;
@property(nonatomic, assign) simd_float2 resizeOrigMin;
@property(nonatomic, assign) simd_float2 resizeOrigMax;
@property(nonatomic, assign) float resizeOrigAspect;
@property(nonatomic, strong) NSArray<NSData *> *resizeOrigSnapshots;
@property(nonatomic, strong) NSArray<NSNumber *> *resizeOrigIndices;

- (NSMutableArray<KKBezierPath *> *)readPaths;
- (void)writePaths:(NSArray<KKBezierPath *> *)paths;
- (KKBezierPath *)activePath;

@end
