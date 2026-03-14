/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

/// Per-plugin logger. Each instance routes to the OS log and to a dedicated
/// log file under ~/Library/Logs/co.overpolish.keyframeless/<pluginID>/.
///
/// Usage: store an instance on your plugin and use the logging methods.
///   _log = [KKLog loggerForPlugin:@"co.overpolish.myPlugin"];
///   [_log info:@"Plugin ready"];
@interface KKLog : NSObject

/// Returns a cached logger for the given plugin identifier, creating it if
/// needed.
+ (instancetype)loggerForPlugin:(NSString *)pluginID;

- (void)verbose:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)debug:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)info:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)warn:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)error:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);

@end
