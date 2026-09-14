/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <FxPlug/FxPlugSDK.h>
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    [FxPrincipal startServicePrincipalWithDelegate:nil];
  }
  return 0;
}
