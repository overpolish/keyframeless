/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

class AudioSetupSettings {

	static let shared = AudioSetupSettings()

	var selectedModel: String?
	var selectedLanguage: String?
	var translateToEnglish: Bool = false
	var hotWords: [String] = []

	private init() { load() }

	private struct Persisted: Codable {
		var selectedModel: String?
		var selectedLanguage: String?
		var translateToEnglish: Bool?
		var hotWords: [String]?
	}

	private var fileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/audio_setup_settings.json")
	}

	private func load() {
		guard let url = fileURL,
			let data = try? Data(contentsOf: url),
			let state = try? JSONDecoder().decode(Persisted.self, from: data)
		else { return }
		selectedModel = state.selectedModel
		selectedLanguage = state.selectedLanguage
		translateToEnglish = state.translateToEnglish ?? false
		hotWords = state.hotWords ?? []
	}

	func save() {
		guard let url = fileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(
			Persisted(
				selectedModel: selectedModel, selectedLanguage: selectedLanguage,
				translateToEnglish: translateToEnglish, hotWords: hotWords
			)
		).write(
			to: url, options: .atomic)
	}

}
