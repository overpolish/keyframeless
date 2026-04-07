/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>

@implementation TemplateOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return CGPointZero;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  CGPoint center = [self oscPositionAtTime:time];
  [self drawAtCanvasPosition:center
                   isHovered:(activePart == 1)
                    isActive:self.isDragging && (activePart == 1)
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  if ([self hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    *activePart = 1;
  }
}

@end
