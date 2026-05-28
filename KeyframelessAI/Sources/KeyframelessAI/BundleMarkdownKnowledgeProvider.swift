/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Loads `.md` files from a bundle (optionally from a subdirectory) and parses
/// each as one `AIKnowledgeTopic`. Each markdown file may begin with simple
/// YAML-style frontmatter:
///
/// ```
/// ---
/// id: srt-import
/// summary: Importing SRT subtitle files
/// ---
///
/// Detailed prose here...
/// ```
///
/// If `id` is missing, the filename (without extension) is used. If `summary`
/// is missing, the first non-empty line of the body becomes the summary.
public struct BundleMarkdownKnowledgeProvider: AIKnowledgeProvider {
	public let name: String
	public let bundle: Bundle
	public let subdirectory: String?

	public init(name: String, bundle: Bundle, subdirectory: String? = nil) {
		self.name = name
		self.bundle = bundle
		self.subdirectory = subdirectory
	}

	public func topics() async -> [AIKnowledgeTopic] {
		var urls = bundle.urls(forResourcesWithExtension: "md", subdirectory: subdirectory) ?? []
		if urls.isEmpty, subdirectory != nil {
			urls = bundle.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? []
		}
		if urls.isEmpty, let resourceURL = bundle.resourceURL {
			urls = Self.recursiveMarkdownURLs(in: resourceURL)
		}

		#if DEBUG
			print(
				"[AIKnowledge \(name)] bundle=\(bundle.bundleURL.lastPathComponent) "
					+ "subdir=\(subdirectory ?? "nil") found=\(urls.count) md files")
			for url in urls { print("  - \(url.lastPathComponent)") }
		#endif

		return urls.compactMap { url in
			guard let data = try? Data(contentsOf: url),
				let raw = String(data: data, encoding: .utf8)
			else { return nil }
			return Self.parse(raw, fallbackID: url.deletingPathExtension().lastPathComponent)
		}
	}

	private static func recursiveMarkdownURLs(in root: URL) -> [URL] {
		guard
			let enumerator = FileManager.default.enumerator(
				at: root, includingPropertiesForKeys: nil,
				options: [.skipsHiddenFiles])
		else { return [] }
		var result: [URL] = []
		for case let url as URL in enumerator where url.pathExtension == "md" {
			result.append(url)
		}
		return result
	}

	static func parse(_ raw: String, fallbackID: String) -> AIKnowledgeTopic? {
		var id = fallbackID
		var summary: String?
		var body = raw

		if raw.hasPrefix("---\n") {
			let after = raw.dropFirst(4)
			if let end = after.range(of: "\n---\n") ?? after.range(of: "\n---") {
				let frontmatter = after[..<end.lowerBound]
				body = String(after[end.upperBound...])
				for line in frontmatter.split(separator: "\n") {
					let parts = line.split(separator: ":", maxSplits: 1).map {
						$0.trimmingCharacters(in: .whitespaces)
					}
					guard parts.count == 2 else { continue }
					switch parts[0].lowercased() {
					case "id": id = parts[1]
					case "summary": summary = parts[1]
					default: break
					}
				}
			}
		}

		body = body.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !body.isEmpty else { return nil }

		let finalSummary =
			summary
			?? body.split(whereSeparator: { $0.isNewline })
			.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
			.map { String($0).trimmingCharacters(in: .whitespaces) }
			?? id

		return AIKnowledgeTopic(id: id, summary: finalSummary, content: body)
	}
}
