/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import KeyframelessKit
import SwiftUI

struct AudioEditView: View {
	@ObservedObject var model: AudioModel
	@StateObject private var player = AudioPlayer()

	@State private var rows: [Row] = []
	@State private var hoveredClipIndex: Int?

	private var editSelectedClips: Binding<Set<Int>> {
		Binding(
			get: { model.editSelectedClips ?? [] },
			set: { model.editSelectedClips = $0 }
		)
	}

	struct Row: Identifiable {
		let id: Int
		let clipIndex: Int
		let clipName: String
		let text: String
		let timestamp: String
		let isHeader: Bool
		let isTranscribed: Bool
		var sentenceStart: Double = 0
		var sentenceEnd: Double = 0
	}

	var body: some View {
		GeometryReader { geo in
			VStack(spacing: KKSpacingLG) {
				HStack {
					if let item = model.dropItems.first {
						Text(item.name)
							.font(.title2)
							.lineLimit(1)
					}
					Spacer()
					ClipSelectionToolbar(
						clips: model.audioClips,
						selectedClips: editSelectedClips,
						allowedIndices: transcribedIndices
					)
				}
				VStack(spacing: 0) {
					ZStack {
						RoundedRectangle(cornerRadius: CGFloat(KKRadiusMD))
							.strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1.5)
						if transcribedIndices.isEmpty {
							VStack(spacing: KKSpacingLG) {
								Image(systemName: "waveform.slash")
									.font(.title)
									.foregroundStyle(Color(nsColor: .timelineLabel()))
								Text("No transcribed clips")
									.font(.title3)
									.foregroundStyle(Color(nsColor: .timelineLabel()))
							}
						} else {
							TimelineAxisView(
								duration: timelineDuration,
								format: model.projectFormat,
								useTimecode: model.useTimecode,
								clips: model.audioClips,
								selectedClips: editSelectedClips,
								dimmedIndices: untranscribedIndices,
								showWaveforms: false,
								hoveredClipIndex: $hoveredClipIndex,
								onClickDimmed: { index in
									model.selectedClips = [index]
									model.stage = .setup
								}
							)
						}
					}
					.frame(height: geo.size.height * 0.2)
					.overlay(alignment: .bottomTrailing) {
						HelperText(
							"Click and drag to quickly select/deselect clips",
							systemImage: "pointer.arrow.motionlines"
						)
						.padding(.trailing, KKPaddingSM)
						.alignmentGuide(.bottom) { d in d[.top] - KKSpacingMD }
					}
					ClipCountDisplay(
						selectedCount: model.editSelectedClips?.count ?? 0,
						totalCount: transcribedIndices.count,
						emptyLabel: "No Transcriptions Found",
						selectedLabel: "Transcriptions Selected"
					)
					.padding(.top, KKSpacingMD)
				}
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(rows) { row in
							if row.isHeader {
								if row.isTranscribed {
									HStack(spacing: KKSpacingMD) {
										Toggle(
											isOn: Binding(
												get: {
													editSelectedClips.wrappedValue.contains(
														row.clipIndex)
												},
												set: { isOn in
													if isOn {
														editSelectedClips.wrappedValue.insert(
															row.clipIndex)
													} else {
														editSelectedClips.wrappedValue.remove(
															row.clipIndex)
													}
												}
											)
										) {
											Text(row.clipName)
												.font(.system(size: 12, weight: .semibold))
												.foregroundStyle(.secondary)
										}
										.toggleStyle(.checkbox)
										.tint(Color(nsColor: .accent()))
									}
									.padding(.top, KKSpacingLG)
									.padding(.bottom, KKSpacingXS)
								} else {
									UntranscribedClipRow(
										clipName: row.clipName,
										clipIndex: row.clipIndex,
										isHighlighted: hoveredClipIndex == row.clipIndex,
										hoveredClipIndex: $hoveredClipIndex
									) {
										model.selectedClips = [row.clipIndex]
										model.stage = .setup
									}
									.padding(.top, KKSpacingLG)
									.padding(.bottom, KKSpacingXS)
								}
							} else {
								HStack(alignment: .top, spacing: KKSpacingMD) {
									PlayButton(
										isPlaying: player.isPlaying(index: row.id)
									) {
										player.toggleRange(
											clip: model.audioClips[row.clipIndex],
											index: row.id,
											from: row.sentenceStart,
											to: row.sentenceEnd
										)
									}
									Text(row.timestamp)
										.font(.system(size: 11).monospacedDigit())
										.foregroundStyle(.tertiary)
										.frame(width: 80, alignment: .trailing)
									Text(row.text)
										.font(.system(size: 13))
									Spacer()
								}
								.padding(.vertical, KKPaddingXS)
								.padding(.horizontal, KKPaddingSM)
								.background(
									RoundedRectangle(cornerRadius: CGFloat(KKRadiusSM))
										.fill(
											Color(nsColor: .hover()).opacity(
												hoveredClipIndex == row.clipIndex ? 1 : 0
											))
								)
								.onHover { hovering in
									hoveredClipIndex = hovering ? row.clipIndex : nil
								}
							}
						}
					}
					.padding(KKPaddingMD)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
		.onAppear {
			if model.editSelectedClips == nil {
				model.editSelectedClips = transcribedIndices
			}
			buildRows()
		}
	}

	private var timelineDuration: Double {
		model.projectFormat?.sequenceDuration ?? model.audioClips.map(\.end).max() ?? 0
	}

	private var untranscribedIndices: Set<Int> {
		Set(model.audioClips.indices).subtracting(transcribedIndices)
	}

	private var transcribedIndices: Set<Int> {
		let store = TranscriptionStore.shared
		var result = Set<Int>()
		for i in model.audioClips.indices {
			if store.words(for: model.audioClips[i]) != nil {
				result.insert(i)
			}
		}
		return result
	}

	private func buildRows() {
		let store = TranscriptionStore.shared
		var result: [Row] = []
		var nextID = 0

		for idx in model.audioClips.indices {
			let clip = model.audioClips[idx]
			let words = store.words(for: clip)
			let hasTranscription = words != nil

			result.append(
				Row(
					id: nextID, clipIndex: idx, clipName: clip.name, text: "", timestamp: "",
					isHeader: true, isTranscribed: hasTranscription))
			nextID += 1

			if let words {
				let sentences = groupIntoSentences(words)
				for sentence in sentences {
					let text = sentence.map { $0.word.trimmingCharacters(in: .whitespaces) }
						.joined(separator: " ")
					result.append(
						Row(
							id: nextID,
							clipIndex: idx,
							clipName: clip.name,
							text: text,
							timestamp: formatTimestamp(sentence.first!.start),
							isHeader: false,
							isTranscribed: true,
							sentenceStart: Double(sentence.first!.start),
							sentenceEnd: Double(sentence.last!.end)
						))
					nextID += 1
				}
			}
		}
		rows = result
	}

	private static let sentenceEndChars = CharacterSet(charactersIn: ".!?")
	private static let pauseThreshold: Float = 0.7
	private static let maxSentenceDuration: Float = 5.0

	private func groupIntoSentences(
		_ words: [TranscriptionStore.StoredWord]
	) -> [[TranscriptionStore.StoredWord]] {
		guard !words.isEmpty else { return [] }

		var sentences: [[TranscriptionStore.StoredWord]] = []
		var current: [TranscriptionStore.StoredWord] = []

		for word in words {
			if let prev = current.last,
				word.start - prev.end > Self.pauseThreshold
			{
				sentences.append(current)
				current = []
			}

			if let first = current.first,
				word.end - first.start > Self.maxSentenceDuration
			{
				sentences.append(current)
				current = []
			}

			current.append(word)

			let trimmed = word.word.trimmingCharacters(in: .whitespaces)
			if trimmed.unicodeScalars.last.map({ Self.sentenceEndChars.contains($0) }) == true {
				sentences.append(current)
				current = []
			}
		}

		if !current.isEmpty {
			sentences.append(current)
		}

		return sentences
	}

	private func formatTimestamp(_ time: Float) -> String {
		if let format = model.projectFormat {
			return format.timecode(for: Double(time))
		}
		let s = Int(time) % 60
		let m = Int(time) / 60
		let ms = Int((time - Float(Int(time))) * 100)
		return String(format: "%d:%02d.%02d", m, s, ms)
	}
}
