/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLocalized.h"
#import "CanvasOSC_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <KeyframelessKit/KKToolbar.h>

// kParamUIState keys for the toolbar + grid. These are SCREEN CHROME, not plugin
// parameters - they live in the UI-state dict (so they're remembered) and never
// affect the render output, only the editing overlay.
static NSString *const kCanvasUIToolbarPos = @"toolbarPos"; // @[nx, ny] (0..1)
static NSString *const kCanvasUITool = @"tool";             // active drawing tool
static NSString *const kCanvasUIGridEnabled = @"gridEnabled";
static NSString *const kCanvasUIGridAdaptive = @"gridAdaptive";
static NSString *const kCanvasUIGridSpacing = @"gridSpacing";
static NSString *const kCanvasUIGridSnap = @"gridSnap";

@implementation CanvasOSC (Toolbar)

- (void)_setupToolbar {
  // Shared builder (same bar in the viewer + mini); per-frame state is driven in
  // _drawToolbarWithWidth:.
  self.toolbar = CanvasMakeToolbar(self.apiManager);
}

- (NSInteger)_activeTool {
  id v = [self _uiStateDict][kCanvasUITool];
  return v ? [v integerValue] : CanvasToolbarToolCursor;
}

- (void)_drawToolbarWithWidth:(NSInteger)width
                       height:(NSInteger)height
             destinationImage:(FxImageTile *)destinationImage {
  if (!self.toolbar)
    return;
  self.toolbarIOSize = CGSizeMake(width, height);
  NSDictionary *ui = [self _uiStateDict];
  NSInteger tool =
      ui[kCanvasUITool] ? [ui[kCanvasUITool] integerValue] : CanvasToolbarToolCursor;
  BOOL gridOn = [ui[kCanvasUIGridEnabled] boolValue];
  BOOL adaptive =
      ui[kCanvasUIGridAdaptive] ? [ui[kCanvasUIGridAdaptive] boolValue] : YES;
  BOOL snap = [ui[kCanvasUIGridSnap] boolValue];
  NSInteger spacing =
      ui[kCanvasUIGridSpacing] ? [ui[kCanvasUIGridSpacing] integerValue] : 10;

  CanvasToolbarApplyState(self.toolbar, tool, gridOn, adaptive, snap, spacing);

  // Position from UI state (normalised), or the anchored bottom-centre default
  // until the user drags it. Skipped mid-drag: the drag sets anchorCenter live.
  if (!self.toolbarDragging) {
    NSArray *pos = ui[kCanvasUIToolbarPos];
    if ([pos isKindOfClass:[NSArray class]] && pos.count == 2) {
      self.toolbar.usesAnchorCenter = YES;
      self.toolbar.anchorCenter = CGPointMake([pos[0] doubleValue] * width,
                                              [pos[1] doubleValue] * height);
    } else {
      self.toolbar.usesAnchorCenter = NO;
    }
  }
  [self.toolbar drawWithDestinationImage:destinationImage];
}

- (NSInteger)_toolbarHitTestAtX:(double)x y:(double)y {
  return self.toolbar ? [self.toolbar hitTestAtX:x y:y] : 0;
}

- (BOOL)_gridEnabled {
  return [[self _uiStateDict][kCanvasUIGridEnabled] boolValue];
}

- (BOOL)_gridAdaptive {
  id v = [self _uiStateDict][kCanvasUIGridAdaptive];
  return v ? [v boolValue] : YES;
}

- (NSInteger)_gridSpacing {
  id v = [self _uiStateDict][kCanvasUIGridSpacing];
  NSInteger s = v ? [v integerValue] : 10;
  return s < 1 ? 1 : s;
}

- (BOOL)_gridSnap {
  return [[self _uiStateDict][kCanvasUIGridSnap] boolValue];
}

- (void)_toggleUIBool:(NSString *)key default:(BOOL)def {
  BOOL cur = [self _uiStateDict][key] ? [[self _uiStateDict][key] boolValue]
                                      : def;
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[key] = @(!cur);
  }];
}

- (void)_cycleGridSpacing {
  id v = [self _uiStateDict][kCanvasUIGridSpacing];
  NSInteger next = CanvasToolbarNextGridSpacing(v ? [v integerValue] : 0);
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[kCanvasUIGridSpacing] = @(next);
  }];
}

- (BOOL)_handleToolbarKey:(unsigned short)asciiKey
                modifiers:(NSUInteger)modifiers {
  // Only the Control+letter tool shortcuts shown on the toolbar. With Control
  // held the ASCII value is the control character (letter - 64): V=22, X=24,
  // B=2, G=7 -> recover the lowercase letter (+96) for the shared mapping.
  if (!(modifiers & kFxModifierKey_CONTROL))
    return NO;
  NSInteger tag = CanvasToolbarToolTagForLetter((unichar)(asciiKey + 96));
  if (tag == 0)
    return NO;
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[kCanvasUITool] = @(tag);
  }];
  return YES;
}

- (void)_toolbarMouseDownTag:(NSInteger)tag atX:(double)x y:(double)y {
  switch (tag) {
  case CanvasToolbarDragHandle: {
    self.toolbarDragging = YES;
    self.toolbarPressMouse = CGPointMake(x, y);
    NSRect f = self.toolbar.toolbarFrame;
    self.toolbarPressCenter = CGPointMake(NSMidX(f), NSMidY(f));
    break;
  }
  case CanvasToolbarToolCursor:
  case CanvasToolbarToolPen:
  case CanvasToolbarToolRect:
  case CanvasToolbarToolEllipse:
    // Radio: store the selected tool (UNWIRED - drawing returns later).
    [self _writeUIStateMerging:^(NSMutableDictionary *state) {
      state[kCanvasUITool] = @(tag);
    }];
    break;
  case CanvasToolbarGrid:
    [self _toggleUIBool:kCanvasUIGridEnabled default:NO];
    break;
  case CanvasToolbarGridAdaptive:
    [self _toggleUIBool:kCanvasUIGridAdaptive default:YES];
    break;
  case CanvasToolbarSnap:
    [self _toggleUIBool:kCanvasUIGridSnap default:NO];
    break;
  case CanvasToolbarGridSpacing:
    [self _cycleGridSpacing];
    break;
  default:
    break;
  }
}

- (void)_toolbarMouseDraggedAtX:(double)x y:(double)y {
  if (!self.toolbarDragging)
    return;
  // Live (no persist - draw keeps anchorCenter while dragging); the host redraws
  // because the caller sets forceUpdate.
  self.toolbar.usesAnchorCenter = YES;
  self.toolbar.anchorCenter =
      CGPointMake(self.toolbarPressCenter.x + (x - self.toolbarPressMouse.x),
                  self.toolbarPressCenter.y + (y - self.toolbarPressMouse.y));
}

- (void)_toolbarMouseUp {
  if (!self.toolbarDragging)
    return;
  self.toolbarDragging = NO;
  CGSize io = self.toolbarIOSize;
  if (io.width <= 0 || io.height <= 0)
    return;
  // Persist the settled centre once (normalised to the viewport so it survives
  // zoom / size changes). The clamp in KKToolbar keeps it fully on-screen.
  CGPoint c = self.toolbar.anchorCenter;
  double nx = c.x / io.width, ny = c.y / io.height;
  [self _writeUIStateMerging:^(NSMutableDictionary *state) {
    state[kCanvasUIToolbarPos] = @[ @(nx), @(ny) ];
  }];
}

@end
