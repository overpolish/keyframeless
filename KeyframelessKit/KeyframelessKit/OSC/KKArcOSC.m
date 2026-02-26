//
//  KKArcOSC.m
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#import <FxPlug/FxPlugSDK.h>
#import "KKArcOSC.h"
#import "KKRenderHelpers.h"
#import "KKOSCShaderTypes.h"


@implementation KKArcOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
{
    self = [super initWithAPIManager:apiManager];
    if (self)
    {
        _oscRadius      = 23.0f;
        _strokeWidth    = 10.0f;
        _outlineWidth   = 2.0f;
    }
    return self;
}

- (NSString *)pipelinePluginID { return @"co.overpolish.keyframelesskit.ArcOSC"; }
- (NSString *)fragmentFunctionName { return @"KKArcOSCFragment"; }

- (float)hitRadius { return _oscRadius + _outlineWidth; }
- (float)oscSize { return (_oscRadius + _strokeWidth + _outlineWidth) / 2.0f; }

- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time
{
    id<MTLRenderPipelineState> ps = [self pipelineStateForRegistryID:destinationImage.deviceRegistryID];
    if (!ps) return;
    
    float outerRadiusPixels = _oscRadius + _outlineWidth;
    
    KKArcOSCParams params = {
        .innerRadius = (_oscRadius - _strokeWidth) / outerRadiusPixels,
        .outlineWidth = _outlineWidth / outerRadiusPixels,
        .fillColor = [self colorForHovered:isHovered active:isActive],
        .outlineColor = self.outlineColor
    };
    
    [self encodeRenderCommandsForDestinationImage:destinationImage
                                   canvasPosition:canvasPosition
                                         commands:^(id<MTLRenderCommandEncoder> encoder,
                                                    CGPoint metalPosition,
                                                    simd_uint2 viewportSize){
        KKVertex2D quadVertices[6];
        [KKRenderHelpers generateQuadVertices:quadVertices
                                       center:metalPosition
                                         size:outerRadiusPixels];
        
        [encoder setRenderPipelineState:ps];
        [encoder setVertexBytes:quadVertices length:sizeof(quadVertices) atIndex:KKVertexInputIndex_Vertices];
        [encoder setVertexBytes:&viewportSize length:sizeof(viewportSize) atIndex:KKVertexInputIndex_ViewportSize];
        [encoder setFragmentBytes:&params length:sizeof(params) atIndex:KKOSCFragmentIndex_DrawColor];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }];
}


@end
