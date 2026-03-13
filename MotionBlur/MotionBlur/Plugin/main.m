/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    [FxPrincipal
        startServicePrincipalWithDelegate:[KKPlugin servicePrincipalDelegate]];
  }
  return 0;
}
