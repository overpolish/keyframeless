/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathEditController_Internal.h"
#import "CanvasPathEditGeometry.h" // insert-anchor + auto-smooth maths
#import "CanvasPathMorph.h"        // per-keypose geometry writes + keypose ops
#import <KeyframelessKit/KKBezierPath.h>

// PUBLIC methods (declared in CanvasPathEditController.h) implemented here as
// part of the intentional category split - silence the warning that they're not
// in the primary @implementation (which suppresses the matching -Wincomplete).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasPathEditController (Topology)

- (BOOL)penInsertAtX:(double)x y:(double)y {
  if ([self _animatedOffKeypose])
    return NO;
  if ([self hitTestAtX:x y:y] != CanvasPathEditHitNone)
    return NO; // on an existing anchor / handle: not an insert (remove/convert
               // later)
  NSUInteger seg;
  double t;
  if (![self _segmentHitAtX:x y:y outSeg:&seg outT:&t])
    return NO;
  KKBezierPath *base = [self _path];
  KKBezierPath *working = [self _workingPath];
  if (!base || !working)
    return NO;
  KKBezierPath *edited = CanvasPathByInsertingAnchor(working, seg, t);
  NSUInteger newIdx = seg + 1;

  double frac = [_surface penEditFraction];
  KKBezierPath *result = CanvasPathByWritingWorkingGeometry(base, frac, edited);
  NSMutableArray<KKBezierPath *> *paths = [[_surface penAllLayers] mutableCopy];
  for (NSUInteger i = 0; i < paths.count; i++)
    if ([paths[i].layerID isEqualToString:base.layerID]) {
      paths[i] = result;
      break;
    }
  // Preview only: the split preserves the rendered shape, so don't write the
  // param here (that would be a separate undo step from the drag); the OSC
  // reads the snapshot to show the new anchor, and mouseUp commits the one
  // undo.
  [_surface penPreviewLayers:paths];

  // Select + grab the new anchor so a press-insert-drag adjusts it; mouseUp
  // commits the whole thing as one undo.
  [_selectedAnchors removeAllIndexes];
  [_selectedAnchors addIndex:newIdx];
  _grabAnchor = (NSInteger)newIdx;
  _grabIsHandle = NO;
  _dragStartGeom = [edited copy];
  _dragging = YES;
  _didDrag = NO;
  _didEdit = YES;
  return YES;
}

- (BOOL)removeAnchorAtX:(double)x y:(double)y {
  NSInteger a = -1;
  BOOL ho = NO;
  if ([self _hitAtX:x y:y outAnchor:&a
          outHandleOut:&ho] != CanvasPathEditHitAnchor ||
      a < 0)
    return NO; // only an anchor hit removes (a handle hit is a future convert)
  return [self
      removeAnchorsAtIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)a]];
}

- (BOOL)removeAnchorsAtIndexes:(NSIndexSet *)indexes {
  return [self removeAnchorsAtIndexes:indexes breakPath:NO];
}

- (BOOL)removeAnchorsAtIndexes:(NSIndexSet *)indexes breakPath:(BOOL)breakPath {
  if ([self _animatedOffKeypose] || indexes.count == 0)
    return NO;
  KKBezierPath *base = [self _path];
  KKBezierPath *working = [self _workingPath];
  if (!base || !working)
    return NO;
  double frac = [_surface penEditFraction];
  NSInteger kp =
      CanvasPathActiveKeyposeAtFraction(base, frac, kCanvasPathKeyposeEps);

  KKBezierPath *edited;
  // The "open at deletion" behavior only makes sense for a single closed loop; a
  // multi-contour path (boolean result) falls through to removeAtIndex so its
  // other subpaths stay intact.
  BOOL singleContour = (working.contourCount <= 1);
  if (breakPath && working.closed && kp < 0 && working.count >= 2 &&
      singleContour) {
    // Destructive (cursor) delete on a CLOSED constant path: OPEN it at the
    // deletion - reorder the survivors to start just after the first deleted
    // anchor and drop the deleted ones, so the gap lands exactly where the
    // point was (matches Illustrator's Direct-Selection delete). closed = NO.
    NSUInteger n = working.count;
    NSUInteger brk = indexes.firstIndex;
    KKBezierPoint *pts = malloc(n * sizeof(KKBezierPoint));
    NSUInteger *origIdx = malloc(n * sizeof(NSUInteger));
    NSUInteger m = 0;
    for (NSUInteger k = 1; k <= n; k++) {
      NSUInteger idx = (brk + k) % n;
      if ([indexes containsIndex:idx])
        continue;
      origIdx[m] = idx;
      pts[m++] = [working pointAtIndex:idx];
    }
    edited = [working copy];
    [edited setBezierPoints:pts count:m closed:NO];
    // setBezierPoints clears the per-anchor radii - re-apply each survivor's
    // radius in the NEW order, else deleting one point drops every rounding.
    if (working.hasCornerRadii)
      for (NSUInteger j = 0; j < m; j++)
        [edited setCornerRadius:[working cornerRadiusAtIndex:origIdx[j]]
                        atIndex:j];
    free(pts);
    free(origIdx);
  } else {
    // Smart (pen) delete, or an open / animated / multi-contour path: remove the
    // anchors and let the neighbours reconnect, preserving the closed flag.
    // removeAtIndex keeps the survivors' corner radii in step on its own.
    edited = [working copy];
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      if (i < working.count)
        [order addObject:@(i)];
    }];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
      return
          [b compare:a]; // DESCENDING so earlier removals don't shift the rest
    }];
    if (order.count == 0)
      return NO;
    for (NSNumber *nn in order)
      [edited removeAtIndex:nn.unsignedIntegerValue];
    // removeAtIndex doesn't shift the contour boundaries, so rebuild them for a
    // multi-contour path - otherwise the survivors' subpaths render joined.
    if (working.contourCount > 1) {
      NSMutableArray<NSNumber *> *newStarts = [NSMutableArray array];
      for (NSUInteger c = 0; c < working.contourCount; c++) {
        NSRange r = [working contourRangeAtIndex:c];
        __block NSUInteger removedBeforeStart = 0, removedInContour = 0;
        [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
          if (idx < r.location)
            removedBeforeStart++;
          else if (idx < NSMaxRange(r))
            removedInContour++;
        }];
        if (c > 0 && (r.length - removedInContour) > 0)
          [newStarts addObject:@(r.location - removedBeforeStart)];
      }
      [edited setContourStarts:newStarts];
    }
  }

  NSString *targetID = base.layerID;
  BOOL deleteLayer = NO;
  KKBezierPath *result = nil;
  if (edited.count >= 2) {
    result = CanvasPathByWritingWorkingGeometry(base, frac, edited);
  } else {
    // Non-viable at this fraction: drop the keypose (animated) or the layer.
    if (kp < 0) {
      deleteLayer = YES; // constant path emptied -> delete the layer
    } else {
      result = CanvasPathByRemovingKeypose(base, (NSUInteger)kp);
      deleteLayer = (result == nil);
    }
  }

  [_selectedAnchors removeAllIndexes];
  [self _publishSelection]; // anchors removed - sync the now-empty selection
  [_surface
      penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
        for (NSUInteger i = 0; i < paths.count; i++)
          if ([paths[i].layerID isEqualToString:targetID]) {
            if (deleteLayer)
              [paths removeObjectAtIndex:i];
            else if (result)
              paths[i] = result;
            break;
          }
      }
      selectLayerID:nil];
  return YES;
}

- (BOOL)_toggleSmoothAtIndex:(NSUInteger)idx {
  if ([self _animatedOffKeypose])
    return NO;
  KKBezierPath *base = [self _path];
  KKBezierPath *working = [self _workingPath];
  if (!base || !working || idx >= working.count)
    return NO;
  KKBezierPath *edited = [working copy];
  KKBezierPoint pt = [edited pointAtIndex:idx];
  BOOL smooth =
      (fabsf(pt.outX) + fabsf(pt.outY) + fabsf(pt.inX) + fabsf(pt.inY) > 1e-6f);
  if (smooth) { // -> corner: drop the handles
    [edited setInHandle:simd_make_float2(0, 0) atIndex:idx];
    [edited setOutHandle:simd_make_float2(0, 0) atIndex:idx];
    [edited setType:KKBezierPointLinear atIndex:idx];
  } else { // -> smooth: auto-tangents
    CanvasPathAutoSmoothAnchor(edited, idx, (float)[_surface penCanvasAspect]);
  }
  double frac = [_surface penEditFraction];
  KKBezierPath *result = CanvasPathByWritingWorkingGeometry(base, frac, edited);
  NSString *targetID = base.layerID;
  [_surface
      penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
        for (NSUInteger i = 0; i < paths.count; i++)
          if ([paths[i].layerID isEqualToString:targetID]) {
            paths[i] = result;
            break;
          }
      }
      selectLayerID:nil];
  return YES;
}

- (BOOL)toggleSmoothAtX:(double)x y:(double)y {
  NSInteger a = -1;
  BOOL ho = NO;
  if ([self _hitAtX:x y:y outAnchor:&a
          outHandleOut:&ho] != CanvasPathEditHitAnchor ||
      a < 0)
    return NO;
  return [self _toggleSmoothAtIndex:(NSUInteger)a];
}

@end

#pragma clang diagnostic pop
