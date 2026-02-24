//
//  RoundedPlugIn.h
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>

@interface RoundedPlugIn : NSObject <FxTileableEffect>
@property (assign) id<PROAPIAccessing> apiManager;
@end
