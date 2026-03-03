//
//  KKHostInfo.m
//  KeyframelessKit
//
// Created by Dom on 02/03/2026.
//

#import "KKHostInfo.h"

@implementation KKHostInfo

+ (BOOL)isRunningInFinalCut {
  return [[self shared].hostID isEqualToString:@"com.apple.FinalCut"];
}

+ (instancetype)shared {
  static KKHostInfo *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[KKHostInfo alloc] init];
  });
  return instance;
}

@end
