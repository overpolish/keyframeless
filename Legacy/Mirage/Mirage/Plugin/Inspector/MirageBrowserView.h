/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <AppKit/AppKit.h>

@class MirageCatalogEntry;

NS_ASSUME_NONNULL_BEGIN

/// A grid of saved-shader cards (thumbnail + name underneath); on hover a card
/// reveals action buttons (publish / delete). Alphabetical, no reordering. Fed
/// from `MirageLocalCatalog`; call `-reload` to refresh. The card look mirrors
/// Steno's community caption card, reimplemented in AppKit.
@interface MirageBrowserView : NSView

/// A card was clicked: load this shader into the editor / lanes.
@property(nonatomic, copy, nullable) void (^onSelectEntry)
    (MirageCatalogEntry *entry);
/// The card's publish button was pressed.
@property(nonatomic, copy, nullable) void (^onPublishEntry)
    (MirageCatalogEntry *entry);
/// The card's delete button was pressed.
@property(nonatomic, copy, nullable) void (^onDeleteEntry)
    (MirageCatalogEntry *entry);
/// A local card was inline-renamed (double-click) to `name`.
@property(nonatomic, copy, nullable) void (^onRenameEntry)
    (MirageCatalogEntry *entry, NSString *name);

/// Reload entries from the local catalog (sorted A-Z) and rebuild the grid.
- (void)reload;

/// Rebuild the grid from the current local catalog + already-fetched community
/// list, WITHOUT re-fetching the community. For local-only changes (rename,
/// delete, save) that shouldn't hit the network.
- (void)refreshLocal;

@end

NS_ASSUME_NONNULL_END
