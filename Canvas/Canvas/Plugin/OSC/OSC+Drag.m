/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC_Private.h"

@implementation CanvasOSC (Drag)

- (simd_float2)shiftConstrainedPosition:(simd_float2)objPos {
  simd_float2 totalDelta = objPos - self.dragAnchor;
  if (fabs(totalDelta.x) > fabs(totalDelta.y))
    objPos.y = self.dragAnchor.y;
  else
    objPos.x = self.dragAnchor.x;
  return objPos;
}

- (void)dragRectToX:(double)positionX
                  y:(double)positionY
          modifiers:(NSUInteger)modifiers
        forceUpdate:(BOOL *)forceUpdate {
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  if (modifiers & kFxModifierKey_SHIFT) {
    CGPoint sc = [self canvasPointFromObjectPoint:self.rectStart];
    float dx = (float)(positionX - sc.x);
    float dy = (float)(positionY - sc.y);
    float side = roundf(fmaxf(fabsf(dx), fabsf(dy)));
    float sx = roundf((float)sc.x);
    float sy = roundf((float)sc.y);
    float ex = sx + copysignf(side, dx);
    float ey = sy + copysignf(side, dy);
    objPos = [self objectPointFromCanvasPoint:CGPointMake(ex, ey)];
  }
  objPos = [self snapToGridPosition:objPos];
  self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
  objPos = [self alignSnapPoint:objPos excludingPaths:nil excludingPoints:nil];
  self.dragOrigin = objPos;
  *forceUpdate = YES;
}

- (void)dragLineToX:(double)positionX
                  y:(double)positionY
          modifiers:(NSUInteger)modifiers
        forceUpdate:(BOOL *)forceUpdate {
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  if (modifiers & kFxModifierKey_SHIFT) {
    CGPoint sc = [self canvasPointFromObjectPoint:self.rectStart];
    float dx = (float)(positionX - sc.x);
    float dy = (float)(positionY - sc.y);
    float angle = atan2f(dy, dx);
    float snapped = roundf(angle / (M_PI / 4.0f)) * (M_PI / 4.0f);
    float dist = hypotf(dx, dy);
    float ex = (float)sc.x + dist * cosf(snapped);
    float ey = (float)sc.y + dist * sinf(snapped);
    objPos = [self objectPointFromCanvasPoint:CGPointMake(ex, ey)];
  }
  objPos = [self snapToGridPosition:objPos];
  self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
  objPos = [self alignSnapPoint:objPos excludingPaths:nil excludingPoints:nil];
  self.dragOrigin = objPos;
  *forceUpdate = YES;
}

- (void)duplicateSelectedPaths:(simd_float2)delta {
  NSMutableIndexSet *expanded = [self.selectedPathIndices mutableCopy];
  [self.selectedPathIndices
      enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.paths.count && self.paths[idx].isGroup)
          [expanded addIndexes:KKDescendantIndices(idx, self.paths)];
      }];
  NSMutableIndexSet *newIndices = [NSMutableIndexSet indexSet];
  NSMutableDictionary<NSString *, NSString *> *groupIDMap =
      [NSMutableDictionary dictionary];
  [expanded enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    if (idx >= self.paths.count || self.paths[idx].locked)
      return;
    KKBezierPath *clone =
        [KKBezierPath pathWithData:[self.paths[idx] dataRepresentation]];
    // Fresh layerID so per-layer state (Path-morph snapshots, lanes,
    // selection) doesn't bleed between original and clone. Mirrors the
    // layer-list duplicate path.
    clone.layerID = [[NSUUID UUID] UUIDString];
    if (clone.isGroup && clone.groupID) {
      NSString *newID = [[NSUUID UUID] UUIDString];
      groupIDMap[clone.groupID] = newID;
      clone.groupID = newID;
    }
    if (clone.parentGroupID && groupIDMap[clone.parentGroupID])
      clone.parentGroupID = groupIDMap[clone.parentGroupID];
    [self.paths addObject:clone];
    if ([self.selectedPathIndices containsIndex:idx])
      [newIndices addIndex:self.paths.count - 1];
  }];
  [self.selectedPathIndices removeAllIndexes];
  [self.selectedPathIndices addIndexes:newIndices];
  self.activePathIndex = (NSInteger)newIndices.lastIndex;
}

- (void)dragSelectionToX:(double)positionX
                       y:(double)positionY
               modifiers:(NSUInteger)modifiers
             forceUpdate:(BOOL *)forceUpdate {
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  if (modifiers & kFxModifierKey_SHIFT)
    objPos = [self shiftConstrainedPosition:objPos];

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;

  // Snap the selection's bounding-box corner to grid, not the mouse position.
  simd_float2 rawDelta = objPos - self.dragOrigin;
  simd_float2 bmin, bmax;
  if (self.snapToGrid && self.gridEnabled && isCursorMode &&
      [self boundsOfSelectedPaths:&bmin max:&bmax]) {
    simd_float2 targetMin = bmin + rawDelta;
    simd_float2 snappedMin = [self snapToGridPosition:targetMin];
    rawDelta += (snappedMin - targetMin);
  } else {
    objPos = [self snapToGridPosition:objPos];
    rawDelta = objPos - self.dragOrigin;
  }
  simd_float2 delta = rawDelta;
  if (isCursorMode)
    delta = [self alignSnapDelta:delta
                forSelectedPaths:self.selectedPathIndices];
  self.dragOrigin += delta;
  if (isCursorMode) {
    if ((modifiers & kFxModifierKey_OPTION) && !self.dragDidDuplicate) {
      self.dragDidDuplicate = YES;
      [self duplicateSelectedPaths:delta];
    }
    [self.selectedPathIndices
        enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
          if (idx < self.paths.count && !self.paths[idx].locked)
            [self.paths[idx] translateBy:delta];
        }];
  } else {
    for (NSUInteger p = 0; p < self.paths.count; p++) {
      KKBezierPath *path = self.paths[p];
      for (NSUInteger i = 0; i < path.count; i++) {
        if ([self isPointSelected:p point:i]) {
          KKBezierPoint pt = [path pointAtIndex:i];
          [path moveAtIndex:i to:(simd_float2){pt.x + delta.x, pt.y + delta.y}];
        }
      }
    }
  }
  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)dragPointOrHandleToX:(double)positionX
                           y:(double)positionY
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate {
  KKBezierPath *active = [self activePath];
  if (!active || self.dragIndex < 0 ||
      self.dragIndex >= (NSInteger)active.count)
    return;

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  BOOL breakSymmetry = (modifiers & kFxModifierKey_OPTION) != 0;
  KKBezierPoint pt = [active pointAtIndex:self.dragIndex];
  simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};

  if (self.dragIsNewPoint) {
    CGFloat canvasDist = hypot(positionX - self.newPointCanvasOrigin.x,
                               positionY - self.newPointCanvasOrigin.y);
    if (canvasDist > 10.0) {
      [self setHandle:offset
                atIndex:self.dragIndex
                   isIn:NO
          breakSymmetry:NO
                 onPath:active];
    }
  } else if (self.dragIsInHandle) {
    [self setHandle:offset
              atIndex:self.dragIndex
                 isIn:YES
        breakSymmetry:breakSymmetry
               onPath:active];
  } else if (self.dragIsOutHandle) {
    [self setHandle:offset
              atIndex:self.dragIndex
                 isIn:NO
        breakSymmetry:breakSymmetry
               onPath:active];
  } else {
    if (modifiers & kFxModifierKey_SHIFT)
      objPos = [self shiftConstrainedPosition:objPos];
    objPos = [self snapToGridPosition:objPos];
    self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
    {
      NSMutableIndexSet *exPts = [NSMutableIndexSet
          indexSetWithIndex:selKey((NSUInteger)self.activePathIndex,
                                   (NSUInteger)self.dragIndex)];
      if (self.selectedPoints.count > 1)
        [exPts addIndexes:self.selectedPoints];
      objPos = [self alignSnapPoint:objPos
                     excludingPaths:nil
                    excludingPoints:exPts];
    }
    NSUInteger dragKey =
        selKey((NSUInteger)self.activePathIndex, (NSUInteger)self.dragIndex);
    if (self.selectedPoints.count > 1 &&
        [self.selectedPoints containsIndex:dragKey]) {
      simd_float2 delta = {objPos.x - pt.x, objPos.y - pt.y};
      [self.selectedPoints
          enumerateIndexesUsingBlock:^(NSUInteger sk, BOOL *stop) {
            NSUInteger pi = sk / 100000;
            NSUInteger pti = sk % 100000;
            if (pi >= self.paths.count)
              return;
            KKBezierPath *p = self.paths[pi];
            if (pti >= p.count)
              return;
            p.isRect = NO;
            KKBezierPoint sp = [p pointAtIndex:pti];
            simd_float2 newPos = {sp.x + delta.x, sp.y + delta.y};
            [p moveAtIndex:pti to:newPos];
          }];
    } else {
      active.isRect = NO;
      [active moveAtIndex:self.dragIndex to:objPos];
    }
  }

  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)dragPathToX:(double)positionX
                  y:(double)positionY
          modifiers:(NSUInteger)modifiers
        forceUpdate:(BOOL *)forceUpdate {
  KKBezierPath *active = [self activePath];
  if (!active)
    return;
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  if (modifiers & kFxModifierKey_SHIFT)
    objPos = [self shiftConstrainedPosition:objPos];
  objPos = [self snapToGridPosition:objPos];
  simd_float2 delta = objPos - self.dragOrigin;
  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
  if (isCursorMode) {
    NSMutableIndexSet *snapSet =
        [NSMutableIndexSet indexSetWithIndex:self.activePathIndex];
    if (active.isGroup)
      [snapSet
          addIndexes:KKDescendantIndices(self.activePathIndex, self.paths)];
    delta = [self alignSnapDelta:delta forSelectedPaths:snapSet];
  }
  if (isCursorMode && (modifiers & kFxModifierKey_OPTION) &&
      !self.dragDidDuplicate) {
    self.dragDidDuplicate = YES;
    NSMutableIndexSet *srcIndices =
        [NSMutableIndexSet indexSetWithIndex:self.activePathIndex];
    if (active.isGroup)
      [srcIndices
          addIndexes:KKDescendantIndices(self.activePathIndex, self.paths)];
    NSMutableDictionary<NSString *, NSString *> *groupIDMap =
        [NSMutableDictionary dictionary];
    __block NSInteger cloneIdx = -1;
    [srcIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      KKBezierPath *c =
          [KKBezierPath pathWithData:[self.paths[idx] dataRepresentation]];
      if (c.isGroup && c.groupID) {
        NSString *newID = [[NSUUID UUID] UUIDString];
        groupIDMap[c.groupID] = newID;
        c.groupID = newID;
      }
      if (c.parentGroupID && groupIDMap[c.parentGroupID])
        c.parentGroupID = groupIDMap[c.parentGroupID];
      [self.paths addObject:c];
      if ((NSUInteger)self.activePathIndex == idx)
        cloneIdx = (NSInteger)self.paths.count - 1;
    }];
    [self.selectedPathIndices removeAllIndexes];
    [self.selectedPathIndices addIndex:cloneIdx];
    self.activePathIndex = cloneIdx;
  }
  active = [self activePath];
  [active translateBy:delta];
  if (active.isGroup) {
    NSIndexSet *desc = KKDescendantIndices(self.activePathIndex, self.paths);
    [desc enumerateIndexesUsingBlock:^(NSUInteger di, BOOL *stop) {
      [self.paths[di] translateBy:delta];
    }];
  }
  self.dragOrigin += delta;
  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)handleStepperDragAtY:(double)positionY
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate {
  double moveDelta = positionY - self.stepperDragOriginY;
  self.stepperDragOriginY = positionY;
  self.stepperAccumulatedDelta += moveDelta;

  BOOL shiftDown = (modifiers & kFxModifierKey_SHIFT) != 0;

  // When shift is pressed/released, rebase so the multiplier change
  // starts from the current value.
  if (shiftDown != self.stepperShiftWasDown) {
    self.stepperAccumulatedDelta = 0;
    self.stepperDragStartValue = self.gridSpacing;
    self.stepperShiftWasDown = shiftDown;
  }

  // 8px per unit normally, 2px per unit with shift.
  double pxPerUnit = shiftDown ? 2.0 : 8.0;
  NSInteger newVal = self.stepperDragStartValue +
                     (NSInteger)(self.stepperAccumulatedDelta / pxPerUnit);
  if (newVal < 1)
    newVal = 1;
  if (newVal > 1000)
    newVal = 1000;
  if (newVal != self.gridSpacing) {
    self.gridSpacing = newVal;
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setIntValue:(int)self.gridSpacing
            toParameter:kParamGridSpacing
                 atTime:kCMTimeZero];
    *forceUpdate = YES;
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (self.positionPathDragSegIndex >= 0) {
    if ([self mouseDraggedOnPositionPathAtX:positionX
                                          y:positionY
                                  modifiers:modifiers
                                     atTime:time]) {
      *forceUpdate = YES;
      return;
    }
  }

  if (self.transformPositionDragging) {
    simd_float2 currentObj =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    simd_float2 delta = currentObj - self.transformPositionDragStartObj;
    if (modifiers & kFxModifierKey_SHIFT) {
      if (fabsf(delta.x) > fabsf(delta.y))
        delta.y = 0;
      else
        delta.x = 0;
    }
    simd_float2 newParam = self.transformPositionDragStartParam + delta;
    id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [actAPI startAction:self];
    [setAPI setXValue:newParam.x
               YValue:newParam.y
          toParameter:kParamPosition
               atTime:time];
    [actAPI endAction:self];
    *forceUpdate = YES;
    return;
  }

  if (self.scaleRingDragging) {
    // MagicMove pattern: default = uniform (both axes track the radial
    // ratio); shift held = unlink, applies the ratio to whichever axis
    // dominated the start click direction. Clamp 0..10.
    CGPoint anchorCanvas = [self transformAnchorCanvasPointAtTime:time];
    double dx = positionX - anchorCanvas.x;
    double dy = positionY - anchorCanvas.y;
    double dist = sqrt(dx * dx + dy * dy);
    if (self.scaleRingDragStartDist > 0) {
      double ratio = dist / self.scaleRingDragStartDist;
      BOOL shiftHeld = (modifiers & kFxModifierKey_SHIFT) != 0;
      id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      id<FxParameterSettingAPI_v5> setAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [actAPI startAction:self];
      if (shiftHeld) {
        BOOL horizontal = self.scaleRingDragStartAngle < M_PI / 4.0;
        double newVal =
            MAX(0.0, MIN(10.0, (horizontal ? self.scaleRingDragStartValX
                                           : self.scaleRingDragStartValY) *
                                   ratio));
        [setAPI setFloatValue:newVal
                  toParameter:(horizontal ? kParamScaleX : kParamScaleY)atTime
                             :time];
      } else {
        double newSx = MAX(0.0, MIN(10.0, self.scaleRingDragStartValX * ratio));
        double newSy = MAX(0.0, MIN(10.0, self.scaleRingDragStartValY * ratio));
        [setAPI setFloatValue:newSx toParameter:kParamScaleX atTime:time];
        [setAPI setFloatValue:newSy toParameter:kParamScaleY atTime:time];
      }
      [actAPI endAction:self];
    }
    [self.scaleRingOSC updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (self.rotXRingDragging || self.rotYRingDragging) {
    // MagicMove pattern: M_PI/200 radians per pixel of mouse movement;
    // X ring tracks horizontal motion, Y ring tracks vertical (sign
    // inverted to match MM's "up = positive RotX" feel). Snap to zero
    // at ±3°.
    double pos = self.rotXRingDragging ? positionX : positionY;
    double delta = (pos - self.rotRingDragPrevPos) * (M_PI / 200.0);
    if (self.rotYRingDragging)
      delta = -delta;
    self.rotRingDragPrevPos = pos;
    self.rotRingDragAccum = self.rotRingDragAccum + delta;
    static const double kSnapToZero = 3.0 * (M_PI / 180.0);
    double value = self.rotRingDragAccum;
    if (fabs(value) < kSnapToZero)
      value = 0.0;
    id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [actAPI startAction:self];
    [setAPI setFloatValue:value
              toParameter:self.rotRingDragTargetParam
                   atTime:time];
    [actAPI endAction:self];
    *forceUpdate = YES;
    return;
  }

  if (self.rotZDragging) {
    // MagicMove pattern: atan2 delta accumulation around the rotation
    // pivot (anchor canvas point), with snap-to-zero at ±3°.
    CGPoint anchorCanvas = [self transformAnchorCanvasPointAtTime:time];
    double dx = positionX - anchorCanvas.x;
    double dy = positionY - anchorCanvas.y;
    double angle = atan2(-dy, dx);
    double delta = angle - self.rotZDragPrevAngle;
    if (delta > M_PI)
      delta -= 2.0 * M_PI;
    else if (delta < -M_PI)
      delta += 2.0 * M_PI;
    self.rotZDragAccum = self.rotZDragAccum + delta;
    self.rotZDragPrevAngle = angle;
    static const double kSnapToZero = 3.0 * (M_PI / 180.0);
    double value = self.rotZDragAccum;
    if (fabs(value) < kSnapToZero)
      value = 0.0;
    id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [actAPI startAction:self];
    [setAPI setFloatValue:value toParameter:kParamRotation atTime:time];
    [actAPI endAction:self];
    *forceUpdate = YES;
    return;
  }

  if (self.anchorDragging) {
    // MagicMove pattern: mouse → object space → that's the new anchor
    // (no translate compensation). Canvas anchor is bbox-relative, so we
    // subtract the path's bbox center first, then snap targets are
    // expressed as bbox-relative offsets (corners, edges, thirds, center).
    KKBezierPath *p = [self selectedTransformablePath];
    if (!p) {
      *forceUpdate = YES;
      return;
    }
    simd_float2 mouseObj =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    simd_float2 paramPos = [self objectPositionForParam:kParamPosition
                                                 atTime:time];
    simd_float2 translation = paramPos - (simd_float2){0.5f, 0.5f};
    simd_float2 bboxCenter = [self bboxCenterOfPath:p];
    // Anchor offset in object space: subtract bbox center and the layer's
    // visual translation (so dragging the handle to a screen location
    // resolves to the correct bbox-local pivot).
    simd_float2 anchorOffset = mouseObj - bboxCenter - translation;

    BOOL snapDisabled = (modifiers & kFxModifierKey_OPTION) != 0;
    if (!snapDisabled) {
      simd_float2 bmin, bmax;
      if (p.isGroup)
        [self boundsOfGroup:p min:&bmin max:&bmax];
      else
        [self boundsOfPath:p min:&bmin max:&bmax];
      float bw = bmax.x - bmin.x;
      float bh = bmax.y - bmin.y;
      // 17 targets in bbox-local normalized space, mapped to object-space
      // offsets from bbox center via (bw, bh). Mirrors MM's anchor target
      // set (corners, edges, thirds, center).
      simd_float2 targets[17] = {
          {0, 0},
          {-0.5f * bw, -0.5f * bh},
          {0.5f * bw, -0.5f * bh},
          {-0.5f * bw, 0.5f * bh},
          {0.5f * bw, 0.5f * bh},
          {0, -0.5f * bh},
          {0.5f * bw, 0},
          {0, 0.5f * bh},
          {-0.5f * bw, 0},
          {-bw / 6.0f, -0.5f * bh},
          {bw / 6.0f, -0.5f * bh},
          {-bw / 6.0f, 0.5f * bh},
          {bw / 6.0f, 0.5f * bh},
          {-0.5f * bw, -bh / 6.0f},
          {-0.5f * bw, bh / 6.0f},
          {0.5f * bw, -bh / 6.0f},
          {0.5f * bw, bh / 6.0f},
      };
      CGPoint c0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
      CGPoint c1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
      float pixPerUnit = (float)fabs(c1.x - c0.x);
      anchorOffset = [self.anchorSnapEngine snapObjectPoint:anchorOffset
                                                  toTargets:targets
                                                      count:17
                                              pixelsPerUnit:pixPerUnit];
    } else {
      [self.anchorSnapEngine reset];
    }

    id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [actAPI startAction:self];
    [setAPI setXValue:anchorOffset.x
               YValue:anchorOffset.y
          toParameter:kParamAnchor
               atTime:time];
    [actAPI endAction:self];
    *forceUpdate = YES;
    return;
  }
  if (self.stepperDragging) {
    [self handleStepperDragAtY:positionY
                     modifiers:modifiers
                   forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIsMarquee) {
    self.marqueeEnd = CGPointMake(positionX, positionY);
    *forceUpdate = YES;
    return;
  }
  if (self.dragIsLine) {
    [self dragLineToX:positionX
                    y:positionY
            modifiers:modifiers
          forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIsRect || self.dragIsEllipse) {
    [self dragRectToX:positionX
                    y:positionY
            modifiers:modifiers
          forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIsSelection) {
    if (self.autoSelectPending) {
      CGFloat dx = positionX - self.autoSelectClickOrigin.x;
      CGFloat dy = positionY - self.autoSelectClickOrigin.y;
      if (hypot(dx, dy) < 4.0)
        return;
      self.autoSelectPending = NO;
    }
    [self dragSelectionToX:positionX
                         y:positionY
                 modifiers:modifiers
               forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIndex == -2) {
    [self dragCornerRadiusAtX:positionX
                            y:positionY
                    modifiers:modifiers
                  forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIsRotation) {
    [self dragRotateAtX:positionX
                      y:positionY
              modifiers:modifiers
            forceUpdate:forceUpdate];
    return;
  }
  if (self.dragResizeHandle >= 0) {
    [self dragResizeAtX:positionX
                      y:positionY
              modifiers:modifiers
            forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIsPath) {
    [self dragPathToX:positionX
                    y:positionY
            modifiers:modifiers
          forceUpdate:forceUpdate];
    return;
  }
  [self dragPointOrHandleToX:positionX
                           y:positionY
                   modifiers:modifiers
                 forceUpdate:forceUpdate];
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  if (self.positionPathDragSegIndex >= 0 ||
      self.positionPathDragPointIndex >= 0) {
    self.positionPathDragSegIndex = -1;
    self.positionPathDragPointIndex = -1;
    self.positionPathDragIsInHandle = NO;
    self.positionPathDragIsOutHandle = NO;
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor arrowCursor]];
    *forceUpdate = YES;
    [super mouseUpAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
    return;
  }

  BOOL transformDragEnded = NO;
  if (self.transformPositionDragging) {
    self.transformPositionDragging = NO;
    self.transformPositionHovered = NO;
    transformDragEnded = YES;
  } else if (self.scaleRingDragging) {
    self.scaleRingDragging = NO;
    self.scaleRingHovered = NO;
    transformDragEnded = YES;
  } else if (self.anchorDragging) {
    self.anchorDragging = NO;
    self.anchorHovered = NO;
    transformDragEnded = YES;
  } else if (self.rotZDragging) {
    self.rotZDragging = NO;
    self.rotZHovered = NO;
    transformDragEnded = YES;
  } else if (self.rotXRingDragging) {
    self.rotXRingDragging = NO;
    self.rotXRingHovered = NO;
    transformDragEnded = YES;
  } else if (self.rotYRingDragging) {
    self.rotYRingDragging = NO;
    self.rotYRingHovered = NO;
    transformDragEnded = YES;
  }
  if (transformDragEnded) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor arrowCursor]];
    *forceUpdate = YES;
    [super mouseUpAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
    return;
  }
  if (self.stepperDragging) {
    self.stepperDragging = NO;
    self.stepperShiftWasDown = NO;
  }
  if (self.autoSelectPending) {
    self.autoSelectPending = NO;
    double hitRadiusStroke = [self strokeHitRadius];
    NSInteger frontPath = [self pathIndexNearX:positionX
                                             y:positionY
                                        radius:hitRadiusStroke];
    if (frontPath >= 0 && ![self.selectedPathIndices containsIndex:frontPath]) {
      NSIndexSet *prevSel = [self.selectedPathIndices copy];
      [self.selectedPathIndices removeAllIndexes];
      [self.selectedPathIndices addIndex:frontPath];
      self.activePathIndex = frontPath;
      [self resetDragState];
      [self syncStrokeParamsToSelectionWithPrevious:prevSel];
      *forceUpdate = YES;
      [super mouseUpAtPositionX:positionX
                      positionY:positionY
                     activePart:activePart
                      modifiers:modifiers
                    forceUpdate:forceUpdate
                         atTime:time];
      return;
    }
  }

  if (self.dragIsMarquee)
    [self finalizeMarqueeAtX:positionX y:positionY modifiers:modifiers];
  if (self.dragIsRect)
    [self finalizeRect];
  if (self.dragIsEllipse)
    [self finalizeEllipse];
  if (self.dragIsLine)
    [self finalizeLine];

  [self resetDragState];
  [self resetAlignSnap];
  [self syncStrokeParamsToSelection];
  *forceUpdate = YES;
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
