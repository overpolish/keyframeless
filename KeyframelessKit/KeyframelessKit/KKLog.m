/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKLog.h"

@import CocoaLumberjack;

#ifdef DEBUG
static const DDLogLevel ddLogLevel = DDLogLevelDebug;
#else
static const DDLogLevel ddLogLevel = DDLogLevelWarning;
#endif

static NSString *const KKLogFolderName = @"co.overpolish.keyframeless";

@interface KKLog ()
@property(nonatomic, strong) DDLog *ddLog;
@end

@implementation KKLog

+ (instancetype)shared {
  static KKLog *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [[KKLog alloc] initShared];
  });
  return shared;
}

+ (instancetype)loggerForPlugin:(NSString *)pluginID {
  // Legacy entry point. All loggers now write to the same unified folder;
  // per-process file separation is handled by DDFileLogger's process-name
  // based filenames. The pluginID is retained only as a cache key so repeated
  // callers don't allocate redundant DDLog stacks.
  static NSMutableDictionary<NSString *, KKLog *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
  });

  @synchronized(cache) {
    KKLog *existing = cache[pluginID];
    if (existing)
      return existing;

    KKLog *logger = [[KKLog alloc] initShared];
    cache[pluginID] = logger;
    return logger;
  }
}

- (instancetype)initShared {
  self = [super init];
  if (!self)
    return nil;

  _ddLog = [[DDLog alloc] init];
  [_ddLog addLogger:[DDOSLogger sharedInstance] withLevel:DDLogLevelDebug];

  NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
                                                      NSUserDomainMask, YES);
  NSString *logDir = [[dirs[0] stringByAppendingPathComponent:@"Logs"]
      stringByAppendingPathComponent:KKLogFolderName];

  DDLogFileManagerDefault *fileManager =
      [[DDLogFileManagerDefault alloc] initWithLogsDirectory:logDir];
  DDFileLogger *fileLogger =
      [[DDFileLogger alloc] initWithLogFileManager:fileManager];
  fileLogger.rollingFrequency = 60 * 60 * 24; // daily
  fileLogger.logFileManager.maximumNumberOfLogFiles = 7;
  fileLogger.maximumFileSize = 1024 * 1024 * 10; // 10 MB
  [_ddLog addLogger:fileLogger withLevel:DDLogLevelDebug];

  return self;
}

- (void)logFlag:(DDLogFlag)flag
           file:(const char *)file
       function:(const char *)function
           line:(NSUInteger)line
         format:(NSString *)format
           args:(va_list)args {
  BOOL async = !(flag & DDLogFlagError);
  [_ddLog log:async
         level:ddLogLevel
          flag:flag
       context:0
          file:file
      function:function
          line:line
           tag:nil
        format:format
          args:args];
}

- (void)logFlagValue:(NSUInteger)flag
                file:(const char *)file
            function:(const char *)function
                line:(NSUInteger)line
              format:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:(DDLogFlag)flag
           file:file
       function:function
           line:line
         format:format
           args:args];
  va_end(args);
}

- (void)verbose:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagVerbose
           file:__FILE__
       function:__FUNCTION__
           line:__LINE__
         format:format
           args:args];
  va_end(args);
}

- (void)debug:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagDebug
           file:__FILE__
       function:__FUNCTION__
           line:__LINE__
         format:format
           args:args];
  va_end(args);
}

- (void)info:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagInfo
           file:__FILE__
       function:__FUNCTION__
           line:__LINE__
         format:format
           args:args];
  va_end(args);
}

- (void)warn:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagWarning
           file:__FILE__
       function:__FUNCTION__
           line:__LINE__
         format:format
           args:args];
  va_end(args);
}

- (void)error:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagError
           file:__FILE__
       function:__FUNCTION__
           line:__LINE__
         format:format
           args:args];
  va_end(args);
}

@end
