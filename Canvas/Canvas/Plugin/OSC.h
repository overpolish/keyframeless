/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Constants.h"
#import <KeyframelessKit/KeyframelessKit.h>

@interface CanvasOSC : KKOnScreenControl

@property(nonatomic, strong) NSMutableArray<KKBezierPath *> *paths;
@property(nonatomic, assign) NSInteger activePathIndex; // -1 = none selected
@property(nonatomic, strong) KKPointOSC *pathPointOSC;
@property(nonatomic, strong) KKPointOSC *pathHandleOSC;
@property(nonatomic, assign) NSInteger dragIndex;
@property(nonatomic, assign) BOOL dragIsInHandle;
@property(nonatomic, assign) BOOL dragIsOutHandle;
@property(nonatomic, assign) NSInteger lastClickIndex;
@property(nonatomic, assign) CFAbsoluteTime lastClickTime;
@property(nonatomic, strong) NSCursor *penCursor;
@property(nonatomic, strong) NSCursor *penCloseCursor;
@property(nonatomic, strong) NSCursor *penAddCursor;
@property(nonatomic, strong) NSCursor *moveCursor;
@property(nonatomic, strong) NSCursor *editPointsCursor;
@property(nonatomic, strong) NSCursor *penDeleteCursor;
@property(nonatomic, strong) KKToolbar *toolbar;

- (NSMutableArray<KKBezierPath *> *)readPaths;
- (void)writePaths:(NSArray<KKBezierPath *> *)paths;
- (KKBezierPath *)activePath;

@end
