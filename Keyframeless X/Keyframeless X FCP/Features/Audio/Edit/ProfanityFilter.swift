/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

enum ProfanityFilter {
	static func isProfane(_ word: String, language: String?) -> Bool {
		let wordSet = wordSet(for: language)
		guard !wordSet.isEmpty else { return false }
		let normalized =
			word
			.lowercased()
			.trimmingCharacters(in: .punctuationCharacters)
		return wordSet.contains(normalized)
	}

	static let availableLanguages: Set<String> = {
		let bundle = Bundle(for: BundleToken.self)
		// Folder reference: Profanity/*.txt
		if let resourceURL = bundle.resourceURL {
			let profanityDir = resourceURL.appendingPathComponent("Profanity")
			if let files = try? FileManager.default.contentsOfDirectory(atPath: profanityDir.path) {
				let codes =
					files
					.filter { $0.hasSuffix(".txt") }
					.map { String($0.dropLast(4)) }
				if !codes.isEmpty { return Set(codes) }
			}
		}
		// Group: profanity_*.txt flat in bundle
		let all =
			bundle.paths(forResourcesOfType: "txt", inDirectory: nil)
			.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
			.filter { $0.hasPrefix("profanity_") }
			.map { String($0.dropFirst("profanity_".count)) }
		return Set(all)
	}()

	private static var cache: [String: Set<String>] = [:]

	private static func wordSet(for language: String?) -> Set<String> {
		let code = language ?? "en"
		if let cached = cache[code] { return cached }
		let loaded = loadWordSet(code: code)
		cache[code] = loaded
		return loaded
	}

	private static func loadWordSet(code: String) -> Set<String> {
		let bundle = Bundle(for: BundleToken.self)
		let url =
			bundle.url(forResource: code, withExtension: "txt", subdirectory: "Profanity")
			?? bundle.url(forResource: "profanity_\(code)", withExtension: "txt")
		guard let url else { return [] }
		guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
		let words =
			contents
			.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
			.filter { !$0.isEmpty }
		return Set(words)
	}
}

private class BundleToken {}
