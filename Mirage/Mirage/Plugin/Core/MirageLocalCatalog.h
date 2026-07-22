/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One locally-saved shader (a draft the user can browse and publish). Mirrors
/// the community repo layout on disk so publishing is just "push this folder".
@interface MirageCatalogEntry : NSObject
@property(nonatomic, copy) NSString *entryID; // UUID
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *author;
/// What the shader is (see MirageCategory.h). Always a known id: reads
/// normalise, so this is safe to switch on. Carried in metadata.json, so it
/// survives a publish + download round trip.
@property(nonatomic, copy) NSString *category;
@property(nonatomic) NSInteger version;
@property(nonatomic, copy)
    NSString *folderPath; // on-disk directory ("" builtin)
@property(nonatomic, strong, nullable) NSImage *thumbnail;
/// Section name (@"Image"/@"Common"/@"Buffer A"..) -> GLSL code.
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *sections;
/// A shipped, non-deletable starter shader (e.g. the default Plasma), so the
/// browser always has at least one shader. Built-ins aren't on disk.
@property(nonatomic) BOOL builtin;
/// A downloaded community shader (installed for offline use, folder keyed by
/// its community id). Not user-created, so it isn't publishable, only
/// uninstalled or updated. Custom entries have this NO.
@property(nonatomic) BOOL community;
@end

/// Local store of saved shaders under Application Support. Each entry is a
/// folder `Shaders/<uuid>/` holding `metadata.json`, one `.glsl` per section
/// (`image.glsl`/`common.glsl`/`buffer-a.glsl`..) and `preview.jpg`.
@interface MirageLocalCatalog : NSObject
+ (instancetype)shared;

/// Every saved entry, newest first (thumbnails loaded lazily on access).
- (NSArray<MirageCatalogEntry *> *)entries;

/// Shipped starter shaders (currently the default Plasma), always present so
/// the browser is never empty. Non-deletable. Their thumbnail is set once via
/// `+setBuiltinThumbnail:forName:` (baked by the inspector's renderer).
- (NSArray<MirageCatalogEntry *> *)builtinEntries;

/// Cache a baked thumbnail for a built-in shader by name.
+ (void)setBuiltinThumbnail:(nullable NSImage *)image forName:(NSString *)name;

/// Save the given sections as a new UUID-keyed entry. Never overwrites an
/// existing entry by name, so duplicate names are fine. `previewJPEG` is
/// optional (a placeholder is used until a real thumbnail is rendered).
/// `category` is a MirageCategory.h id (nil = the default). Returns the written
/// entry.
- (MirageCatalogEntry *)
    saveShaderNamed:(NSString *)name
             author:(NSString *)author
           category:(nullable NSString *)category
           sections:(NSDictionary<NSString *, NSString *> *)sections
        previewJPEG:(nullable NSData *)previewJPEG;

/// Delete a saved entry by id (also uninstalls a downloaded community shader).
- (void)deleteEntryID:(NSString *)entryID;

/// Install (or update) a downloaded community shader for offline use, keyed by
/// its community id so a re-download replaces it. `version` is the remote
/// version; `category` is a MirageCategory.h id (nil = the default).
- (void)installCommunityID:(NSString *)entryID
                      name:(NSString *)name
                    author:(NSString *)author
                  category:(nullable NSString *)category
                   version:(NSInteger)version
                  sections:(NSDictionary<NSString *, NSString *> *)sections
               previewJPEG:(nullable NSData *)previewJPEG;

/// Installed version of a community shader (0 = not installed).
- (NSInteger)installedVersionForID:(NSString *)entryID;

/// Rename a saved entry (updates its metadata.json name; files/folder
/// unchanged).
- (void)renameEntryID:(NSString *)entryID toName:(NSString *)newName;

/// Favourites (persisted): any entry id (built-in / local / community).
- (BOOL)isFavorite:(NSString *)entryID;
- (void)toggleFavorite:(NSString *)entryID;

/// The files a publish needs: filename -> bytes (`.glsl` per section +
/// `preview.jpg`), NOT including metadata.json (the caller builds that).
- (NSDictionary<NSString *, NSData *> *)publishFilesForEntry:
    (MirageCatalogEntry *)entry;
@end

/// Section display name (@"Buffer A") <-> repo filename (@"buffer-a.glsl").
FOUNDATION_EXPORT NSString *MirageSectionFileName(NSString *sectionName);
FOUNDATION_EXPORT NSString *_Nullable MirageSectionNameForFile(
    NSString *fileName);

NS_ASSUME_NONNULL_END
