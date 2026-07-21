/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKMiniViewerView.h>

@class KKLane;

NS_ASSUME_NONNULL_BEGIN

/// Manages the mini-viewer siblings of the viewer's custom `// @osc` handles
/// (ShaderOSC's expr blocks). One fixed glyph per block, drawn at the block's
/// forward-expression object point and dragged by numerically inverting the
/// forward (or evaluating its explicit inverse) - the SAME
/// ShaderOSCBlockRuntime the viewer uses, so both sit and drag identically.
/// Reads/writes the host through KKMiniViewerRenderer's public hooks. The mini
/// analogue of the viewer's expr-handle loop in ShaderOSC, and the `// @osc`
/// cousin of KKRingOSCSet.
@interface ShaderExprMiniSet : NSObject

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer;

/// Rebuild from the shader source (parse + compile via ShaderOSCBlockRuntime).
/// Cheap string-compare no-op when unchanged. `lanes` seed a first write.
- (void)syncWithSource:(nullable NSString *)src
                 lanes:(NSArray<KKLane *> *)lanes;

/// `@{@"center", @"style", @"alpha"}` bundles for the active handles. Forward
/// -miniViewer:extraFixedGlyphsForContentRect: here.
- (NSArray<NSDictionary<NSString *, id> *> *)glyphBundlesForContentRect:
    (CGRect)cr;

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr;
- (nullable NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr;
/// Grab whatever handle is under `p`. YES if claimed (host should NOT fall
/// through to super).
- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas;
/// Live-update the active drag. YES if a drag is active.
- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas;
/// End the active drag. YES if a drag was active.
- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas;
/// Opt-click to hide the handle under `p`. YES if one toggled.
- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas;

@end

NS_ASSUME_NONNULL_END
