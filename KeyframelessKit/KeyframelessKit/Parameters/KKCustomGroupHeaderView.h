//
//  KKCustomGroupHeaderView.h
//  KeyframelessKit
//
//  Created by Dom on 27/02/2026.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

@interface KKCustomGroupHeaderView : NSView

@property (nonatomic, strong) NSButton *chevronButton;
@property (nonatomic, strong) NSTextField *labelField;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, assign) CGFloat currentRotation;
@property (nonatomic, strong) id<PROAPIAccessing> apiManager;
@property (nonatomic, strong) NSView *customView;

- (instancetype)initWithFrame:(NSRect)frame apiManager:(id<PROAPIAccessing>)apiManager
                        label:(NSString *)label
                   customView:(NSView *)customView;

@end

NS_ASSUME_NONNULL_END
