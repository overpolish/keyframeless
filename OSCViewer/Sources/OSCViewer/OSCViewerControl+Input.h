/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "OSCViewerControl.h"

// Everything the pointer and the keyboard reach: hit precedence, cursor
// arbitration, the drags and their per-tick undo groups, and the callbacks that
// bring a playhead-hidden control back. Declared here so the class reads as
// conforming to FxOnScreenControl_v4 wherever it is compiled, and split out
// because the control itself keeps only lifecycle, host geometry and the saved
// visibility reads.
@interface OSCViewerControl (Input)
- (void)hitTestOSCAtMousePositionX:(double)x mousePositionY:(double)y
                        activePart:(NSInteger *)activePart atTime:(CMTime)time;
- (void)mouseDownAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time;
- (void)mouseDraggedAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                      modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time;
- (void)mouseUpAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                 modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time;
- (void)mouseEnteredAtPositionX:(double)x positionY:(double)y modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time;
- (void)mouseExitedAtPositionX:(double)x positionY:(double)y modifiers:(FxModifierKeys)modifiers
                   forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time;
- (void)mouseMovedAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time;
- (void)keyDownAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key
                 modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle atTime:(CMTime)time;
- (void)keyUpAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key
               modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate
               didHandle:(BOOL *)didHandle atTime:(CMTime)time;
@end
