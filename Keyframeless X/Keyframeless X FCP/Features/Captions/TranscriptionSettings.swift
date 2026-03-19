/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

class TranscriptionSettings {

	static let shared = TranscriptionSettings()

	var selectedModel: String?
	var selectedLanguage: String?

	private init() { load() }

	private struct Persisted: Codable {
		var selectedModel: String?
		var selectedLanguage: String?
	}

	private var fileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/transcription_settings.json")
	}

	private func load() {
		guard let url = fileURL,
			let data = try? Data(contentsOf: url),
			let state = try? JSONDecoder().decode(Persisted.self, from: data)
		else { return }
		selectedModel = state.selectedModel
		selectedLanguage = state.selectedLanguage
	}

	func save() {
		guard let url = fileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(
			Persisted(selectedModel: selectedModel, selectedLanguage: selectedLanguage)
		).write(
			to: url, options: .atomic)
	}

}
