/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

class TranscriptionStore {

	static let shared = TranscriptionStore()

	struct StoredWord: Codable {
		let word: String
		let start: Float
		let end: Float
		let probability: Float
	}

	struct ClipKey: Codable, Hashable {
		let sourceName: String
		let sourceStart: Double
		let sourceDuration: Double

		init(clip: FCPXMLParser.AudioClip) {
			self.sourceName = clip.url?.lastPathComponent ?? clip.name
			self.sourceStart = clip.sourceStart
			self.sourceDuration = clip.sourceDuration
		}
	}

	private var entries: [ClipKey: [StoredWord]] = [:]

	private init() { load() }

	func words(for clip: FCPXMLParser.AudioClip) -> [StoredWord]? {
		entries[ClipKey(clip: clip)]
	}

	func store(words: [AudioTranscriber.WordResult], for clip: FCPXMLParser.AudioClip) {
		let stored = words.map {
			StoredWord(word: $0.word, start: $0.start, end: $0.end, probability: $0.probability)
		}
		entries[ClipKey(clip: clip)] = stored
		save()
	}

	func store(results: [AudioTranscriber.ClipResult], clips: [FCPXMLParser.AudioClip]) {
		for result in results {
			guard clips.indices.contains(result.clipIndex) else { continue }
			if result.words.isEmpty {
				print(
					"[TranscriptionStore] clip \(result.clipIndex) (\(clips[result.clipIndex].name)) produced 0 words — skipping store"
				)
				continue
			}
			store(words: result.words, for: clips[result.clipIndex])
		}
	}

	func removeAll() {
		entries = [:]
		save()
	}

	private var fileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/transcription_store.json")
	}

	private func load() {
		guard let url = fileURL,
			let data = try? Data(contentsOf: url),
			let decoded = try? JSONDecoder().decode([ClipKey: [StoredWord]].self, from: data)
		else { return }
		entries = decoded
	}

	private func save() {
		guard let url = fileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
	}

}
