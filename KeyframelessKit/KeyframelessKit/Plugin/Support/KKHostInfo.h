/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared store for the FxPlug host bundle identifier.
/// Set once from the principal delegate, then read from anywhere in
/// KeyframelessKit.
@interface KKHostInfo : NSObject

@property(nonatomic, copy, nullable) NSString *hostID;
@property(nonatomic, assign) BOOL isWorkflowExtension;

+ (BOOL)isRunningInFinalCut;
+ (BOOL)isRunningInWorkflowExtension;
+ (instancetype)shared;

/// Fits the host app's viewer/canvas to its window via System Events
/// AppleScript, branching on FCP vs Motion. Locale-proof: navigates the host
/// menus by structural position (identical across UI languages) rather than by
/// localized title. Runs synchronously, so call from a background queue or
/// dispatch_async (and, for an OSC joyride, before the overlay exists so the
/// host-app focus steal happens first). Shared so every plugin's interactive
/// guide can zoom-to-fit the same way.
+ (void)zoomHostViewerToFit;

@end

NS_ASSUME_NONNULL_END
