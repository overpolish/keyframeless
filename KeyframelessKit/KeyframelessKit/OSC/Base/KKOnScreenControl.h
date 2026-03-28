/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

@class FxImageTile;
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

/// Loads or retrieves cached pipeline state matching the destination image's
/// pixel format.
- (nullable id<MTLRenderPipelineState>)pipelineStateForDestinationImage:
    (FxImageTile *)destinationImage;

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
