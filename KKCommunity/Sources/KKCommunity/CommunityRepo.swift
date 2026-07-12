/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// The GitHub repo a community catalog reads from and publishes to. One repo
/// (`overpolish/keyframeless-community`) holds every catalog as a top-level
/// folder ("Captions", "Shaders", ...); `catalogFolder` selects which.
public struct CommunityRepo: Sendable {
  public let owner: String
  public let repo: String
  public let branch: String
  public let catalogFolder: String

  public static let apiBase = "https://api.github.com"
  public static let rawBase = "https://raw.githubusercontent.com"

  public init(
    owner: String = "overpolish",
    repo: String = "keyframeless-community",
    branch: String = "main",
    catalogFolder: String
  ) {
    self.owner = owner
    self.repo = repo
    self.branch = branch
    self.catalogFolder = catalogFolder
  }

  /// GitHub Contents API URL listing a path in the repo.
  func contentsURL(_ path: String) -> URL {
    let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    return URL(string: "\(Self.apiBase)/repos/\(owner)/\(repo)/contents/\(enc)?ref=\(branch)")!
  }

  /// Raw file URL for a path in the repo (used for metadata / asset fetches).
  func rawURL(_ path: String) -> URL {
    let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    return URL(string: "\(Self.rawBase)/\(owner)/\(repo)/\(branch)/\(enc)")!
  }

  /// A GitHub REST API URL under this repo (e.g. "git/refs", "pulls"). Used by
  /// the publisher; not percent-encoded since callers pass API path segments.
  func apiURL(_ path: String) -> URL {
    URL(string: "\(Self.apiBase)/repos/\(owner)/\(repo)/\(path)")!
  }
}
