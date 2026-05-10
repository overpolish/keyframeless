/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHostInfo.h"

@implementation KKHostInfo

+ (BOOL)isRunningInFinalCut {
  return [[self shared].hostID isEqualToString:@"com.apple.FinalCut"];
}

+ (BOOL)isRunningInWorkflowExtension {
  return [self shared].isWorkflowExtension;
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
