/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// How a plugin names a published Sonar source, and what it must remember so a
/// project can still explain itself on a Mac that never published.
///
/// Only plugin parameters travel inside an FCP library. The app-group container
/// does not, so a project opened on a second Mac finds no manifest and no grids
/// at all - every binding dangles, and nothing on disk can say what was lost. A
/// **ticket** is that record: which source a plugin wants, and which clips
/// Sonar must select to rebuild it. The plugin stores the ticket in whichever
/// parameter it likes; this header only defines what one is.
///
/// This lives in the kit rather than in Shader because it is the *protocol*,
/// not a consumer's private business. A second consumer deriving source keys
/// its own way would produce bindings that silently never match, and the
/// failure would look like "audio doesn't work" rather than "two hash functions
/// disagree".
///
/// A source's key is derived from its content, never its position in a list, so
/// deleting a source in Sonar cannot silently repoint every plugin that pointed
/// past it.

/// Stable lane value for a published source, from a `manifest.json` entry.
///
/// 0 means the entry names nothing usable, which is also the reserved "None"
/// value - so a caller can store the result directly.
double KKSonarSourceKeyForSource(NSDictionary<NSString *, id> *source);

/// The published source a lane value names, or nil when none does.
///
/// Nil is the ordinary answer, not an error: the source may have been deleted,
/// or the project may have travelled to a Mac where it was never published.
NSDictionary<NSString *, id> *_Nullable KKSonarSourceForKey(
    double key, NSArray<NSDictionary<NSString *, id> *> *published);

/// A ticket for a manifest entry, ready to be stored in a plugin parameter.
///
/// Plain JSON types only, so it can ride in whatever a plugin already
/// persists. Nil when `source` names nothing bindable.
NSDictionary<NSString *, id> *_Nullable KKSonarTicketForSource(
    NSDictionary<NSString *, id> *source);

double KKSonarTicketKey(NSDictionary<NSString *, id> *ticket);
NSString *_Nullable KKSonarTicketProjectName(
    NSDictionary<NSString *, id> *ticket);
NSString *_Nullable KKSonarTicketSourceName(
    NSDictionary<NSString *, id> *ticket);

/// Portable keys of the clips that were published, for Sonar to reselect.
///
/// Empty for a ticket written before Sonar recorded them, which means the
/// binding can be named but not rebuilt automatically.
NSArray<NSString *> *
KKSonarTicketClipKeys(NSDictionary<NSString *, id> *ticket);

/// Leaves a request for Sonar to republish what `ticket` describes.
///
/// A plugin cannot ask Sonar anything directly - they are separate sandboxes
/// that never share a process - so the app-group container is the only channel,
/// and it only goes one way: the plugin drops a note, Sonar reads it whenever
/// it next opens a project. Nothing waits on anything.
///
/// Call when a binding resolves to nothing (`KKSonarSourceForKey` returns nil),
/// never from a render path. Writing the same request twice is harmless: the
/// key names the file, so a request refreshes in place rather than piling up.
BOOL KKSonarWriteRepublishRequest(NSDictionary<NSString *, id> *ticket);

/// Every outstanding republish request, newest first.
///
/// These are tickets, so read them with the `KKSonarTicket*` accessors above.
NSArray<NSDictionary<NSString *, id> *> *KKSonarPendingRepublishRequests(void);

/// Drops the request for `key` once its source has been published again.
void KKSonarClearRepublishRequest(double key);

NS_ASSUME_NONNULL_END
