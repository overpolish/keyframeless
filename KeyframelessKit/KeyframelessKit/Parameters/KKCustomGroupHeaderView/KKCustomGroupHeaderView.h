//
//  KKCustomGroupHeaderView.h
//  KeyframelessKit
//
//  Created by Dom on 27/02/2026.
//

#import <KeyframelessKit/KKNativeStyleView.h>
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

@interface KKCustomGroupHeaderView : KKNativeStyleView

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
                        label:(NSString *)label;

@end

NS_ASSUME_NONNULL_END
