/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// One entry discovered in a catalog folder. Carries the fields common to every
/// payload (id / name / author / version) plus the raw `metadata.json` so a
/// consumer's adapter can read payload-specific keys, and the URLs needed to
/// preview and download the entry's files.
public struct CommunityEntry: Sendable {
  public let id: String  // the per-item UUID folder name
  public let name: String
  public let author: String
  public let version: Int
  public let folderName: String  // the display sub-dir inside the UUID folder
  public let metadata: [String: String]  // flattened string values from metadata.json
  public let previewURL: URL?  // convention: <folder>/<preview> (metadata "preview")
  public let files: [CommunityFile]  // every file in the entry folder (name + url)
}

public struct CommunityFile: Sendable {
  public let name: String
  public let downloadURL: URL
}

/// Payload-agnostic catalog reader: lists a repo folder, loads each item's
/// metadata, and downloads an item's files. Lifted from Steno's caption store,
/// generified over the catalog folder. Publish lives in `CommunityPublisher`.
public struct CommunityCatalog: Sendable {
  public let repo: CommunityRepo

  public init(repo: CommunityRepo) {
    self.repo = repo
  }

  /// List every entry in the catalog folder, sorted by name. A folder whose
  /// metadata can't be read is skipped rather than failing the whole fetch.
  public func fetchEntries() async throws -> [CommunityEntry] {
    let (data, _) = try await URLSession.shared.data(from: repo.contentsURL(repo.catalogFolder))
    guard let folders = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }

    var results: [CommunityEntry] = []
    for folder in folders {
      guard let uuid = folder["name"] as? String,
        folder["type"] as? String == "dir",
        let entry = try? await loadEntry(uuid: uuid)
      else { continue }
      results.append(entry)
    }
    return results.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Load a single entry: the UUID folder holds one display sub-dir; its
  /// `metadata.json` names the entry, and its files are what a consumer installs.
  private func loadEntry(uuid: String) async throws -> CommunityEntry? {
    let (data, _) = try await URLSession.shared.data(
      from: repo.contentsURL("\(repo.catalogFolder)/\(uuid)"))
    guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
      let dir = items.first(where: { $0["type"] as? String == "dir" }),
      let folderName = dir["name"] as? String
    else { return nil }

    let base = "\(repo.catalogFolder)/\(uuid)/\(folderName)"
    let (metaData, _) = try await URLSession.shared.data(from: repo.rawURL("\(base)/metadata.json"))
    guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
      let name = meta["name"] as? String
    else { return nil }

    // Flatten metadata to string values so the ObjC bridge can pass it through
    // as a plain dictionary (payload-specific typed reads happen in the adapter).
    var flat: [String: String] = [:]
    for (k, v) in meta { flat[k] = "\(v)" }

    let files = try await listFiles(base: base)
    let previewName = meta["preview"] as? String
    let previewURL = previewName.map { repo.rawURL("\(base)/\($0)") }

    return CommunityEntry(
      id: meta["id"] as? String ?? uuid,
      name: name,
      author: meta["author"] as? String ?? "",
      version: meta["version"] as? Int ?? 1,
      folderName: folderName,
      metadata: flat,
      previewURL: previewURL,
      files: files
    )
  }

  private func listFiles(base: String) async throws -> [CommunityFile] {
    let (data, _) = try await URLSession.shared.data(from: repo.contentsURL(base))
    guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return items.compactMap { item in
      guard item["type"] as? String == "file",
        let name = item["name"] as? String,
        let urlStr = item["download_url"] as? String,
        let url = URL(string: urlStr)
      else { return nil }
      return CommunityFile(name: name, downloadURL: url)
    }
  }

  /// Download an entry's files as name -> bytes (skipping `metadata.json`). The
  /// consumer decides what to do with them (write to disk, parse into lanes...).
  public func downloadFiles(_ entry: CommunityEntry) async throws -> [String: Data] {
    var out: [String: Data] = [:]
    for file in entry.files where file.name != "metadata.json" {
      let (data, _) = try await URLSession.shared.data(from: file.downloadURL)
      out[file.name] = data
    }
    return out
  }
}
