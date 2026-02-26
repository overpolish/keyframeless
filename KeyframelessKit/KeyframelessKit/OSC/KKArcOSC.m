//
//  KKArcOSC.m
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#import <FxPlug/FxPlugSDK.h>
#import "KKArcOSC.h"
#import "KKMetalDeviceCache.h"
#import "KKRenderHelpers.h"
#import "KKOSCShaderTypes.h"
#import "KKColors.h"

static NSString *kArcOSCPluginID = @"co.overpolish.keyframelesskit.arcosc";

@implementation KKArcOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
{
    self = [super initWithAPIManager:apiManager];
    if (self)
    {
        _oscRadius      = 23.0f;
        _strokeWidth    = 10.0f;
        _outlineWidth   = 2.0f;
        
        _primaryColor   = KKColor_Primary;
        _outlineColor   = KKColor_Outline;
        _hoverColor     = KKColor_Hover;
        _activeColor    = KKColor_Active;
    }
    return self;
}

- (float)hitRadius
{
    return _oscRadius + _outlineWidth;
}

- (float)oscSize
{
    return (_oscRadius + _strokeWidth + _outlineWidth) / 2.0f;
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                 positionY:(double)positionY
                         atTime:(CMTime)time
{
    CGPoint pos = [self oscPositionAtTime:time];
    double dx = positionX - pos.x;
    double dy = positionY - pos.y;
    return sqrt(dx*dx + dy*dy) <= self.hitRadius;
}

- (id<MTLRenderPipelineState>)arcPipelineStateForRegistryID:(uint64_t)registryID
{
    KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
    
    id<MTLRenderPipelineState> ps = [cache pipelineStateForPluginID:kArcOSCPluginID
                                                         registryID:registryID
                                                        pixelFormat:MTLPixelFormatRGBA8Unorm];
    
    if (ps) return ps;
    
    id<MTLDevice> device = [cache deviceWithRegistryID:registryID];
    NSBundle *bundle = [NSBundle bundleWithIdentifier:@"co.overpolish.keyframeless.KeyframelessKit"];
    NSError *error = nil;
    
    id<MTLLibrary> lib = [device newDefaultLibraryWithBundle:bundle error:&error];
    if (!lib || error)
    {
        NSLog(@"KKArcOSC: Failed to load KeyframelessKit Metal library: %@", error);
        return nil;
    }
    
    id<MTLFunction> vertFn = [lib newFunctionWithName:@"KKVertexShader"];
    id<MTLFunction> fragFn = [lib newFunctionWithName:@"KKOSCRingFragment"];
    
    if (!vertFn || !fragFn)
    {
        NSLog(@"KKArcOSC: Required shaders not found in library.");
        return nil;
    }
    
    MTLRenderPipelineDescriptor *desc = [KKRenderHelpers createPipelineDescriptorWithVertexFunction:vertFn
                                                                                   fragmentFunction:fragFn
                                                                                        pixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          blendMode:KKBlendModeStraightAlpha];
    
    ps = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!ps || error)
    {
        NSLog(@"KKArcOSC: Failed to create pipeline state: %@", error);
        return nil;
    }
    
    [cache registerPipelineState:ps forPluginID:kArcOSCPluginID registryID:registryID pixelFormat:MTLPixelFormatRGBA8Unorm];
    return ps;
}

- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time
{
    id<MTLRenderPipelineState> ps = [self arcPipelineStateForRegistryID:destinationImage.deviceRegistryID];
    if (!ps) return;
    
    simd_float4 color = isActive ? _activeColor : (isHovered ? _hoverColor : _primaryColor);
    float outerRadiusPixels = self.oscRadius + self.outlineWidth;
    
    KKOSCRingParams params = {
        .innerRadius = (_oscRadius - _strokeWidth) / outerRadiusPixels,
        .outlineWidth = _outlineWidth / outerRadiusPixels,
        .fillColor = color,
        .outlineColor = _outlineColor
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
