//
//  RoundedKFPlugIn.h
//  RoundedKF
//
//  Created by Dom on 23/02/2026.
//

#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>

@interface RoundedKFPlugIn : NSObject <FxTileableEffect>
@property (assign) id<PROAPIAccessing> apiManager;
@end
