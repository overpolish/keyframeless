/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Combine
import Foundation

struct CommunityTemplate: Identifiable {
	let id: String
	let name: String
	let author: String
	let perWord: Bool
	let params: [[String: String]]
	let previewGifURL: URL
	let folderName: String
}

class CommunityTemplateStore: ObservableObject {
	static let shared = CommunityTemplateStore()

	static let owner = "overpolish"
	static let repo = "keyframeless-community"
	static let branch = "main"
	static let apiBase = "https://api.github.com"
	static let rawBase = "https://raw.githubusercontent.com"

	@Published private(set) var templates: [CommunityTemplate] = []
	@Published private(set) var isLoading = false
	@Published private(set) var error: String?

	private var hasFetched = false

	func fetchIfNeeded() {
		guard !hasFetched, !isLoading else { return }
		hasFetched = true
		fetch()
	}

	func fetch() {
		guard !isLoading else { return }
		isLoading = true
		error = nil

		Task {
			do {
				let templates = try await Self.loadTemplates()
				await MainActor.run {
					self.templates = templates
					self.isLoading = false
				}
			} catch {
				await MainActor.run {
					self.error = error.localizedDescription
					self.isLoading = false
				}
			}
		}
	}

	private static func loadTemplates() async throws -> [CommunityTemplate] {
		let contentsURL = URL(
			string: "\(apiBase)/repos/\(owner)/\(repo)/contents/Captions?ref=\(branch)")!
		let (data, _) = try await URLSession.shared.data(from: contentsURL)
		guard let folders = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
		else { return [] }

		var results: [CommunityTemplate] = []

		for folder in folders {
			guard let folderName = folder["name"] as? String,
				folder["type"] as? String == "dir"
			else { continue }

			guard let template = try? await loadTemplate(uuid: folderName) else { continue }
			results.append(template)
		}

		return results.sorted {
			$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
	}

	private static func loadTemplate(uuid: String) async throws -> CommunityTemplate? {
		let contentsURL = URL(
			string: "\(apiBase)/repos/\(owner)/\(repo)/contents/Captions/\(uuid)?ref=\(branch)")!
		let (data, _) = try await URLSession.shared.data(from: contentsURL)
		guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
		else { return nil }

		guard let templateDir = items.first(where: { $0["type"] as? String == "dir" }),
			let templateFolderName = templateDir["name"] as? String
		else { return nil }

		let metadataURL = URL(
			string:
				"\(rawBase)/\(owner)/\(repo)/\(branch)/Captions/\(uuid)/\(templateFolderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? templateFolderName)/metadata.json"
		)!
		let (metaData, _) = try await URLSession.shared.data(from: metadataURL)
		guard let meta = try JSONSerialization.jsonObject(with: metaData) as? [String: Any],
			let name = meta["name"] as? String
		else { return nil }

		let previewGifURL = URL(
			string:
				"\(rawBase)/\(owner)/\(repo)/\(branch)/Captions/\(uuid)/\(templateFolderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? templateFolderName)/preview.gif"
		)!

		return CommunityTemplate(
			id: meta["id"] as? String ?? uuid,
			name: name,
			author: meta["author"] as? String ?? "",
			perWord: meta["perWord"] as? Bool ?? false,
			params: meta["params"] as? [[String: String]] ?? [],
			previewGifURL: previewGifURL,
			folderName: templateFolderName
		)
	}

	private static let installBase: URL = {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(
				"Movies/Motion Templates.localized/Titles.localized/Keyframeless")
	}()

	static func download(_ template: CommunityTemplate) async throws {
		let contentsURL = URL(
			string:
				"\(apiBase)/repos/\(owner)/\(repo)/contents/Captions/\(template.id)/\(template.folderName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? template.folderName)?ref=\(branch)"
		)!
		let (data, _) = try await URLSession.shared.data(from: contentsURL)
		guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
		else { return }

		let destDir = installBase.appendingPathComponent(template.name)
		try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

		if !template.author.isEmpty {
			let authorFile = destDir.appendingPathComponent("author.txt")
			try template.author.write(to: authorFile, atomically: true, encoding: .utf8)
		}

		for item in items {
			guard let fileName = item["name"] as? String,
				let downloadURL = item["download_url"] as? String,
				let url = URL(string: downloadURL),
				fileName != "metadata.json"
			else { continue }

			let (fileData, _) = try await URLSession.shared.data(from: url)
			let destFile: URL
			if fileName.hasSuffix(".moti") {
				destFile = destDir.appendingPathComponent("\(template.name).moti")
			} else {
				destFile = destDir.appendingPathComponent(fileName)
			}
			try fileData.write(to: destFile)
		}
	}
}
