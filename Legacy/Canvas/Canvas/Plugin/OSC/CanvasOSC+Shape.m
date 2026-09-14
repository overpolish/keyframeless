/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSC_Private.h"
#import "CanvasShapeController.h"
#import <FxPlug/FxPlugSDK.h>

@implementation CanvasOSC (Shape)

- (BOOL)_shapeToolActive {
  NSInteger t = [self _activeTool];
  return t == CanvasToolbarToolRect || t == CanvasToolbarToolEllipse;
}

// Sync the controller's kind to the live tool before each gesture, so one
// controller serves both buttons.
- (void)_syncShapeKind {
  self.shapeController.kind = ([self _activeTool] == CanvasToolbarToolEllipse)
                                  ? CanvasShapeKindEllipse
                                  : CanvasShapeKindRect;
}

- (void)_shapeMouseDownAtX:(double)x
                         y:(double)y
                 modifiers:(NSUInteger)modifiers {
  [self _syncShapeKind];
  [self.shapeController mouseDownAtX:x
                                   y:y
                           modifiers:CanvasPenModsFromFxModifiers(modifiers)];
}

- (void)_shapeMouseDraggedAtX:(double)x
                            y:(double)y
                    modifiers:(NSUInteger)modifiers {
  [self.shapeController
      mouseDraggedAtX:x
                    y:y
            modifiers:CanvasPenModsFromFxModifiers(modifiers)];
}

- (void)_shapeMouseUp {
  [self.shapeController mouseUp];
}

- (void)_drawShapeInProgressInDestination:(FxImageTile *)destinationImage
                                   atTime:(CMTime)time {
  self.penDrawDest = destinationImage;
  self.penDrawTime = time;
  [self.shapeController draw];
  self.penDrawDest = nil;
}

@end
