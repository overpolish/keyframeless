/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// ObjC-facing view of a `CommunityEntry`. The Shader plugin is Objective-C, so
/// the Swift core is surfaced through NSObject facades with completion handlers
/// (mirrors how the plugin already consumes KeyframelessAI).
@objc(KKCommunityEntry)
public final class KKCommunityEntry: NSObject {
  @objc public let entryID: String
  @objc public let name: String
  @objc public let author: String
  @objc public let version: Int
  @objc public let folderName: String
  @objc public let previewURLString: String?
  /// Raw metadata.json values as strings, for payload-specific adapter reads.
  @objc public let metadata: [String: String]

  fileprivate let entry: CommunityEntry

  init(_ e: CommunityEntry) {
    entry = e
    entryID = e.id
    name = e.name
    author = e.author
    version = e.version
    folderName = e.folderName
    previewURLString = e.previewURL?.absoluteString
    metadata = e.metadata
  }
}

/// Process-wide TTL cache of fetched entries, keyed by catalog folder. Browsing
/// the catalog reuses a recent result instead of re-fetching every time a
/// popover opens; a manual refresh bypasses it. Lives in the (shared) inspector
/// UI process, so it persists across plugin instances and popover reopens.
private actor CommunityCache {
  static let shared = CommunityCache()
  static let ttl: TimeInterval = 15 * 60  // 15 minutes

  private var store: [String: (fetched: Date, entries: [CommunityEntry])] = [:]

  func cached(_ key: String) -> [CommunityEntry]? {
    guard let hit = store[key], Date().timeIntervalSince(hit.fetched) < Self.ttl
    else { return nil }
    return hit.entries
  }

  func put(_ key: String, _ entries: [CommunityEntry]) {
    store[key] = (Date(), entries)
  }
}

/// ObjC entry point to the shared community catalog. `catalogFolder` picks the
/// payload ("Shaders", "Captions"). Read-only for now (publish added next).
@objc(KKCommunityClient)
public final class KKCommunityClient: NSObject {
  private let catalog: CommunityCatalog
  private let publisher: CommunityPublisher
  private let catalogFolder: String

  @objc public init(catalogFolder: String) {
    let repo = CommunityRepo(catalogFolder: catalogFolder)
    self.catalogFolder = catalogFolder
    catalog = CommunityCatalog(repo: repo)
    publisher = CommunityPublisher(repo: repo)
    super.init()
  }

  /// List the catalog's entries. Serves a cached result when one is fresh
  /// (within the TTL) unless `forceRefresh` is set. `completion` is always
  /// called on the main queue.
  @objc public func fetchEntries(
    forceRefresh: Bool,
    completion: @escaping (_ entries: [KKCommunityEntry]?, _ error: String?) -> Void
  ) {
    Task {
      if !forceRefresh, let cached = await CommunityCache.shared.cached(catalogFolder) {
        let mapped = cached.map(KKCommunityEntry.init)
        await MainActor.run { completion(mapped, nil) }
        return
      }
      do {
        let entries = try await catalog.fetchEntries(bustCache: forceRefresh)
        await CommunityCache.shared.put(catalogFolder, entries)
        let mapped = entries.map(KKCommunityEntry.init)
        await MainActor.run { completion(mapped, nil) }
      } catch {
        await MainActor.run { completion(nil, error.localizedDescription) }
      }
    }
  }

  /// Download an entry's files as filename -> bytes. Main-queue completion.
  @objc public func downloadFiles(
    _ entry: KKCommunityEntry,
    completion: @escaping (_ files: [String: Data]?, _ error: String?) -> Void
  ) {
    Task {
      do {
        let files = try await catalog.downloadFiles(entry.entry)
        await MainActor.run { completion(files, nil) }
      } catch {
        await MainActor.run { completion(nil, error.localizedDescription) }
      }
    }
  }

  /// Publish an entry (files + metadata.json bytes) as a PR into the community
  /// repo. `version` 1 = new, >1 = update. Main-queue completion (nil error = ok).
  @objc public func publish(
    entryID: String, name: String, author: String, version: Int,
    files: [String: Data], metadataJSON: Data,
    completion: @escaping (_ error: String?) -> Void
  ) {
    let payload = CommunityPublisher.Payload(
      id: entryID, name: name, author: author, version: version,
      files: files, metadataJSON: metadataJSON)
    Task {
      do {
        try await publisher.publish(payload)
        await MainActor.run { completion(nil) }
      } catch {
        await MainActor.run { completion(error.localizedDescription) }
      }
    }
  }
}
