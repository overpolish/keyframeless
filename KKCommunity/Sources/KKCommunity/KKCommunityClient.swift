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

/// ObjC entry point to the shared community catalog. `catalogFolder` picks the
/// payload ("Shaders", "Captions"). Read-only for now (publish added next).
@objc(KKCommunityClient)
public final class KKCommunityClient: NSObject {
  private let catalog: CommunityCatalog
  private let publisher: CommunityPublisher

  @objc public init(catalogFolder: String) {
    let repo = CommunityRepo(catalogFolder: catalogFolder)
    catalog = CommunityCatalog(repo: repo)
    publisher = CommunityPublisher(repo: repo)
    super.init()
  }

  /// List the catalog's entries. `completion` is always called on the main queue.
  @objc public func fetchEntries(
    completion: @escaping (_ entries: [KKCommunityEntry]?, _ error: String?) -> Void
  ) {
    Task {
      do {
        let entries = try await catalog.fetchEntries().map(KKCommunityEntry.init)
        await MainActor.run { completion(entries, nil) }
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
