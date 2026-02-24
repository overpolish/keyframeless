//
//  RoundedOSC.h
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>

@interface RoundedOSC : NSObject <FxOnScreenControl_v4>
@property (assign) id<PROAPIAccessing> apiManager;
@end
