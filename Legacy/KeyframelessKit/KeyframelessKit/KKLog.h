/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

/// Per-plugin logger. Each instance routes to the OS log and to a dedicated
/// log file under ~/Library/Logs/com.keyframeless/.
///
/// Prefer the macros below over the instance API:
///   KKLogInfo(@"Plugin ready, count=%d", n);
///
/// The legacy instance API is retained for existing call sites:
///   _log = [KKLog loggerForPlugin:@"com.keyframeless.myPlugin"];
///   [_log info:@"Plugin ready"];
@interface KKLog : NSObject

/// Process-wide shared logger. Writes to the unified
/// ~/Library/Logs/com.keyframeless/ folder; per-process file
/// separation comes from DDFileLogger's process-name-based filenames.
+ (instancetype)shared;

/// Returns a cached logger for the given plugin identifier, creating it if
/// needed. Legacy: new code should use +shared / the KKLog* macros.
+ (instancetype)loggerForPlugin:(NSString *)pluginID;

- (void)verbose:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)debug:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)info:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)warn:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)error:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

/// Synchronously drain the async log queue so pending lines hit disk. Call
/// right before a suspected crash point so the last line isn't lost in the
/// buffer when the process aborts.
- (void)flush;

/// Macro entry point - captures call site, routes through +shared.
- (void)logFlagValue:(NSUInteger)flag
                file:(const char *)file
            function:(const char *)function
                line:(NSUInteger)line
              format:(NSString *)format, ... NS_FORMAT_FUNCTION(5, 6);

@end

#define KKLogFlush() [[KKLog shared] flush]

#define KKLogVerbose(fmt, ...)                                                 \
  [[KKLog shared] logFlagValue:(1 << 4) /* DDLogFlagVerbose */                 \
                          file:__FILE__                                        \
                      function:__PRETTY_FUNCTION__                             \
                          line:__LINE__                                        \
                        format:(fmt), ##__VA_ARGS__]
#define KKLogDebug(fmt, ...)                                                   \
  [[KKLog shared] logFlagValue:(1 << 3) /* DDLogFlagDebug */                   \
                          file:__FILE__                                        \
                      function:__PRETTY_FUNCTION__                             \
                          line:__LINE__                                        \
                        format:(fmt), ##__VA_ARGS__]
#define KKLogInfo(fmt, ...)                                                    \
  [[KKLog shared] logFlagValue:(1 << 2) /* DDLogFlagInfo */                    \
                          file:__FILE__                                        \
                      function:__PRETTY_FUNCTION__                             \
                          line:__LINE__                                        \
                        format:(fmt), ##__VA_ARGS__]
#define KKLogWarn(fmt, ...)                                                    \
  [[KKLog shared] logFlagValue:(1 << 1) /* DDLogFlagWarning */                 \
                          file:__FILE__                                        \
                      function:__PRETTY_FUNCTION__                             \
                          line:__LINE__                                        \
                        format:(fmt), ##__VA_ARGS__]
#define KKLogError(fmt, ...)                                                   \
  [[KKLog shared] logFlagValue:(1 << 0) /* DDLogFlagError */                   \
                          file:__FILE__                                        \
                      function:__PRETTY_FUNCTION__                             \
                          line:__LINE__                                        \
                        format:(fmt), ##__VA_ARGS__]
