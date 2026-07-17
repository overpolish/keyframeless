/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Private declarations shared between the Shader browser's parts: the item
// model, the card view, its field subclasses, and the owner protocol. Not a
// public header - only ShaderBrowserView.m / ShaderCard.m /
// ShaderBrowserFields.m include it.

#import <Cocoa/Cocoa.h>

@class ShaderCatalogEntry;
@class KKCommunityEntry;

NS_ASSUME_NONNULL_BEGIN

/// The card's name-row height. Both the card layout and the grid's per-card
/// height need it, so it's declared here and defined in each.
extern const CGFloat kShaderCardNameH;

typedef NS_ENUM(NSInteger, _ShaderItemKind) {
  _ShaderItemBuiltin,   // shipped starter (favourite only)
  _ShaderItemLocal,     // user-saved custom (delete + publish + rename)
  _ShaderItemInstalled, // downloaded community, offline (uninstall + update)
  _ShaderItemRemote     // community not installed (download)
};

@interface _ShaderBrowserItem : NSObject
@property(nonatomic) _ShaderItemKind kind;
@property(nonatomic, copy) NSString *entryID;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *author;
/// A ShaderCategory.h id, already normalised. Drives the card's type badge and
/// the header's category filter.
@property(nonatomic, copy) NSString *category;
@property(nonatomic, strong, nullable) NSImage *thumbnail;
@property(nonatomic)
    BOOL updateAvailable; // installed + remote has newer version
@property(nonatomic, strong, nullable) ShaderCatalogEntry *localEntry;
@property(nonatomic, strong, nullable) KKCommunityEntry *communityEntry;
@end

@interface _ShaderFlippedView : NSView
@end

// The card name field, editable inline. In a ViewBridge panel key events arrive
// as key equivalents, not keyDown, so forward them to the field editor (the
// Canvas layer-list rename fix), else typing does nothing.
@interface _ShaderRenameField : NSTextField
@end

// Search field with the same focus behaviour as the shader name field: don't
// grab focus from the key-view loop on open (only from a real click on the
// field), act on the first click even when the panel isn't key, and forward key
// equivalents to the field editor so typing works in the ViewBridge popover.
@interface _ShaderSearchField : NSSearchField
@end

@class _ShaderCard;
@protocol _ShaderCardOwner
- (void)cardClicked:(_ShaderCard *)card;
- (void)cardPublish:(_ShaderCard *)card;
- (void)cardDelete:(_ShaderCard *)card;
- (void)cardDownload:(_ShaderCard *)card;
- (void)cardToggleFavorite:(_ShaderCard *)card;
- (void)cardRename:(_ShaderCard *)card toName:(NSString *)name;
- (void)card:(_ShaderCard *)card didBeginRename:(BOOL)renaming;
@end

// One card: thumbnail + name, with hover buttons (delete top-left, favourite
// top-right, action bottom-right).
@interface _ShaderCard : NSView <NSTextFieldDelegate, NSViewToolTipOwner>
@property(nonatomic, strong) _ShaderBrowserItem *item;
@property(nonatomic, weak) id<_ShaderCardOwner> owner;
@property(nonatomic) BOOL favorite;
- (instancetype)initWithItem:(_ShaderBrowserItem *)item width:(CGFloat)width;
- (void)setHovered:(BOOL)hovered;
/// The pointer's position in this card's coordinates, on every move while it is
/// the hovered card. Drives the author badge's expand, which needs per-move
/// resolution rather than just card enter/exit. (Tracking areas would be the
/// obvious tool, but the browser already tracks hover with a global monitor -
/// this panel is a nonactivating ViewBridge child window.)
- (void)setHoverPoint:(NSPoint)point;
- (void)setThumbnail:(NSImage *)image;
@end

NS_ASSUME_NONNULL_END
