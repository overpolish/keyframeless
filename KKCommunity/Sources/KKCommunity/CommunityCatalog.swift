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

  /// Fetch that bypasses the local URLCache. GitHub's Contents API responds with
  /// `Cache-Control: max-age=60` + ETag, so `URLSession.shared`'s default protocol
  /// cache serves a stale folder listing and newly published entries don't show up
  /// until it expires. Always reload from origin for discovery/metadata reads.
  private func fetchFresh(_ url: URL) async throws -> Data {
    var req = URLRequest(url: url)
    req.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, _) = try await URLSession.shared.data(for: req)
    return data
  }

  /// List every entry in the catalog folder, sorted by name.
  ///
  /// Prefers the precomputed manifest (`<catalog>/index.json`) served over the
  /// raw CDN: one fetch, zero GitHub REST API calls, so it never touches the
  /// 60/hour unauthenticated limit. Falls back to the Git Trees API if the
  /// manifest is missing (e.g. the generator Action hasn't run yet).
  /// `bustCache` appends a unique query param to the manifest URL so the raw
  /// CDN (Fastly, `max-age=300`) is forced to miss and refetch from origin.
  /// Set it on an explicit user refresh; without it a just-published entry can
  /// be up to 5 minutes stale at the viewer's edge node.
  public func fetchEntries(bustCache: Bool = false) async throws -> [CommunityEntry] {
    if let viaManifest = try? await fetchEntriesFromManifest(bustCache: bustCache),
      !viaManifest.isEmpty
    {
      return viaManifest
    }
    return try await fetchEntriesFromTree()
  }

  /// Read the catalog manifest and build entries directly from it. Every URL an
  /// entry needs is reconstructed from `<catalog>/<uuid>/<folder>/<file>`, so no
  /// further listing calls are made. Throws if the manifest can't be parsed
  /// (missing/404 -> non-JSON body), which routes `fetchEntries` to the tree.
  private func fetchEntriesFromManifest(bustCache: Bool) async throws -> [CommunityEntry] {
    var url = repo.manifestURL()
    if bustCache, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      comps.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
      url = comps.url ?? url
    }
    let data = try await fetchFresh(url)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let items = root["entries"] as? [[String: Any]]
    else { return [] }

    var out: [CommunityEntry] = []
    for item in items {
      guard let uuid = item["uuid"] as? String,
        let folder = item["folder"] as? String,
        let meta = item["metadata"] as? [String: Any],
        let name = meta["name"] as? String
      else { continue }

      let base = "\(repo.catalogFolder)/\(uuid)/\(folder)"
      var flat: [String: String] = [:]
      for (k, v) in meta { flat[k] = "\(v)" }

      let files = ((item["files"] as? [String]) ?? []).map {
        CommunityFile(name: $0, downloadURL: repo.rawURL("\(base)/\($0)"))
      }
      let previewName = meta["preview"] as? String
      let previewURL = previewName.map { repo.rawURL("\(base)/\($0)") }

      out.append(
        CommunityEntry(
          id: meta["id"] as? String ?? uuid,
          name: name,
          author: meta["author"] as? String ?? "",
          version: meta["version"] as? Int ?? 1,
          folderName: folder,
          metadata: flat,
          previewURL: previewURL,
          files: files
        ))
    }
    return out.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Fallback lister: one Git Trees API call returns every path in the repo;
  /// entries and their files are reconstructed from those paths, and each
  /// entry's `metadata.json` is read over the raw CDN. Costs one REST call, so
  /// it stays well under the 60/hour limit even without the manifest.
  private func fetchEntriesFromTree() async throws -> [CommunityEntry] {
    let data = try await fetchFresh(repo.treeURL())
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let nodes = root["tree"] as? [[String: Any]]
    else { return [] }

    // Group blob paths by their entry (the UUID folder just under the catalog
    // folder). Path shape: "<catalog>/<uuid>/<displayFolder>/<file...>".
    let prefix = "\(repo.catalogFolder)/"
    var filesByUUID: [String: [String]] = [:]
    var order: [String] = []
    for node in nodes {
      guard node["type"] as? String == "blob",
        let path = node["path"] as? String, path.hasPrefix(prefix)
      else { continue }
      let rest = path.dropFirst(prefix.count)
      guard let uuid = rest.split(separator: "/").first.map(String.init) else { continue }
      if filesByUUID[uuid] == nil { order.append(uuid) }
      filesByUUID[uuid, default: []].append(path)
    }

    // Fetch each entry's metadata concurrently over raw. Malformed/unreadable
    // entries drop out individually; a rate limit no longer erases the tail.
    let entries = await withTaskGroup(of: CommunityEntry?.self) { group in
      for uuid in order {
        let paths = filesByUUID[uuid] ?? []
        group.addTask { try? await self.makeEntry(uuid: uuid, paths: paths) }
      }
      var out: [CommunityEntry] = []
      for await e in group { if let e { out.append(e) } }
      return out
    }

    return entries.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  /// Build one entry from its blob paths: read `metadata.json` over raw, map the
  /// remaining paths to downloadable files. Returns nil if metadata is missing.
  private func makeEntry(uuid: String, paths: [String]) async throws -> CommunityEntry? {
    let prefix = "\(repo.catalogFolder)/\(uuid)/"
    // The display sub-dir is the first path segment after the UUID folder.
    guard
      let folderName = paths.lazy.compactMap({ p -> String? in
        guard p.hasPrefix(prefix) else { return nil }
        return p.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
      }).first
    else { return nil }

    let base = "\(repo.catalogFolder)/\(uuid)/\(folderName)"
    let metaData = try await fetchFresh(repo.rawURL("\(base)/metadata.json"))
    guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
      let name = meta["name"] as? String
    else { return nil }

    // Flatten metadata to string values so the ObjC bridge can pass it through
    // as a plain dictionary (payload-specific typed reads happen in the adapter).
    var flat: [String: String] = [:]
    for (k, v) in meta { flat[k] = "\(v)" }

    let filePrefix = "\(base)/"
    let files: [CommunityFile] = paths.compactMap { path in
      guard path.hasPrefix(filePrefix) else { return nil }
      let name = String(path.dropFirst(filePrefix.count))
      guard !name.contains("/") else { return nil }  // only files directly in the folder
      return CommunityFile(name: name, downloadURL: repo.rawURL(path))
    }

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

  /// Download an entry's files as name -> bytes (skipping `metadata.json`). The
  /// consumer decides what to do with them (write to disk, parse into lanes...).
  public func downloadFiles(_ entry: CommunityEntry) async throws -> [String: Data] {
    var out: [String: Data] = [:]
    let cacheToken = String(Int(Date().timeIntervalSince1970 * 1_000))
    for file in entry.files where file.name != "metadata.json" {
      // raw.githubusercontent.com caches branch/path URLs at the CDN edge. A
      // template replaced on `main` can therefore download its previous bytes
      // for several minutes even after the catalog was force-refreshed. Give
      // the payload request its own cache-busting URL as well as bypassing the
      // process URLCache, so delete + redownload always installs current main.
      var url = file.downloadURL
      if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: cacheToken))
        components.queryItems = items
        url = components.url ?? url
      }
      let data = try await fetchFresh(url)
      out[file.name] = data
    }
    return out
  }
}
