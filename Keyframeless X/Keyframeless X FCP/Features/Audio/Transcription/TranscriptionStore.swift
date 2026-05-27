/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

class TranscriptionStore {

	static let shared = TranscriptionStore()

	struct StoredWord: Codable {
		let word: String
		let start: Float
		let end: Float
	}

	struct ClipKey: Codable, Hashable {
		let sourceName: String
		let sourceStart: Double
		let sourceDuration: Double
		let timelineStart: Double

		init(clip: FCPXMLParser.AudioClip) {
			self.sourceName = clip.url?.path ?? clip.name
			self.sourceStart = clip.sourceStart
			self.sourceDuration = clip.sourceDuration
			self.timelineStart = clip.start
		}
	}

	private var entries: [ClipKey: [StoredWord]] = [:]
	private var sentenceEdits: [ClipKey: [String: [StoredWord]]] = [:]
	private var captionBreaks: [ClipKey: [String: [Int]]] = [:]
	private var srtCueStore: [ClipKey: [SRTCue]] = [:]

	private init() {
		load()
		loadEdits()
		loadBreaks()
		loadSrtCues()
	}

	static func syntheticProjectWideClip(projectKey: String) -> FCPXMLParser.AudioClip {
		FCPXMLParser.AudioClip(
			name: "project:\(projectKey)",
			start: 0, end: 0,
			sourceStart: 0, sourceDuration: 0,
			url: nil, bookmark: nil,
			isCompound: false,
			volumeCurve: nil, fadeIn: nil, fadeOut: nil,
			auFilters: nil, sourceChannels: nil, unhandledAdjustments: nil
		)
	}

	func words(for clip: FCPXMLParser.AudioClip) -> [StoredWord]? {
		entries[ClipKey(clip: clip)]
	}

	func srtCues(for clip: FCPXMLParser.AudioClip) -> [SRTCue]? {
		srtCueStore[ClipKey(clip: clip)]
	}

	func storeSrtCues(_ cues: [SRTCue], for clip: FCPXMLParser.AudioClip) {
		srtCueStore[ClipKey(clip: clip)] = cues
		saveSrtCues()
	}

	func removeSrtCues(for clip: FCPXMLParser.AudioClip) {
		srtCueStore[ClipKey(clip: clip)] = nil
		saveSrtCues()
	}

	func projectWideSrtCues(projectKey: String) -> [SRTCue]? {
		srtCues(for: Self.syntheticProjectWideClip(projectKey: projectKey))
	}

	func storeProjectWideSrtCues(_ cues: [SRTCue], projectKey: String) {
		storeSrtCues(cues, for: Self.syntheticProjectWideClip(projectKey: projectKey))
	}

	func removeProjectWideSrtCues(projectKey: String) {
		removeSrtCues(for: Self.syntheticProjectWideClip(projectKey: projectKey))
	}

	func removeWords(for clip: FCPXMLParser.AudioClip) {
		let key = ClipKey(clip: clip)
		entries[key] = nil
		sentenceEdits[key] = nil
		captionBreaks[key] = nil
		save()
		saveEdits()
		saveBreaks()
	}

	func isSrtImported(_ clip: FCPXMLParser.AudioClip) -> Bool {
		srtCueStore[ClipKey(clip: clip)] != nil
	}

	func isTranscribed(_ clip: FCPXMLParser.AudioClip) -> Bool {
		entries[ClipKey(clip: clip)] != nil || srtCueStore[ClipKey(clip: clip)] != nil
	}

	func editedWords(
		for clip: FCPXMLParser.AudioClip, sentenceStart: Float
	) -> [StoredWord]? {
		sentenceEdits[ClipKey(clip: clip)]?[sentenceStartKey(sentenceStart)]
	}

	func setEditedWords(
		_ words: [StoredWord]?, for clip: FCPXMLParser.AudioClip, sentenceStart: Float
	) {
		let key = ClipKey(clip: clip)
		let sKey = sentenceStartKey(sentenceStart)
		if let words {
			if sentenceEdits[key] == nil { sentenceEdits[key] = [:] }
			sentenceEdits[key]![sKey] = words
		} else {
			sentenceEdits[key]?[sKey] = nil
			if sentenceEdits[key]?.isEmpty == true {
				sentenceEdits[key] = nil
			}
		}
		saveEdits()
	}

	static func alignWords(
		original: [StoredWord], editedText: String
	) -> [StoredWord] {
		let editedTokens =
			editedText
			.split(separator: " ", omittingEmptySubsequences: true)
			.map(String.init)
		guard !editedTokens.isEmpty else { return [] }

		let origNorm = original.map { normalize($0.word) }
		let editNorm = editedTokens.map { normalize($0) }
		let n = origNorm.count
		let m = editNorm.count

		// LCS DP table
		var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
		for i in 1...n {
			for j in 1...m {
				if origNorm[i - 1] == editNorm[j - 1] {
					dp[i][j] = dp[i - 1][j - 1] + 1
				} else {
					dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
				}
			}
		}

		// Backtrack to find which edited words match which originals
		var matchMap: [Int: Int] = [:]  // editIndex -> origIndex
		var i = n
		var j = m
		while i > 0 && j > 0 {
			if origNorm[i - 1] == editNorm[j - 1] {
				matchMap[j - 1] = i - 1
				i -= 1
				j -= 1
			} else if dp[i - 1][j] > dp[i][j - 1] {
				i -= 1
			} else {
				j -= 1
			}
		}

		// Build aligned words with interpolated timestamps for unmatched
		var result: [StoredWord] = []
		var unmatched: [Int] = []

		for ei in 0..<m {
			if matchMap[ei] != nil {
				if !unmatched.isEmpty {
					result.append(
						contentsOf: interpolate(
							indices: unmatched, tokens: editedTokens,
							original: original, matchMap: matchMap))
					unmatched = []
				}
				let oi = matchMap[ei]!
				result.append(
					StoredWord(
						word: editedTokens[ei],
						start: original[oi].start,
						end: original[oi].end))
			} else {
				unmatched.append(ei)
			}
		}
		if !unmatched.isEmpty {
			result.append(
				contentsOf: interpolate(
					indices: unmatched, tokens: editedTokens,
					original: original, matchMap: matchMap))
		}

		return result
	}

	private static func normalize(_ word: String) -> String {
		word.trimmingCharacters(in: .whitespaces)
			.lowercased()
			.trimmingCharacters(in: .punctuationCharacters)
	}

	private static func interpolate(
		indices: [Int], tokens: [String],
		original: [StoredWord], matchMap: [Int: Int]
	) -> [StoredWord] {
		// Find time bounds from neighboring matched words
		let prevMatched = (0..<indices.first!).last { matchMap[$0] != nil }
		let nextMatched = ((indices.last! + 1)..<tokens.count).first { matchMap[$0] != nil }

		let rangeStart: Float
		let rangeEnd: Float

		if let pi = prevMatched, let oi = matchMap[pi] {
			rangeStart = original[oi].end
		} else {
			rangeStart = original.first?.start ?? 0
		}

		if let ni = nextMatched, let oi = matchMap[ni] {
			rangeEnd = original[oi].start
		} else {
			rangeEnd = original.last?.end ?? rangeStart
		}

		let count = Float(indices.count)
		let sliceDuration = max(0, rangeEnd - rangeStart) / count

		return indices.enumerated().map { offset, ei in
			StoredWord(
				word: tokens[ei],
				start: rangeStart + Float(offset) * sliceDuration,
				end: rangeStart + Float(offset + 1) * sliceDuration)
		}
	}

	private func sentenceStartKey(_ start: Float) -> String {
		String(format: "%.4f", start)
	}

	func store(words: [AudioTranscriber.WordResult], for clip: FCPXMLParser.AudioClip) {
		let stored = words.map {
			StoredWord(word: $0.word, start: $0.start, end: $0.end)
		}
		entries[ClipKey(clip: clip)] = stored
		save()
	}

	func store(results: [AudioTranscriber.ClipResult], clips: [FCPXMLParser.AudioClip]) {
		for result in results {
			guard clips.indices.contains(result.clipIndex) else { continue }
			if result.words.isEmpty {
				print(
					"[TranscriptionStore] clip \(result.clipIndex) (\(clips[result.clipIndex].name)) produced 0 words - skipping store"
				)
				continue
			}
			store(words: result.words, for: clips[result.clipIndex])
		}
	}

	func captionBreakIndices(
		for clip: FCPXMLParser.AudioClip, sentenceStart: Float
	) -> [Int]? {
		captionBreaks[ClipKey(clip: clip)]?[sentenceStartKey(sentenceStart)]
	}

	func setCaptionBreakIndices(
		_ indices: [Int]?, for clip: FCPXMLParser.AudioClip, sentenceStart: Float
	) {
		let key = ClipKey(clip: clip)
		let sKey = sentenceStartKey(sentenceStart)
		if let indices, !indices.isEmpty {
			if captionBreaks[key] == nil { captionBreaks[key] = [:] }
			captionBreaks[key]![sKey] = indices.sorted()
		} else {
			captionBreaks[key]?[sKey] = nil
			if captionBreaks[key]?.isEmpty == true {
				captionBreaks[key] = nil
			}
		}
		saveBreaks()
	}

	func toggleCaptionBreak(
		at wordIndex: Int, for clip: FCPXMLParser.AudioClip, sentenceStart: Float
	) {
		var indices = captionBreakIndices(for: clip, sentenceStart: sentenceStart) ?? []
		if let existing = indices.firstIndex(of: wordIndex) {
			indices.remove(at: existing)
		} else {
			indices.append(wordIndex)
		}
		setCaptionBreakIndices(
			indices.isEmpty ? nil : indices, for: clip, sentenceStart: sentenceStart)
	}

	func removeAll() {
		entries = [:]
		captionBreaks = [:]
		srtCueStore = [:]
		save()
		saveBreaks()
		saveSrtCues()
	}

	private func load() {
		entries =
			KKStore.load([ClipKey: [StoredWord]].self, from: "transcription_store.json") ?? [:]
	}

	private func save() {
		KKStore.save(entries, to: "transcription_store.json")
	}

	private func loadEdits() {
		sentenceEdits =
			KKStore.load([ClipKey: [String: [StoredWord]]].self, from: "transcription_edits.json")
			?? [:]
	}

	private func saveEdits() {
		KKStore.save(sentenceEdits, to: "transcription_edits.json")
	}

	private func loadBreaks() {
		captionBreaks =
			KKStore.load([ClipKey: [String: [Int]]].self, from: "transcription_breaks.json") ?? [:]
	}

	private func saveBreaks() {
		KKStore.save(captionBreaks, to: "transcription_breaks.json")
	}

	private func loadSrtCues() {
		srtCueStore =
			KKStore.load([ClipKey: [SRTCue]].self, from: "transcription_srt.json")
			?? [:]
	}

	private func saveSrtCues() {
		KKStore.save(srtCueStore, to: "transcription_srt.json")
	}

}
