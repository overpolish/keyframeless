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

- (NSString *)entriesFingerprint {
  NSURL *root = [NSURL fileURLWithPath:[self rootDirectory] isDirectory:YES];
  NSArray<NSURLResourceKey> *keys =
      @[ NSURLIsDirectoryKey, NSURLContentModificationDateKey ];
  NSArray<NSURL *> *children = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:root
      includingPropertiesForKeys:keys
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:nil];
  NSMutableArray<NSString *> *parts =
      [NSMutableArray arrayWithCapacity:children.count];
  for (NSURL *url in children) {
    NSNumber *isDir = nil;
    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
    if (!isDir.boolValue)
      continue;
    // Every write this catalog makes is atomic (write-temp + rename), which
    // bumps the containing folder's date - so a save, a rename, an install and
    // a delete all move the token even though none of them replaces the folder.
    NSDate *modified = nil;
    [url getResourceValue:&modified
                   forKey:NSURLContentModificationDateKey
                    error:nil];
    [parts addObject:[NSString
                         stringWithFormat:@"%@:%.6f", url.lastPathComponent,
                                          modified
                                              .timeIntervalSinceReferenceDate]];
  }
  [parts sortUsingSelector:@selector(compare:)];
  return [parts componentsJoinedByString:@"\n"];
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
  // The Image shader owns its type. metadata.json repeats it only for remote
  // catalogue filtering before the source has been downloaded.
  e.category = MirageCategoryForSource(sections[@"Image"]);
  if (!e.category.length)
    return nil;
  return e;
}

- (MirageCatalogEntry *)
    saveShaderNamed:(NSString *)name
             author:(NSString *)author
           sections:(NSDictionary<NSString *, NSString *> *)sections
        previewJPEG:(NSData *)previewJPEG {
  NSString *category = MirageCategoryForSource(sections[@"Image"]);
  if (!category.length)
    return nil;
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
    // Denormalised for remote catalogue filtering; the Image directive remains
    // authoritative whenever the source is available.
    @"category" : category,
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

  // The former standalone Rounded plugin, now a shipped shader (and rather
  // more than rounding). Categorised
  // `layout` rather than `filter`: it does read the clip, but what it IS is the
  // `#alpha`-masked one-region-of-the-frame shader that category describes, and
  // stacking instances on Final Cut's lanes is the whole point of it.
  MirageCatalogEntry *frame = [MirageCatalogEntry new];
  frame.entryID = @"builtin.frame";
  frame.name = @"Frame";
  frame.author = @"";
  frame.category = kMirageCategoryLayout;
  frame.version = 1;
  frame.folderPath = @"";
  frame.builtin = YES;
  frame.sections = @{
    @"Image" : MirageFrameShaderSource(),
    @"Common" : MirageFrameCommonSource(),
    @"Buffer B" : MirageFrameBufferBSource(),
    @"Buffer C" : MirageFrameBufferCSource(),
    @"Buffer D" : MirageFrameBufferDSource(),
  };
  frame.thumbnail = sBuiltinThumbnails[@"Frame"];
  // Card values: Frame's border, glow and bloom all default to 0, so a
  // defaults bake shows the source frame with slightly rounded corners and
  // nothing else. Pixel sizes are for the 320x180 bake.
  frame.thumbnailValues = @{
    @"uSize" : @[ @56 ], // room for the glow to spread before the card edge
    @"uRadius" : @[ @30 ],
    // Pixels are measured against the 1080-tall REFERENCE render, not the
    // 320x180 card: ~30px reads as a 5px border once downscaled.
    @"uBorderWidth" : @[ @30 ],
    @"uBorderColor" : @[ @1.0, @1.0, @1.0, @1.0 ], // white, not glow-tinted
    @"uGlowSize" : @[ @260 ],
    // Glow Color's ALPHA is the strength, and its default #FFFFFFB3 caps the
    // whole glow at 70% - full alpha is what makes it read on the card at all.
    @"uGlowColor" : @[ @1.0, @1.0, @1.0, @1.0 ],
    @"uGlowPickup" : @[ @60 ], // drifts toward the shot's colour, still bright
    // Feather is a GAMMA on the blurred silhouette (mix(3.0, 0.5, feather)),
    // so it runs the opposite way to intuition: LOW feather = high exponent =
    // a dim glow crushed against the shape. The silhouette peaks near 0.5
    // alpha, so 35% gave 0.5^2.13 = 0.23 and read as barely there; 90% gives
    // 0.5^0.75 = 0.59.
    @"uGlowFeather" : @[ @90 ],
    @"uBloom" : @[ @25 ],
  };

  MirageCatalogEntry *colorTransform = [MirageCatalogEntry new];
  colorTransform.entryID = @"builtin.color-transform";
  colorTransform.name = @"Color Transform";
  colorTransform.author = @"";
  colorTransform.category = kMirageCategoryColorTransform;
  colorTransform.version = 1;
  colorTransform.folderPath = @"";
  colorTransform.builtin = YES;
  colorTransform.sections = @{@"Image" : MirageColorTransformShaderSource()};
  colorTransform.thumbnail = sBuiltinThumbnails[@"Color Transform"];

  // The former standalone MagicMove plugin. `layout` like Frame: it reads the
  // clip but what it IS is an `#alpha`-masked placement of one region of the
  // frame, and stacking instances on Final Cut's lanes is the point.
  MirageCatalogEntry *magicMove = [MirageCatalogEntry new];
  magicMove.entryID = @"builtin.magicmove";
  magicMove.name = @"Magic Move";
  magicMove.author = @"";
  magicMove.category = kMirageCategoryLayout;
  magicMove.version = 1;
  magicMove.folderPath = @"";
  magicMove.builtin = YES;
  magicMove.sections = @{
    @"Image" : MirageMagicMoveShaderSource(),
    @"Buffer B" : MirageMagicMoveBufferBSource(),
  };
  magicMove.thumbnail = sBuiltinThumbnails[@"Magic Move"];
  // Card values: Magic Move's defaults are an IDENTITY transform, which bakes
  // a card identical to the untouched preview photo. Scale it down and tip it
  // so the card reads as a transform.
  magicMove.thumbnailValues = @{
    @"uScale" : @[ @62, @62 ],
    // X/Y tip the picture in perspective, Z spins it in plane - all three, so
    // the card shows the 3D transform rather than a flat rotation.
    @"uRotation" : @[ @14, @-22, @-9 ],
  };
  return @[ plasma, frame, magicMove, colorTransform ];
}

- (void)deleteEntryID:(NSString *)entryID {
  NSString *dir = [[self rootDirectory] stringByAppendingPathComponent:entryID];
  [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
}

- (void)installCommunityID:(NSString *)entryID
                      name:(NSString *)name
                    author:(NSString *)author
                   version:(NSInteger)version
                  sections:(NSDictionary<NSString *, NSString *> *)sections
               previewJPEG:(NSData *)previewJPEG {
  NSString *category = MirageCategoryForSource(sections[@"Image"]);
  if (!category.length)
    return;
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
    @"category" : category,
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

- (NSString *)favoritesFingerprint {
  NSArray *favs = [NSUserDefaults.standardUserDefaults arrayForKey:kFavKey];
  if (!favs.count)
    return @"";
  return [[favs sortedArrayUsingSelector:@selector(compare:)]
      componentsJoinedByString:@","];
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
