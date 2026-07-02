/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasToolbar.h" // CanvasToolbarTool*

@implementation CanvasMiniViewerRenderer (Shape)

- (BOOL)_shapeToolActive {
  NSInteger t = self.toolbarTool ?: CanvasToolbarToolCursor;
  return t == CanvasToolbarToolRect || t == CanvasToolbarToolEllipse;
}

- (void)_syncShapeKind {
  self.shapeController.kind = ((self.toolbarTool ?: CanvasToolbarToolCursor) ==
                               CanvasToolbarToolEllipse)
                                  ? CanvasShapeKindEllipse
                                  : CanvasShapeKindRect;
}

@end
