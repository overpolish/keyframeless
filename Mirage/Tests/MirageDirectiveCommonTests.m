/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

#import "MirageDirectiveCommon.h"

static void KKRequire(BOOL condition, NSString *message) {
  if (condition)
    return;
  NSLog(@"FAIL: %@", message);
  exit(1);
}

int main(void) {
  @autoreleasepool {
    KKRequire(MirageAttrHasBareFlag(@" dropdown multiple", @"dropdown"),
              @"recognises a bare dropdown flag");
    KKRequire(MirageAttrHasBareFlag(@" dropdown multiple", @"multiple"),
              @"recognises a bare multiple flag");
    KKRequire(!MirageAttrHasBareFlag(@" label=\"multiple\"", @"multiple"),
              @"ignores flags in quoted labels");
    KKRequire(!MirageAttrHasBareFlag(@" options=\"Flow,No flow\" flowgate=-30",
                                     @"flow"),
              @"ignores quoted and prefixed flow words");
    KKRequire(MirageAttrHasBareFlag(@" flow flowgate=-30", @"flow"),
              @"recognises flow alongside prefixed attributes");
  }
  return 0;
}
