/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

static NSString *const kPluginID = @"co.overpolish.keyframeless.MagicMove";

// Parameter IDs — Point A (1–100)
static const UInt32 kParamGroupPointA = 1;
static const UInt32 kParamPointA = 2;
static const UInt32 kParamRotationA = 3;
static const UInt32 kParamScaleA = 4;
static const UInt32 kParamScaleYA = 5;
static const UInt32 kParamOpacityA = 6;
static const UInt32 kParamPreviewA = 7;
static const UInt32 kParamHideOSCA = 8;
static const UInt32 kParamRotationXA = 9;
static const UInt32 kParamRotationYA = 10;
static const UInt32 kParamExpandedA = 11;

// Parameter IDs — Point B (101–200)
static const UInt32 kParamGroupPointB = 101;
static const UInt32 kParamPointB = 102;
static const UInt32 kParamRotationB = 103;
static const UInt32 kParamScaleB = 104;
static const UInt32 kParamScaleYB = 105;
static const UInt32 kParamOpacityB = 106;
static const UInt32 kParamPreviewB = 107;
static const UInt32 kParamHideOSCB = 108;
static const UInt32 kParamRotationXB = 109;
static const UInt32 kParamRotationYB = 110;
static const UInt32 kParamExpandedB = 111;

// Parameter IDs — Drift (201–300)
static const UInt32 kParamGroupDrift = 201;
static const UInt32 kParamDrift = 202;
static const UInt32 kParamDriftPoint = 203;
static const UInt32 kParamDriftRotation = 204;
static const UInt32 kParamDriftScale = 205;
static const UInt32 kParamDriftScaleY = 206;
static const UInt32 kParamDriftOpacity = 207;
static const UInt32 kParamPreviewDrift = 208;
static const UInt32 kParamHideOSCDrift = 209;
static const UInt32 kParamDriftRotationX = 210;
static const UInt32 kParamDriftRotationY = 211;
static const UInt32 kParamExpandedDrift = 212;

// Parameter IDs — Exit (301–400)
static const UInt32 kParamGroupExit = 301;
static const UInt32 kParamExit = 302;
static const UInt32 kParamExitPoint = 303;
static const UInt32 kParamExitRotation = 304;
static const UInt32 kParamExitScale = 305;
static const UInt32 kParamExitScaleY = 306;
static const UInt32 kParamExitOpacity = 307;
static const UInt32 kParamPreviewExit = 308;
static const UInt32 kParamHideOSCExit = 309;
static const UInt32 kParamExitRotationX = 310;
static const UInt32 kParamExitRotationY = 311;
static const UInt32 kParamExpandedExit = 312;

// Path (401–500)
static const UInt32 kParamPathAB = 401;
static const UInt32 kParamPathBDrift = 402;
static const UInt32 kParamPathDriftExit = 403;
static const UInt32 kParamPathBExit = 404;
static const UInt32 kParamPathDriftA = 405;

// Global (501–600)
static const UInt32 kParamRotateWithMotion = 501;

// Alerts & Info (9000+)
static const UInt32 kParamForceShowAlerts = 9000;
static const UInt32 kParamInfoCompound = 9001;
static const UInt32 kParamAlertStackSelected = 9004;

typedef struct {
  UInt32 point, rotation, rotationX, rotationY, scaleX, scaleY, opacity;
} MagicMovePointParamIDs;

typedef struct {
  double x, y, rotation, rotationX, rotationY, scaleX, scaleY, opacity;
} MagicMovePointValues;

typedef struct {
  UInt32 group, enable, expanded, preview, hideOSC;
  MagicMovePointParamIDs params;
} MagicMoveGroupIDs;

static const MagicMoveGroupIDs kGroupA = {
    .group = kParamGroupPointA,
    .expanded = kParamExpandedA,
    .preview = kParamPreviewA,
    .hideOSC = kParamHideOSCA,
    .params = {kParamPointA, kParamRotationA, kParamRotationXA,
               kParamRotationYA, kParamScaleA, kParamScaleYA, kParamOpacityA}};

static const MagicMoveGroupIDs kGroupB = {
    .group = kParamGroupPointB,
    .expanded = kParamExpandedB,
    .preview = kParamPreviewB,
    .hideOSC = kParamHideOSCB,
    .params = {kParamPointB, kParamRotationB, kParamRotationXB,
               kParamRotationYB, kParamScaleB, kParamScaleYB, kParamOpacityB}};

static const MagicMoveGroupIDs kGroupDrift = {
    .group = kParamGroupDrift,
    .enable = kParamDrift,
    .expanded = kParamExpandedDrift,
    .preview = kParamPreviewDrift,
    .hideOSC = kParamHideOSCDrift,
    .params = {kParamDriftPoint, kParamDriftRotation, kParamDriftRotationX,
               kParamDriftRotationY, kParamDriftScale, kParamDriftScaleY,
               kParamDriftOpacity}};

static const MagicMoveGroupIDs kGroupExit = {
    .group = kParamGroupExit,
    .enable = kParamExit,
    .expanded = kParamExpandedExit,
    .preview = kParamPreviewExit,
    .hideOSC = kParamHideOSCExit,
    .params = {kParamExitPoint, kParamExitRotation, kParamExitRotationX,
               kParamExitRotationY, kParamExitScale, kParamExitScaleY,
               kParamExitOpacity}};

static inline NSArray<NSNumber *> *childIDsForGroup(MagicMoveGroupIDs g) {
  NSMutableArray *a = [NSMutableArray arrayWithCapacity:9];
  if (g.preview)
    [a addObject:@(g.preview)];
  if (g.hideOSC)
    [a addObject:@(g.hideOSC)];
  [a addObject:@(g.params.point)];
  [a addObject:@(g.params.rotation)];
  [a addObject:@(g.params.rotationX)];
  [a addObject:@(g.params.rotationY)];
  [a addObject:@(g.params.scaleX)];
  [a addObject:@(g.params.scaleY)];
  [a addObject:@(g.params.opacity)];
  return [a copy];
}
