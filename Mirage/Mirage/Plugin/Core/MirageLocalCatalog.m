/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageLocalCatalog.h"
#import "Constants.h"       // MirageCustomDefaultShaderSource
#import "KKGLSLFormatter.h" // auto-format sections on publish
#import "MirageCategory.h"
#import "MirageDirectiveCatalog.h" // tidy `//` directive blocks on publish
#import <KeyframelessKit/KeyframelessKit.h>

static NSMutableDictionary<NSString *, NSImage *> *sBuiltinThumbnails;

NSString *MirageSectionFileName(NSString *sectionName) {
  if ([sectionName isEqualToString:@"Image"])
    return @"image.glsl";
  if ([sectionName isEqualToString:@"Common"])
    return @"common.glsl";
  if ([sectionName hasPrefix:@"Buffer "]) {
    NSString *letter = [[sectionName substringFromIndex:7] lowercaseString];
    return [NSString stringWithFormat:@"buffer-%@.glsl", letter];
  }
  // Fallback: slugified section name.
  NSString *slug =
      [[sectionName lowercaseString] stringByReplacingOccurrencesOfString:@" "
                                                               withString:@"-"];
  return [slug stringByAppendingPathExtension:@"glsl"];
}

NSString *MirageSectionNameForFile(NSString *fileName) {
  if ([fileName isEqualToString:@"image.glsl"])
    return @"Image";
  if ([fileName isEqualToString:@"common.glsl"])
    return @"Common";
  if ([fileName hasPrefix:@"buffer-"] && [fileName hasSuffix:@".glsl"]) {
    NSString *letter =
        [[fileName substringWithRange:NSMakeRange(7, 1)] uppercaseString];
    return [@"Buffer " stringByAppendingString:letter];
  }
  return nil;
}

@implementation MirageCatalogEntry
@end

@implementation MirageLocalCatalog

+ (instancetype)shared {
  static MirageLocalCatalog *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    s = [MirageLocalCatalog new];
  });
  return s;
}

// ~/Library/Application Support/Keyframeless/Shaders (in the sandbox
// container).
- (NSString *)rootDirectory {
  NSString *appSup = NSSearchPathForDirectoriesInDomains(
                         NSApplicationSupportDirectory, NSUserDomainMask, YES)
                         .firstObject;
  NSString *root =
      [appSup stringByAppendingPathComponent:@"Keyframeless/Shaders"];
  [[NSFileManager defaultManager] createDirectoryAtPath:root
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return root;
}

- (NSArray<MirageCatalogEntry *> *)entries {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *root = [self rootDirectory];
  NSMutableArray<MirageCatalogEntry *> *out = [NSMutableArray array];
  NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
  for (NSString *uuid in uuids) {
    NSString *dir = [root stringByAppendingPathComponent:uuid];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir)
      continue;
    MirageCatalogEntry *e = [self entryAtDirectory:dir];
    if (e)
      [out addObject:e];
  }
  // Newest first by folder mtime.
  [out sortUsingComparator:^NSComparisonResult(MirageCatalogEntry *a,
                                               MirageCatalogEntry *b) {
    NSDate *da =
        [fm attributesOfItemAtPath:a.folderPath error:nil].fileModificationDate;
    NSDate *db =
        [fm attributesOfItemAtPath:b.folderPath error:nil].fileModificationDate;
    return [db compare:da ?: [NSDate distantPast]];
  }];
  return out;
}

- (MirageCatalogEntry *)entryAtDirectory:(NSString *)dir {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *metaPath = [dir stringByAppendingPathComponent:@"metadata.json"];
  NSData *metaData = [NSData dataWithContentsOfFile:metaPath];
  if (!metaData)
    return nil;
  NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:metaData
                                                       options:0
                                                         error:nil];
  if (![meta isKindOfClass:[NSDictionary class]])
    return nil;

  MirageCatalogEntry *e = [MirageCatalogEntry new];
  e.entryID = meta[@"id"] ?: dir.lastPathComponent;
  e.name = meta[@"name"] ?: @"Untitled";
  e.author = meta[@"author"] ?: @"";
  // Normalised, so an entry saved before categories existed (no key at all) and
  // one published by a newer build (a category this build can't draw) both land
  // on the default instead of needing a migration pass over the folder.
  e.category = MirageCategoryNormalize(meta[@"category"]);
  e.version = [meta[@"version"] integerValue] ?: 1;
  e.community = [meta[@"community"] boolValue];
  e.folderPath = dir;

  NSString *preview =
      [dir stringByAppendingPathComponent:meta[@"preview"] ?: @"preview.png"];
  if ([fm fileExistsAtPath:preview])
    e.thumbnail = [[NSImage alloc] initWithContentsOfFile:preview];

  NSMutableDictionary<NSString *, NSString *> *sections =
      [NSMutableDictionary dictionary];
  for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
    NSString *sectionName = MirageSectionNameForFile(file);
    if (!sectionName)
      continue;
    NSString *code = [NSString
        stringWithContentsOfFile:[dir stringByAppendingPathComponent:file]
                        encoding:NSUTF8StringEncoding
                           error:nil];
    if (code)
      sections[sectionName] = code;
  }
  e.sections = sections;
  return e;
}

- (MirageCatalogEntry *)
    saveShaderNamed:(NSString *)name
             author:(NSString *)author
           category:(NSString *)category
           sections:(NSDictionary<NSString *, NSString *> *)sections
        previewJPEG:(NSData *)previewJPEG {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *root = [self rootDirectory];

  // Every save is a new UUID-keyed entry - never overwrite an existing one by
  // name. Entries are identified by UUID, so duplicate names are fine, and a
  // custom save must never clobber a downloaded community entry (or an earlier
  // custom one) that happens to share the name - that hijacked the community
  // entry's folder and made it read as "not downloaded".
  NSString *entryID = [[NSUUID UUID] UUIDString];
  NSInteger version = 1;
  NSString *dir = [root stringByAppendingPathComponent:entryID];
  [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];

  // Write one .glsl per non-empty section.
  for (NSString *sectionName in sections) {
    NSString *code = sections[sectionName];
    if (!code.length)
      continue;
    NSString *file =
        [dir stringByAppendingPathComponent:MirageSectionFileName(sectionName)];
    [code writeToFile:file
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  }

  if (previewJPEG)
    [previewJPEG writeToFile:[dir stringByAppendingPathComponent:@"preview.jpg"]
                  atomically:YES];

  NSDictionary *meta = @{
    @"id" : entryID,
    @"name" : name,
    @"author" : author ?: @"",
    // Written as given, not normalised: writes preserve, reads normalise. The
    // picker only ever hands us a known id, but keeping the one rule everywhere
    // is what lets the community install below round-trip a newer build's
    // category instead of quietly rewriting it.
    @"category" : category.length ? category : kMirageCategoryDefault,
    @"version" : @(version),
    @"preview" : @"preview.jpg",
  };
  NSData *metaData = [NSJSONSerialization
      dataWithJSONObject:meta
                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                   error:nil];
  [metaData writeToFile:[dir stringByAppendingPathComponent:@"metadata.json"]
             atomically:YES];

  return [self entryAtDirectory:dir];
}

+ (void)setBuiltinThumbnail:(NSImage *)image forName:(NSString *)name {
  if (!sBuiltinThumbnails)
    sBuiltinThumbnails = [NSMutableDictionary dictionary];
  if (image)
    sBuiltinThumbnails[name] = image;
}

- (NSArray<MirageCatalogEntry *> *)builtinEntries {
  MirageCatalogEntry *plasma = [MirageCatalogEntry new];
  plasma.entryID = @"builtin.plasma";
  plasma.name = @"Plasma";
  plasma.author = @"";
  plasma.category = kMirageCategoryGenerator;
  plasma.version = 1;
  plasma.folderPath = @"";
  plasma.builtin = YES;
  plasma.sections = @{@"Image" : MirageCustomDefaultShaderSource()};
  plasma.thumbnail = sBuiltinThumbnails[@"Plasma"];
  return @[ plasma ];
}

- (void)deleteEntryID:(NSString *)entryID {
  NSString *dir = [[self rootDirectory] stringByAppendingPathComponent:entryID];
  [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
}

- (void)installCommunityID:(NSString *)entryID
                      name:(NSString *)name
                    author:(NSString *)author
                  category:(NSString *)category
                   version:(NSInteger)version
                  sections:(NSDictionary<NSString *, NSString *> *)sections
               previewJPEG:(NSData *)previewJPEG {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = [[self rootDirectory] stringByAppendingPathComponent:entryID];
  [fm removeItemAtPath:dir error:nil]; // replace on update
  [fm createDirectoryAtPath:dir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  for (NSString *sectionName in sections) {
    NSString *code = sections[sectionName];
    if (!code.length)
      continue;
    [code writeToFile:[dir stringByAppendingPathComponent:MirageSectionFileName(
                                                              sectionName)]
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  }
  if (previewJPEG)
    [previewJPEG writeToFile:[dir stringByAppendingPathComponent:@"preview.jpg"]
                  atomically:YES];
  NSDictionary *meta = @{
    @"id" : entryID,
    @"name" : name ?: @"",
    @"author" : author ?: @"",
    // Deliberately NOT normalised: a shader published by a newer build can name
    // a category this one can't draw, and rewriting it here would downgrade the
    // entry on disk permanently. Reads normalise for display instead, so an
    // unknown shows as the default without losing what it really is.
    @"category" : category.length ? category : kMirageCategoryDefault,
    @"version" : @(version),
    @"preview" : @"preview.jpg",
    @"community" : @YES,
  };
  [[NSJSONSerialization
      dataWithJSONObject:meta
                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                   error:nil]
      writeToFile:[dir stringByAppendingPathComponent:@"metadata.json"]
       atomically:YES];
}

- (NSInteger)installedVersionForID:(NSString *)entryID {
  NSString *dir = [[self rootDirectory] stringByAppendingPathComponent:entryID];
  MirageCatalogEntry *e = [self entryAtDirectory:dir];
  return (e && e.community) ? e.version : 0;
}

- (void)renameEntryID:(NSString *)entryID toName:(NSString *)newName {
  newName = [newName
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (!newName.length)
    return;
  NSString *dir = [[self rootDirectory] stringByAppendingPathComponent:entryID];
  NSString *metaPath = [dir stringByAppendingPathComponent:@"metadata.json"];
  NSData *metaData = [NSData dataWithContentsOfFile:metaPath];
  NSMutableDictionary *meta =
      [[NSJSONSerialization JSONObjectWithData:metaData ?: [NSData data]
                                       options:0
                                         error:nil] mutableCopy];
  if (![meta isKindOfClass:[NSMutableDictionary class]])
    return;
  meta[@"name"] = newName;
  NSData *out = [NSJSONSerialization
      dataWithJSONObject:meta
                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                   error:nil];
  [out writeToFile:metaPath atomically:YES];
}

static NSString *const kFavKey = @"MirageFavorites";

- (BOOL)isFavorite:(NSString *)entryID {
  return [[NSUserDefaults.standardUserDefaults arrayForKey:kFavKey]
      containsObject:entryID];
}

- (void)toggleFavorite:(NSString *)entryID {
  NSMutableArray *favs =
      [[NSUserDefaults.standardUserDefaults arrayForKey:kFavKey] mutableCopy]
          ?: [NSMutableArray array];
  if ([favs containsObject:entryID])
    [favs removeObject:entryID];
  else
    [favs addObject:entryID];
  [NSUserDefaults.standardUserDefaults setObject:favs forKey:kFavKey];
}

- (NSDictionary<NSString *, NSData *> *)publishFilesForEntry:
    (MirageCatalogEntry *)entry {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableDictionary<NSString *, NSData *> *files =
      [NSMutableDictionary dictionary];
  for (NSString *file in [fm contentsOfDirectoryAtPath:entry.folderPath
                                                 error:nil]) {
    if ([file isEqualToString:@"metadata.json"])
      continue;
    NSData *data = [NSData
        dataWithContentsOfFile:[entry.folderPath
                                   stringByAppendingPathComponent:file]];
    if (!data)
      continue;
    // Auto-format GLSL sections on publish so community shaders are clean and
    // consistent whether or not the author ran Format (and this catches
    // entries saved before the Format button existed). Non-code payloads
    // (preview.jpg) and any undecodable source ship unchanged; KKFormatGLSL
    // itself returns the input untouched on an astyle error, and is idempotent
    // so re-publishing a version is stable.
    if ([file.pathExtension isEqualToString:@"glsl"]) {
      NSString *code = [[NSString alloc] initWithData:data
                                             encoding:NSUTF8StringEncoding];
      if (code.length) {
        NSData *formatted = [MirageTidyDirectives(KKFormatGLSL(code))
            dataUsingEncoding:NSUTF8StringEncoding];
        if (formatted)
          data = formatted;
      }
    }
    files[file] = data;
  }
  return files;
}

@end
