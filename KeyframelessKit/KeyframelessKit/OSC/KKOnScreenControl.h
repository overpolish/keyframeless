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

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Override to return the canvas-space position of the OSC center.
- (CGPoint)oscPositionAtTime:(CMTime)time;

/// Override to determine if the mouse position hits this OSC. Required;
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
