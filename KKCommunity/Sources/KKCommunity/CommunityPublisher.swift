/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Payload-agnostic publish: pushes an entry's files to the catalog folder via
/// the GitHub Git Data API and opens a PR into the base branch. Lifted from
/// Steno's caption publisher, generified over `CommunityRepo` and a plain file
/// set (each shader tab is a file; captions are the .moti bundle's files). The
/// same bot PAT publishes every catalog.
public struct CommunityPublisher: Sendable {
  public let repo: CommunityRepo

  public init(repo: CommunityRepo) {
    self.repo = repo
  }

  /// Everything a publish needs. `files` maps a filename to its bytes (code tabs,
  /// preview.png, ...); `metadataJSON` is the already-serialized metadata.json.
  public struct Payload: Sendable {
    public let id: String
    public let name: String
    public let author: String
    public let version: Int
    public let files: [String: Data]
    public let metadataJSON: Data

    public init(
      id: String, name: String, author: String, version: Int,
      files: [String: Data], metadataJSON: Data
    ) {
      self.id = id
      self.name = name
      self.author = author
      self.version = version
      self.files = files
      self.metadataJSON = metadataJSON
    }
  }

  public enum PublishError: LocalizedError {
    case gitHub(String)
    public var errorDescription: String? {
      switch self {
      case .gitHub(let msg): return "GitHub: \(msg)"
      }
    }
  }

  public func publish(_ payload: Payload) async throws {
    let token = CommunityToken.decoded
    let branchName = "community/\(payload.id)"
    let isUpdate = payload.version > 1
    let folder = sanitize(payload.name)
    let base = "\(repo.catalogFolder)/\(payload.id)/\(folder)"

    let mainSHA = try await getRef(repo.branch, token)
    if isUpdate { try? await updateRef(branchName, mainSHA, token) }
    do {
      try await createRef(branchName, mainSHA, token)
    } catch {
      try await updateRef(branchName, mainSHA, token)
    }

    var tree: [[String: String]] = []
    for (name, data) in payload.files {
      let sha = try await createBlob(data, token)
      tree.append([
        "path": "\(base)/\(sanitize(name))", "mode": "100644", "type": "blob", "sha": sha,
      ])
    }
    let metaSHA = try await createBlob(payload.metadataJSON, token)
    tree.append([
      "path": "\(base)/metadata.json", "mode": "100644", "type": "blob", "sha": metaSHA,
    ])

    // Base off the existing branch tree on update so unchanged files survive.
    var baseTreeSHA = mainSHA
    if isUpdate, let t = try? await getTreeSHA(branchName, token) { baseTreeSHA = t }

    let treeSHA = try await createTree(baseTreeSHA, tree, token)
    let msg =
      isUpdate
      ? "Update \(repo.catalogFolder): \(payload.name) to v\(payload.version)"
      : "Add \(repo.catalogFolder): \(payload.name)"
    let commitSHA = try await createCommit(msg, treeSHA, mainSHA, token)
    try await updateRef(branchName, commitSHA, token)

    let title =
      isUpdate
      ? "Update \(payload.name) v\(payload.version)" : "Add \(payload.name)"
    var body =
      isUpdate
      ? "Updates **\(payload.name)** to version \(payload.version)"
      : "Adds **\(payload.name)**"
    if !payload.author.isEmpty { body += " by \(payload.author)" }
    body += "\n\nID: `\(payload.id)`"
    try await createPR(title, body, branchName, token)
  }

  private func sanitize(_ s: String) -> String {
    s.replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "\\", with: "-")
      .replacingOccurrences(of: "\0", with: "")
  }

  private func getRef(_ branch: String, _ token: String) async throws -> String {
    let data = try await request(
      repo.apiURL("git/ref/heads/\(branch)"), "GET", nil, token)
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let obj = j["object"] as? [String: Any], let sha = obj["sha"] as? String
    else { throw PublishError.gitHub("Failed to get ref for \(branch)") }
    return sha
  }

  private func getTreeSHA(_ branch: String, _ token: String) async throws -> String {
    let commitSHA = try await getRef(branch, token)
    let data = try await request(repo.apiURL("git/commits/\(commitSHA)"), "GET", nil, token)
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tree = j["tree"] as? [String: Any], let sha = tree["sha"] as? String
    else { throw PublishError.gitHub("Failed to get tree SHA") }
    return sha
  }

  private func createRef(_ branch: String, _ sha: String, _ token: String) async throws {
    _ = try await request(
      repo.apiURL("git/refs"), "POST", ["ref": "refs/heads/\(branch)", "sha": sha], token)
  }

  private func createBlob(_ data: Data, _ token: String) async throws -> String {
    let r = try await request(
      repo.apiURL("git/blobs"), "POST",
      ["content": data.base64EncodedString(), "encoding": "base64"], token)
    guard let j = try JSONSerialization.jsonObject(with: r) as? [String: Any],
      let sha = j["sha"] as? String
    else { throw PublishError.gitHub("Failed to create blob") }
    return sha
  }

  private func createTree(
    _ baseTreeSHA: String, _ entries: [[String: String]], _ token: String
  ) async throws -> String {
    let data = try await request(
      repo.apiURL("git/trees"), "POST", ["base_tree": baseTreeSHA, "tree": entries], token)
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sha = j["sha"] as? String
    else { throw PublishError.gitHub("Failed to create tree") }
    return sha
  }

  private func createCommit(
    _ message: String, _ treeSHA: String, _ parentSHA: String, _ token: String
  ) async throws -> String {
    let data = try await request(
      repo.apiURL("git/commits"), "POST",
      ["message": message, "tree": treeSHA, "parents": [parentSHA]], token)
    guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let sha = j["sha"] as? String
    else { throw PublishError.gitHub("Failed to create commit") }
    return sha
  }

  private func updateRef(_ branch: String, _ sha: String, _ token: String) async throws {
    _ = try await request(
      repo.apiURL("git/refs/heads/\(branch)"), "PATCH", ["sha": sha, "force": true], token)
  }

  private func createPR(
    _ title: String, _ body: String, _ head: String, _ token: String
  ) async throws {
    _ = try await request(
      repo.apiURL("pulls"), "POST",
      ["title": title, "body": body, "head": head, "base": repo.branch], token)
  }

  private func request(
    _ url: URL, _ method: String, _ body: [String: Any]?, _ token: String
  ) async throws -> Data {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    if let body {
      req.httpBody = try JSONSerialization.data(withJSONObject: body)
      req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else {
      throw PublishError.gitHub("Invalid response")
    }
    if http.statusCode >= 400 {
      let msg =
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"]
        as? String ?? "HTTP \(http.statusCode)"
      throw PublishError.gitHub(msg)
    }
    return data
  }
}

/// The shared bot PAT, obfuscated as two XOR'd byte arrays decoded at runtime.
/// One account publishes every catalog's PRs. Copied verbatim from Steno.
enum CommunityToken {
  private static let _k: [UInt8] = [
    0x5a, 0x07, 0x7a, 0xa5, 0x86, 0x2c, 0x25, 0xdc, 0xb6, 0x6c, 0x14, 0x6c, 0xa7, 0x91,
    0xd6, 0x3c,
    0x6d, 0x1c, 0x1a, 0x55, 0xd8, 0xf7, 0xaa, 0x27, 0x70, 0x50, 0xb3, 0xd0, 0x18, 0xe3,
    0x63, 0xbe,
    0xee, 0xa4, 0x89, 0xb9, 0x0c, 0x75, 0x90, 0x7e, 0xba, 0x06, 0xc2, 0x9f, 0x31, 0x6e,
    0x47, 0x05,
    0xbd, 0x1c, 0xb4, 0x1a, 0xf4, 0xff, 0xe3, 0x24, 0x90, 0x6f, 0x56, 0x8b, 0x94, 0xc9,
    0x58, 0xe1,
    0x95, 0x4c, 0xa5, 0xf6, 0x34, 0x28, 0x9d, 0xf8, 0x06, 0x4b, 0x91, 0xab, 0x71, 0x71,
    0x29, 0x7f,
    0x5a, 0xdd, 0x51, 0xd5, 0x45, 0xc3, 0xac, 0x7d, 0x38, 0xcf, 0xb8, 0xa8, 0x36,
  ]
  private static let _c: [UInt8] = [
    0x3d, 0x6e, 0x0e, 0xcd, 0xf3, 0x4e, 0x7a, 0xac, 0xd7, 0x18, 0x4b, 0x5d, 0x96, 0xd0,
    0x9e, 0x0a,
    0x3e, 0x28, 0x49, 0x0c, 0xe8, 0xc1, 0xeb, 0x55, 0x0a, 0x25, 0xdb, 0x9d, 0x68, 0x8b,
    0x09, 0xc8,
    0xde, 0xfb, 0xec, 0x8b, 0x4e, 0x01, 0xd7, 0x06, 0xdc, 0x61, 0xf0, 0xe6, 0x73, 0x29,
    0x0c, 0x66,
    0xfe, 0x5b, 0xd0, 0x62, 0xa5, 0x8e, 0x94, 0x76, 0xc4, 0x0e, 0x1c, 0xcf, 0xd2, 0xa5,
    0x16, 0xa8,
    0xad, 0x2e, 0xe8, 0x9a, 0x79, 0x61, 0xe9, 0xca, 0x6e, 0x28, 0xf9, 0xea, 0x0b, 0x32,
    0x6f, 0x4c,
    0x03, 0x8a, 0x14, 0x91, 0x09, 0xab, 0xfd, 0x16, 0x6a, 0x9a, 0xd7, 0xc2, 0x44,
  ]
  static var decoded: String {
    String(bytes: zip(_k, _c).map { $0 ^ $1 }, encoding: .utf8) ?? ""
  }
}
