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

	private let transcriber = AudioTranscriber()
	private var processingTask: Task<Void, Never>?

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

		let segments = AudioPreparer.prepare(clips: clips, selectedIndices: selected)

		processingTask?.cancel()
		processingTask = Task { [weak self] in
			guard let self else { return }
			do {
				let prepared = try AudioPreparer.extractAudio(for: segments)
				let results = try await self.transcriber.transcribe(
					segments: prepared,
					modelVariant: modelVariant,
					language: language,
					translateToEnglish: translateToEnglish,
					hotWords: hotWords,
					onProgress: { progress in
						Task { @MainActor [weak self] in
							self?.statusLabel = progress.phase.rawValue
							self?.progress =
								progress.phase == .transcribing ? progress.fraction : nil
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

	func cancel() {
		processingTask?.cancel()
		processingTask = nil
		withAnimation(.easeOut(duration: 0.25)) {
			isProcessing = false
		}
	}
}
