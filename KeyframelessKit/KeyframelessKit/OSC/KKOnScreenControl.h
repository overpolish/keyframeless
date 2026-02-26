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
@protocol FxOnScreenControl_v4;

NS_ASSUME_NONNULL_BEGIN

@interface KKOnScreenControl : NSObject <FxOnScreenControl_v4>

@property (nonatomic, weak) id<PROAPIAccessing> apiManager;
@property (nonatomic, readonly) BOOL isHovered;
@property (nonatomic, readonly) BOOL isDragging;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Override to return the canvas-space position of the OSC center.
- (CGPoint)oscPositionAtTime:(CMTime)time;

/// Override to determine if the mouse position hits this OSC. Required;
- (BOOL)hitTestAtMousePositionX:(double)mousePositionX
                      mousePositionY:(double)mousePositionY
                         atTime:(CMTime)time;

/// Override to perform actual Metal draw.
- (void)drawAtCanvasPosition:(CGPoint)position
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
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
