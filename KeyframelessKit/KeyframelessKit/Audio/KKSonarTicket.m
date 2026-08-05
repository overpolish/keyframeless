/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSonarTicket.h"

#import "KKSpectrogram.h"

static NSString *const kKKSonarTicketKeyKey = @"key";
static NSString *const kKKSonarTicketSourceIDKey = @"sourceID";
static NSString *const kKKSonarTicketProjectKey = @"project";
static NSString *const kKKSonarTicketNameKey = @"name";
static NSString *const kKKSonarTicketClipKeysKey = @"clipKeys";

/// A manifest string field, or nil if it is missing or the wrong type.
///
/// The manifest is JSON written by another process, so every read is a
/// possibility, not a fact.
static NSString *_Nullable KKSonarString(NSDictionary<NSString *, id> *dict,
                                         NSString *key) {
  NSString *value = dict[key];
  return ([value isKindOfClass:NSString.class] && value.length) ? value : nil;
}

/// What a source is known by: its content hash, falling back to its id for
/// entries written before Sonar hashed content.
static NSString *_Nullable KKSonarSourceIdentity(
    NSDictionary<NSString *, id> *source) {
  NSString *hash = KKSonarString(source, @"contentHash");
  return hash ?: KKSonarString(source, @"id");
}

/// 24 bits of djb2, never 0.
///
/// Lane values travel as floats, whose mantissa holds integers exactly only to
/// 2^24, and 0 is reserved for "None". Collisions are a non-issue across the
/// handful of sources one project publishes.
///
/// This must never change: it is written into saved projects, so a different
/// answer tomorrow silently unbinds every plugin bound today.
static double KKSonarKeyForIdentity(NSString *identity) {
  if (identity.length == 0) {
    return 0;
  }
  uint32_t hash = 5381;
  for (NSUInteger i = 0; i < identity.length; i++) {
    hash = (hash * 33u) + (uint32_t)[identity characterAtIndex:i];
  }
  hash &= 0xFFFFFFu;
  return (double)(hash == 0 ? 1u : hash);
}

double KKSonarSourceKeyForSource(NSDictionary<NSString *, id> *source) {
  NSString *identity = KKSonarSourceIdentity(source);
  return identity ? KKSonarKeyForIdentity(identity) : 0;
}

NSDictionary<NSString *, id> *_Nullable KKSonarSourceForKey(
    double key, NSArray<NSDictionary<NSString *, id> *> *published) {
  if (lround(key) == 0) {
    return nil;
  }
  for (NSDictionary<NSString *, id> *source in published) {
    if (lround(KKSonarSourceKeyForSource(source)) == lround(key)) {
      return source;
    }
  }
  return nil;
}

NSDictionary<NSString *, id> *_Nullable KKSonarTicketForSource(
    NSDictionary<NSString *, id> *source) {
  double key = KKSonarSourceKeyForSource(source);
  if (lround(key) == 0) {
    return nil;
  }
  NSMutableDictionary<NSString *, id> *ticket =
      [NSMutableDictionary dictionary];
  ticket[kKKSonarTicketKeyKey] = @(key);
  ticket[kKKSonarTicketSourceIDKey] = KKSonarString(source, @"id");
  ticket[kKKSonarTicketProjectKey] = KKSonarString(source, @"projectName");
  ticket[kKKSonarTicketNameKey] = KKSonarString(source, @"name");
  NSArray *clipKeys = source[@"clipKeys"];
  if ([clipKeys isKindOfClass:NSArray.class] && clipKeys.count) {
    ticket[kKKSonarTicketClipKeysKey] = [clipKeys copy];
  }
  return ticket;
}

double KKSonarTicketKey(NSDictionary<NSString *, id> *ticket) {
  NSNumber *key = ticket[kKKSonarTicketKeyKey];
  return [key isKindOfClass:NSNumber.class] ? key.doubleValue : 0;
}

NSString *_Nullable KKSonarTicketProjectName(
    NSDictionary<NSString *, id> *ticket) {
  return KKSonarString(ticket, kKKSonarTicketProjectKey);
}

NSString *_Nullable KKSonarTicketSourceName(
    NSDictionary<NSString *, id> *ticket) {
  return KKSonarString(ticket, kKKSonarTicketNameKey);
}

NSArray<NSString *> *
KKSonarTicketClipKeys(NSDictionary<NSString *, id> *ticket) {
  NSArray *clipKeys = ticket[kKKSonarTicketClipKeysKey];
  return [clipKeys isKindOfClass:NSArray.class] ? clipKeys : @[];
}

/// Requests live beside the sources they ask for, in the one directory both
/// sandboxes can reach. Derived from the sources directory rather than resolved
/// again: that lookup already handles a process with no app-group access by
/// answering nil once and for good.
static NSURL *_Nullable KKSonarRequestsDirectory(void) {
  NSURL *sources = KKSpectrogramSourcesDirectory();
  if (!sources) {
    return nil;
  }
  NSURL *dir = [[sources URLByDeletingLastPathComponent]
      URLByAppendingPathComponent:@"Requests"
                      isDirectory:YES];
  [[NSFileManager defaultManager] createDirectoryAtURL:dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:NULL];
  return dir;
}

/// Named by key, so re-asking refreshes in place. A request is a standing "this
/// project wants X", not an event worth recording twice.
static NSURL *_Nullable KKSonarRequestURLForKey(double key) {
  NSURL *dir = KKSonarRequestsDirectory();
  return dir ? [dir
                   URLByAppendingPathComponent:[NSString
                                                   stringWithFormat:@"%ld.json",
                                                                    lround(
                                                                        key)]]
             : nil;
}

BOOL KKSonarWriteRepublishRequest(NSDictionary<NSString *, id> *ticket) {
  double key = KKSonarTicketKey(ticket);
  NSURL *url = KKSonarRequestURLForKey(key);
  if (lround(key) == 0 || !url ||
      ![NSJSONSerialization isValidJSONObject:ticket]) {
    return NO;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:ticket
                                                 options:0
                                                   error:NULL];
  // Atomically: Sonar may read this directory at any moment, and a half-written
  // request would parse as no request at all.
  return data ? [data writeToURL:url options:NSDataWritingAtomic error:NULL]
              : NO;
}

NSArray<NSDictionary<NSString *, id> *> *KKSonarPendingRepublishRequests(void) {
  NSURL *dir = KKSonarRequestsDirectory();
  if (!dir) {
    return @[];
  }
  NSArray<NSURL *> *files = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:dir
      includingPropertiesForKeys:@[ NSURLContentModificationDateKey ]
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:NULL];
  NSMutableArray<NSURL *> *sorted = [files mutableCopy];
  [sorted sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
    NSDate *da = nil, *db = nil;
    [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:NULL];
    [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:NULL];
    return [db compare:da]; // newest first
  }];
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (NSURL *url in sorted) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) {
      continue;
    }
    id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:NULL];
    // Written by another process, so every field is a possibility, not a fact.
    if ([parsed isKindOfClass:NSDictionary.class] &&
        lround(KKSonarTicketKey(parsed)) != 0) {
      [out addObject:parsed];
    }
  }
  return out;
}

void KKSonarClearRepublishRequest(double key) {
  NSURL *url = KKSonarRequestURLForKey(key);
  if (url) {
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
  }
}
