/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Combine
import KeyframelessKit
import SwiftUI

@MainActor
class AudioProcessingCoordinator: ObservableObject {
	@Published var isProcessing = false
	@Published var statusLabel = ""
	@Published var progress: Double?
	@Published var estimatedTimeRemaining: String?

	private let transcriber = AudioTranscriber()
	private var processingTask: Task<Void, Never>?
	private var transcriptionStartTime: Date?

	func process(
		model: AudioModel,
		whisperManager: WhisperModelManager,
		replaceAll: Bool
	) {
		guard let modelVariant = whisperManager.selectedModel else { return }
		let clips = model.audioClips
		let selected = model.selectedClips
		let language = whisperManager.selectedLanguage
		let translateToEnglish = whisperManager.translateToEnglish
		let hotWords = whisperManager.hotWords

		guard !selected.isEmpty else {
			withAnimation(.easeOut(duration: 0.25)) {
				isProcessing = false
			}
			return
		}

		let previouslyTranscribed = transcribedIndices(for: clips)

		if replaceAll {
			TranscriptionStore.shared.removeAll()
		}

		statusLabel = AudioTranscriber.Phase.preparingAudio.rawValue
		progress = nil
		estimatedTimeRemaining = nil
		transcriptionStartTime = nil

		let segments = AudioPreparer.prepare(clips: clips, selectedIndices: selected)

		processingTask?.cancel()
		processingTask = Task { [weak self] in
			guard let self else { return }
			do {
				let prepared = try await AudioPreparer.extractAudio(for: segments)
				let results = try await self.transcriber.transcribe(
					segments: prepared,
					modelVariant: modelVariant,
					language: language,
					translateToEnglish: translateToEnglish,
					hotWords: hotWords,
					onProgress: { progress in
						Task { @MainActor [weak self] in
							guard let self else { return }
							self.statusLabel = progress.phase.rawValue
							if progress.phase == .transcribing, progress.segmentProgress > 0 {
								let frac = progress.fraction
								self.progress = frac
								if self.transcriptionStartTime == nil {
									self.transcriptionStartTime = Date()
								}
								self.estimatedTimeRemaining = self.formatETA(fraction: frac)
							} else if progress.phase != .transcribing {
								self.progress = nil
								self.estimatedTimeRemaining = nil
							}
						}
					}
				)
				TranscriptionStore.shared.store(results: results, clips: clips)
				AudioPreparer.cleanUp(segments: prepared)
				let newlyTranscribed = selected.subtracting(previouslyTranscribed)
				if !newlyTranscribed.isEmpty, model.editSelectedClips != nil {
					model.editSelectedClips = model.editSelectedClips?.union(newlyTranscribed)
				}
				withAnimation(.easeOut(duration: 0.25)) {
					self.isProcessing = false
					model.stage = .edit
				}
			} catch is CancellationError {
				print("[AudioProcessing] cancelled")
			} catch {
				print("[AudioProcessing] error: \(error)")
				withAnimation(.easeOut(duration: 0.25)) {
					self.isProcessing = false
				}
			}
		}
	}

	private func transcribedIndices(for clips: [FCPXMLParser.AudioClip]) -> Set<Int> {
		let store = TranscriptionStore.shared
		var result = Set<Int>()
		for i in clips.indices where store.words(for: clips[i]) != nil {
			result.insert(i)
		}
		return result
	}

	private func formatETA(fraction: Double) -> String? {
		guard fraction > 0.05,
			let start = transcriptionStartTime
		else { return nil }
		let elapsed = Date().timeIntervalSince(start)
		let total = elapsed / fraction
		let remaining = total - elapsed
		let seconds = Int(remaining)
		if seconds < 5 { return "Almost done" }
		if seconds < 60 { return "About \(seconds)s remaining" }
		let minutes = seconds / 60
		if minutes == 1 { return "About 1 min remaining" }
		return "About \(minutes) min remaining"
	}

	func cancel() {
		processingTask?.cancel()
		processingTask = nil
		withAnimation(.easeOut(duration: 0.25)) {
			isProcessing = false
		}
	}
}
