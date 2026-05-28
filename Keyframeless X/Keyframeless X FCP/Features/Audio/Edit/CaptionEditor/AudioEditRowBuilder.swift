/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit

struct AudioEditRow: Identifiable {
	let id: Int
	var clipIndex: Int
	var clipName: String
	let text: String
	let timestamp: String
	let isHeader: Bool
	let isTranscribed: Bool
	var isCompound: Bool
	var isFromSRT: Bool = false
	var isProjectWide: Bool = false
	var sentenceStart: Double = 0
	var sentenceEnd: Double = 0
	var words: [TranscriptionStore.StoredWord] = []
	var editedWords: [TranscriptionStore.StoredWord]?
	var captionBreaks: [Int] = []
}

enum AudioEditRowBuilder {
	static func buildRows(
		clips: [FCPXMLParser.AudioClip],
		format: FCPXMLParser.ProjectFormat?,
		projectKey: String = ""
	) -> [AudioEditRow] {
		let store = TranscriptionStore.shared
		var result: [AudioEditRow] = []
		var nextID = 0

		if !projectKey.isEmpty, let pwCues = store.projectWideSrtCues(projectKey: projectKey) {
			let synthClip = TranscriptionStore.syntheticProjectWideClip(projectKey: projectKey)
			let title = String(localized: "Timeline-Wide")
			result.append(
				AudioEditRow(
					id: nextID, clipIndex: AudioModel.projectWideClipIndex,
					clipName: title, text: "", timestamp: "",
					isHeader: true, isTranscribed: true, isCompound: false,
					isFromSRT: true, isProjectWide: true))
			nextID += 1
			for cue in pwCues {
				result.append(
					srtSentenceRow(
						id: nextID, cue: cue, storageClip: synthClip,
						clipIndex: AudioModel.projectWideClipIndex, clipName: title,
						isCompound: false, isProjectWide: true,
						sourceOffset: 0, timelineOffset: 0, format: format))
				nextID += 1
			}
		}

		for idx in clips.indices {
			let clip = clips[idx]
			let words = store.words(for: clip)
			let srtCues = store.srtCues(for: clip)
			let hasTranscription = words != nil || srtCues != nil
			let fromSRT = srtCues != nil

			result.append(
				AudioEditRow(
					id: nextID, clipIndex: idx, clipName: clip.name, text: "", timestamp: "",
					isHeader: true, isTranscribed: hasTranscription, isCompound: clip.isCompound,
					isFromSRT: fromSRT))
			nextID += 1

			if let srtCues {
				for cue in srtCues {
					result.append(
						srtSentenceRow(
							id: nextID, cue: cue, storageClip: clip,
							clipIndex: idx, clipName: clip.name,
							isCompound: clip.isCompound, isProjectWide: false,
							sourceOffset: clip.sourceStart,
							timelineOffset: clip.start - clip.sourceStart, format: format))
					nextID += 1
				}
			} else if let words {
				let sentences = groupIntoSentences(words)
				for sentence in sentences {
					let text = sentence.map { $0.word.trimmingCharacters(in: .whitespaces) }
						.joined(separator: " ")
					let sourceToTimeline = Float(clip.start - clip.sourceStart)
					let timelineStart = sentence.first!.start + sourceToTimeline
					let timelineEnd = sentence.last!.end + sourceToTimeline
					let stamp =
						formatTimestamp(timelineStart, format: format) + " → "
						+ formatTimestamp(timelineEnd, format: format)
					let edited = store.editedWords(
						for: clip, sentenceStart: sentence.first!.start)
					let breaks = store.captionBreakIndices(
						for: clip, sentenceStart: sentence.first!.start)
					result.append(
						AudioEditRow(
							id: nextID,
							clipIndex: idx,
							clipName: clip.name,
							text: text,
							timestamp: stamp,
							isHeader: false,
							isTranscribed: true,
							isCompound: clip.isCompound,
							sentenceStart: Double(sentence.first!.start),
							sentenceEnd: Double(sentence.last!.end),
							words: sentence,
							editedWords: edited,
							captionBreaks: breaks ?? []
						))
					nextID += 1
				}
			}
		}
		return result
	}

	private static func srtSentenceRow(
		id: Int, cue: SRTCue, storageClip: FCPXMLParser.AudioClip,
		clipIndex: Int, clipName: String, isCompound: Bool, isProjectWide: Bool,
		sourceOffset: Double, timelineOffset: Double,
		format: FCPXMLParser.ProjectFormat?
	) -> AudioEditRow {
		let store = TranscriptionStore.shared
		let sourceStart = Float(sourceOffset + cue.startTime)
		let sourceEnd = Float(sourceOffset + cue.endTime)
		let timelineStart = sourceStart + Float(timelineOffset)
		let timelineEnd = sourceEnd + Float(timelineOffset)
		let stamp =
			formatTimestamp(timelineStart, format: format) + " → "
			+ formatTimestamp(timelineEnd, format: format)
		let synthWords =
			cue.text.split(whereSeparator: { $0.isWhitespace }).map {
				TranscriptionStore.StoredWord(
					word: String($0), start: sourceStart, end: sourceEnd)
			}
		let edited = store.editedWords(for: storageClip, sentenceStart: sourceStart)
		let breaks = store.captionBreakIndices(for: storageClip, sentenceStart: sourceStart)
		let displayText = (edited ?? synthWords).map { $0.word }.joined(separator: " ")
		return AudioEditRow(
			id: id,
			clipIndex: clipIndex,
			clipName: clipName,
			text: displayText,
			timestamp: stamp,
			isHeader: false,
			isTranscribed: true,
			isCompound: isCompound,
			isFromSRT: true,
			isProjectWide: isProjectWide,
			sentenceStart: Double(sourceStart),
			sentenceEnd: Double(sourceEnd),
			words: synthWords,
			editedWords: edited,
			captionBreaks: breaks ?? []
		)
	}

	private static let sentenceEndChars = CharacterSet(charactersIn: ".!?")
	private static let clauseBreakChars = CharacterSet(charactersIn: ".,;:!?")
	private static let pauseThreshold: Float = 1.5
	private static let softPauseThreshold: Float = 0.5
	private static let minSentenceDuration: Float = 4.0
	private static let maxDuration: Float = 7.0
	private static let hardMaxDuration: Float = 10.0

	private static func groupIntoSentences(
		_ words: [TranscriptionStore.StoredWord]
	) -> [[TranscriptionStore.StoredWord]] {
		guard !words.isEmpty else { return [] }

		var sentences: [[TranscriptionStore.StoredWord]] = []
		var current: [TranscriptionStore.StoredWord] = []

		for word in words {
			if let prev = current.last {
				let gap = word.start - prev.end
				let duration = prev.end - current.first!.start
				if gap > pauseThreshold
					|| (gap > softPauseThreshold && duration >= minSentenceDuration)
				{
					sentences.append(current)
					current = []
				}
			}

			current.append(word)

			let duration = current.last!.end - current.first!.start
			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			let lastScalar = trimmed.unicodeScalars.last
			let endsWithSentenceEnd = lastScalar.map { sentenceEndChars.contains($0) } == true
			let endsWithClauseBreak = lastScalar.map { clauseBreakChars.contains($0) } == true

			if endsWithSentenceEnd && duration >= minSentenceDuration {
				sentences.append(current)
				current = []
			} else if duration >= maxDuration && endsWithClauseBreak {
				sentences.append(current)
				current = []
			} else if duration >= hardMaxDuration {
				sentences.append(current)
				current = []
			}
		}

		if !current.isEmpty {
			sentences.append(current)
		}

		return sentences
	}

	private static func formatTimestamp(
		_ time: Float, format: FCPXMLParser.ProjectFormat?
	) -> String {
		let t = max(0, Double(time))
		if let format {
			let tc = format.timecode(for: t)
			var parts = tc.split(separator: ":").map { $0.count < 2 ? "0\($0)" : String($0) }
			while parts.count < 4 { parts.insert("00", at: 0) }
			return parts.joined(separator: ":")
		}
		let totalSecs = Int(t)
		let ss = totalSecs % 60
		let mm = (totalSecs / 60) % 60
		let hh = totalSecs / 3600
		let ms = Int((t - Double(totalSecs)) * 100)
		return String(format: "%02d:%02d:%02d.%02d", hh, mm, ss, ms)
	}
}
