/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKFonts.h"
#import "../Plugin/KKHostInfo.h"

@implementation KKFonts

+ (NSFont *)inspectorLabelFont {
  CGFloat size = [KKHostInfo isRunningInWorkflowExtension]
                     ? [NSFont systemFontSize]
                     : [NSFont smallSystemFontSize];
  return [NSFont systemFontOfSize:size weight:NSFontWeightLight];
}

+ (CGFloat)inspectorIconSize {
  return [KKHostInfo isRunningInWorkflowExtension] ? 14.0 : 12.0;
}

@end
