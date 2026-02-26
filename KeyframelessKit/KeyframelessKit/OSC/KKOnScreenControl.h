//
//  KKOnScreenControl.h
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

@class FxImageTile;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

@interface KKOnScreenControl : NSObject

@property (nonatomic, weak) id<PROAPIAccessing> apiManager;
@property (nonatomic, readonly) BOOL isHovered;
@property (nonatomic, readonly) BOOL isDragging;

@property (nonatomic) simd_float4 primaryColor;
@property (nonatomic) simd_float4 outlineColor;
@property (nonatomic) simd_float4 hoverColor;
@property (nonatomic) simd_float4 activeColor;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Override to provide plugin ID for pipeline state caching.
- (NSString *)pipelinePluginID;

/// Override to provide the fragment shader function name.
- (NSString *)fragmentFunctionName;

/// Selects the appropriate color based on hover/active state.
- (simd_float4)colorForHovered:(BOOL)isHovered active:(BOOL)isActive;

/// Loads or retrieves cached pipeline state for the given registry ID.
- (nullable id<MTLRenderPipelineState>)pipelineStateForRegistryID:(uint64_t)registryID;

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

/// Shared Metal setup/teardown. Call from drawAtCanvasPosition: with a block
/// containing your encoder commands. Handles device, queue, command buffer,
/// render pass, viewport, and cleanup automatically.
- (void)encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                                 canvasPosition:(CGPoint)canvasPosition
                                       commands:(void (^)(id<MTLRenderCommandEncoder> encoder,
                                                          CGPoint metalPosition,
                                                          simd_uint2 viewportSize))commands;

@end

NS_ASSUME_NONNULL_END
