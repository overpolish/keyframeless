//
//  OSC.m
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>
#import "KeyframelessKit/KeyframelessKit.h"

@implementation OSC

- (CGPoint)oscPositionAtTime:(CMTime)time
{
    id<FxOnScreenControlAPI_v4> oscAPI = [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (!oscAPI) return CGPointZero;
    
    CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT fromX:1.0 fromY:1.0
                          toSpace:kFxDrawingCoordinates_CANVAS toX:&topRight.x toY:&topRight.y];
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT fromX:0.0 fromY:0.0
                          toSpace:kFxDrawingCoordinates_CANVAS toX:&bottomLeft.x toY:&bottomLeft.y];
    
    float canvasImageWidth  = topRight.x - bottomLeft.x;
    float canvasImageHeight = topRight.y - bottomLeft.y;
    BOOL isFlippedX = canvasImageWidth  < 0;
    BOOL isFlippedY = canvasImageHeight < 0;
    
    float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));
    float padding = minDim * 0.05f;
    
    id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    if (paramGetAPI) {
        double paramRadius = 0.0;
        [paramGetAPI getFloatValue:&paramRadius fromParameter:1 atTime:time];
        float t = paramRadius / 100.0f;
        float power = 5.0f * (1.0f - t) + 2.0f * t;
        float cornerRadiusPixels  = minDim * 0.5f * t;
        float circleInsetFactor   = 1.0f - 1.0f / sqrtf(2.0f);
        float squircleInsetFactor = 1.0f - 1.0f / powf(2.0f, 1.0f / power);
        float insetFactor         = squircleInsetFactor * (1.0f - t) + circleInsetFactor * t;
        float squircleCorrection  = 1.0f - 0.22f * sinf(t * M_PI);
        padding += cornerRadiusPixels * insetFactor * squircleCorrection;
    }
    
    float offsetX = isFlippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
    float offsetY = isFlippedY ? -(self.oscSize + padding) : (self.oscSize + padding);
    
    return CGPointMake(topRight.x - offsetX, topRight.y - offsetY);
}

@end
