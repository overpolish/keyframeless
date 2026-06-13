/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

@class FxImageTile;
@class NSCursor;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

@interface KKOnScreenControl : NSObject

@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
@property(nonatomic, readonly) BOOL isHovered;
@property(nonatomic, readonly) BOOL isDragging;

/// When YES (default), the convenience drawQuad method clears the destination
/// before drawing. Set to NO when compositing multiple controls into one image.
@property(nonatomic) BOOL clearsOnDraw;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Override to provide plugin ID for pipeline state caching.
- (NSString *)pipelinePluginID;

/// Override to provide the fragment shader function name.
- (NSString *)fragmentFunctionName;

/// The radius used for hit testing. Override in subclass.
- (float)hitRadius;

/// Half the full extent of the control. Override in subclass.
- (float)oscSize;

/// Override to return the canvas-space position of the OSC center.
- (CGPoint)oscPositionAtTime:(CMTime)time;

/// Standard distance-based hit test using hitRadius.
/// Override for non-circular hit testing.
- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time;

/// Override to perform actual Metal draw.
- (void)drawAtCanvasPosition:(CGPoint)position
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time;

/// Override to handle mouse drag. Call super to maintain isDragging state.
- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time;

/// Override to handle mouse down. Call super to maintain isDragging state.
- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time;

/// Override to handle mouse up. Call super to maintain isDragging state.
- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time;

/// Override to handle key down.
- (void)keyDownAtPositionX:(double)positionX
                 positionY:(double)positionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time;

/// YES while the user holds Option over the viewer. Hidden elements should then
/// be drawn as dimmed ghosts and made hit-testable so an opt-click re-shows
/// them. Maintained by -kkUpdateOptRevealWithModifiers:forceUpdate:; read it
/// from your drawOSC / hitTest to decide ghost rendering and hit gating.
@property(nonatomic) BOOL optRevealActive;

/// The element keys this control can hide (e.g. @"Position", @"Rotation.X",
/// @"Crop"). Override to opt into the visibility feature; the default @[]
/// leaves it inert. Keys must match the inspector pills + mini-viewer labels.
- (NSArray<NSString *> *)oscElementKeys;

/// The element key under `activePart` (granular - e.g. a specific rotation
/// ring). Override; return nil for parts that can't be hidden. Default nil.
- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart;

/// Param ID of the UI-state blob whose `oscElements` map is rewritten on
/// toggle. Default 201 (the established kParamUIState). Override if different.
- (UInt32)oscVisibilityParamID;

/// Whether an element is currently visible: master tick on AND not individually
/// hidden. Reads this instance's KKPluginInstanceState. Call from drawOSC /
/// hitTest to gate each control.
- (BOOL)kkOSCElementVisible:(NSString *)label;

/// YES when the master "all OSCs off" tick is off. In that state Option-hold is
/// a transient "peek and use" mode (every control reveals + is interactive)
/// rather than the per-element hide/show toggle, so callers gate on this.
- (BOOL)kkOSCMasterOff;

/// Whether `label` is hidden by its own pill (or an ancestor's, via the dotted
/// "Rotation"->"Rotation.X" hierarchy), independent of the master tick.
- (BOOL)kkOSCElementIndividuallyHidden:(NSString *)label;

/// Whether Option-hold should REVEAL `label` this frame. Master on: the
/// elements you individually hid (so an Opt-click re-shows them). Master off:
/// the elements left enabled (the "peek and use" set) - the ones you turned off
/// stay off. Use this in place of a bare `!kkOSCElementVisible:` /
/// `optRevealActive` reveal term so peek mirrors a flip back to master-on
/// rather than flashing everything.
- (BOOL)kkOSCRevealEligible:(NSString *)label;

/// Draw alpha for a revealed ghost. 0.3 (dimmed) in the normal case - a single
/// element you individually hid, previewed so you can opt-click it back. But
/// 1.0 (full) when the master is off: there the whole OSC is hidden and Opt is
/// the "peek and use" modifier, so the revealed controls read as fully usable,
/// not as dimmed re-show targets. Use in place of a literal 0.3 ghost alpha.
- (float)kkRevealGhostAlpha;

/// The Opt-hover visibility cursor for `label`, or nil if none applies. Returns
/// the `eye.slash` (hide) cursor when Opt is held over a visible, toggleable
/// element, or `eye` (show) over a revealed ghost - but nil in peek-and-use
/// mode (master off), where Opt-click doesn't toggle. Call from a hit-test when
/// the pointer is over `label`'s handle, e.g. `[oscAPI setCursor:[self
/// kkVisibilityCursorForLabel:lbl] ?: KKPointMoveCursor()]`.
- (nullable NSCursor *)kkVisibilityCursorForLabel:(NSString *)label;

/// Call at the top of mouseMoved:. Tracks the Option-reveal state (updates
/// optRevealActive and requests a redraw on change) and resets the per-press
/// opt-hide arming so the next press is judged fresh.
- (void)kkUpdateOptRevealWithModifiers:(NSUInteger)modifiers
                           forceUpdate:(BOOL *)forceUpdate;

/// Call at the top of mouseDown: and mouseDragged:. Latches the interaction's
/// nature on its first event: if Option is held over a hideable part, toggles
/// that element off (or back on, for a ghost) and returns YES - you should set
/// *forceUpdate = YES and return without dragging. Returns NO for a normal
/// drag.
- (BOOL)kkArmOptHideForActivePart:(NSInteger)activePart
                        modifiers:(NSUInteger)modifiers;

/// Call from mouseUp: to clear the per-interaction opt-hide arming.
- (void)kkResetOptHideArming;

@end

/// Metal draw helpers. Implemented in KKOnScreenControl+Drawing.m.
@interface KKOnScreenControl (Drawing)

/// Loads or retrieves cached pipeline state matching the destination image's
/// pixel format.
- (nullable id<MTLRenderPipelineState>)pipelineStateForDestinationImage:
    (FxImageTile *)destinationImage;

/// Draws a quad with the given fragment data. Handles pipeline, vertices,
/// viewport, and cleanup. Clears the destination by default.
- (void)drawQuadForDestinationImage:(FxImageTile *)destinationImage
                     canvasPosition:(CGPoint)canvasPosition
                      pipelineState:(id<MTLRenderPipelineState>)pipelineState
                       fragmentData:(const void *)fragmentData
                   fragmentDataSize:(size_t)fragmentDataSize
                               size:(float)size;

/// Same as above but allows preserving existing destination content.
- (void)drawQuadForDestinationImage:(FxImageTile *)destinationImage
                     canvasPosition:(CGPoint)canvasPosition
                   clearDestination:(BOOL)clear
                      pipelineState:(id<MTLRenderPipelineState>)pipelineState
                       fragmentData:(const void *)fragmentData
                   fragmentDataSize:(size_t)fragmentDataSize
                               size:(float)size;

/// Draws an antialiased line between two canvas-space points.
- (void)drawLineFrom:(CGPoint)canvasA
                  to:(CGPoint)canvasB
               color:(simd_float4)color
           halfWidth:(float)halfWidth
    destinationImage:(FxImageTile *)destinationImage;

/// Draws a connected strip of antialiased line segments in a single render
/// pass.
- (void)drawLineStripWithPoints:(const CGPoint *)points
                          count:(NSUInteger)count
                          color:(simd_float4)color
                      halfWidth:(float)halfWidth
               destinationImage:(FxImageTile *)destinationImage;

/// Draws disconnected antialiased line segments in a single render pass.
/// Points are consumed in pairs: (points[0]→points[1]),
/// (points[2]→points[3]), etc. Count must be even.
- (void)drawLineSegmentsWithPoints:(const CGPoint *)points
                             count:(NSUInteger)count
                             color:(simd_float4)color
                         halfWidth:(float)halfWidth
                  destinationImage:(FxImageTile *)destinationImage;

/// Low-level Metal setup/teardown. Use drawQuadForDestinationImage: for
/// standard quad rendering. This is for custom encoder commands. Clears the
/// destination.
- (void)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                             canvasPosition:(CGPoint)canvasPosition
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           CGPoint metalPosition,
                                           simd_uint2 viewportSize))commands;

/// Same as above but allows preserving existing destination content when
/// composing multiple controls into the same image.
- (void)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                             canvasPosition:(CGPoint)canvasPosition
                           clearDestination:(BOOL)clear
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           CGPoint metalPosition,
                                           simd_uint2 viewportSize))commands;

@end

NS_ASSUME_NONNULL_END
