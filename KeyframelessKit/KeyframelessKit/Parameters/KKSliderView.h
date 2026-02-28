//
//  KKSliderView.h
//  KeyframelessKit
//
//  Created by Dom on 27/02/2026.
//

#import <Cocoa/Cocoa.h>
#import <KeyframelessKit/KKNumberField.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

@interface KKSliderView : NSView
@property (nonatomic, strong) id<PROAPIAccessing> apiManager;
@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) KKNumberField *numberField;
@property (nonatomic, assign) double minValue;
@property (nonatomic, assign) double maxValue;
@property (nonatomic, assign) double doubleValue;
@property (nonatomic, assign) BOOL continuous;
@property (nonatomic, weak) id target;
@property (nonatomic, assign) SEL action;

+ (instancetype)styledSlider;

@end

NS_ASSUME_NONNULL_END
