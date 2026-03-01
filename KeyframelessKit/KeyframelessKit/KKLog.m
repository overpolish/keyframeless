//
//  KKLog.m
//  KeyframelessKit
//
//  Created by Dom on 01/03/2026.
//

#import "KKLog.h"

static NSString *const KKLogBaseIdentifier = @"co.overpolish.keyframeless";

@interface KKLog ()
@property(nonatomic, strong) DDLog *ddLog;
@end

@implementation KKLog

+ (instancetype)loggerForPlugin:(NSString *)pluginID {
  static NSMutableDictionary<NSString *, KKLog *> *cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
  });

  @synchronized(cache) {
    KKLog *existing = cache[pluginID];
    if (existing)
      return existing;

    KKLog *logger = [[KKLog alloc] initWithPluginID:pluginID];
    cache[pluginID] = logger;
    return logger;
  }
}

- (instancetype)initWithPluginID:(NSString *)pluginID {
  self = [super init];
  if (!self)
    return nil;

  _ddLog = [[DDLog alloc] init];
  [_ddLog addLogger:[DDOSLogger sharedInstance] withLevel:DDLogLevelDebug];

  NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
                                                      NSUserDomainMask, YES);
  NSString *logDir = [[dirs[0] stringByAppendingPathComponent:@"Logs"]
      stringByAppendingPathComponent:pluginID];

  DDLogFileManagerDefault *fileManager =
      [[DDLogFileManagerDefault alloc] initWithLogsDirectory:logDir];
  DDFileLogger *fileLogger =
      [[DDFileLogger alloc] initWithLogFileManager:fileManager];
  fileLogger.rollingFrequency = 60 * 60 * 24; // daily
  fileLogger.logFileManager.maximumNumberOfLogFiles = 7;
  fileLogger.maximumFileSize = 1024 * 1024 * 10; // 10 MB
  [_ddLog addLogger:fileLogger withLevel:DDLogLevelDebug];

  [self info:@"Logging initialized. Log dir: %@", logDir];

  return self;
}

- (void)logFlag:(DDLogFlag)flag format:(NSString *)format args:(va_list)args {
  BOOL async = !(flag & DDLogFlagError);
  [_ddLog log:async
         level:ddLogLevel
          flag:flag
       context:0
          file:__FILE__
      function:__FUNCTION__
          line:__LINE__
           tag:nil
        format:format
          args:args];
}

- (void)verbose:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagVerbose format:format args:args];
  va_end(args);
}

- (void)debug:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagDebug format:format args:args];
  va_end(args);
}

- (void)info:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagInfo format:format args:args];
  va_end(args);
}

- (void)warn:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagWarning format:format args:args];
  va_end(args);
}

- (void)error:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  [self logFlag:DDLogFlagError format:format args:args];
  va_end(args);
}

@end
