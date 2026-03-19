/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Combine
import Foundation
import WhisperKit

@MainActor
class WhisperModelManager: ObservableObject {

	struct ModelInfo: Identifiable {
		let id: String  // variant name
		let displayName: String
		let sizeDescription: String
		let hint: String
	}

	static let models: [ModelInfo] = [
		ModelInfo(
			id: "openai_whisper-tiny", displayName: "Tiny", sizeDescription: "~390 MB",
			hint: "Fastest, good for rough drafts or quick checks"),
		ModelInfo(
			id: "openai_whisper-base", displayName: "Base", sizeDescription: "~670 MB",
			hint: "Balance of speed and accuracy for clear audio"),
		ModelInfo(
			id: "openai_whisper-small", displayName: "Small", sizeDescription: "~1.4 GB",
			hint: "Handles accents and noisy audio well"),
		ModelInfo(
			id: "openai_whisper-large-v3", displayName: "Large v3", sizeDescription: "~6 GB",
			hint: "Best accuracy, recommended for final exports"),
	]

	@Published var downloadedModels: Set<String> = []
	@Published var downloadingModel: String? = nil
	@Published var downloadProgress: Double = 0
	@Published var selectedModel: String? {
		didSet {
			TranscriptionSettings.shared.selectedModel = selectedModel
			TranscriptionSettings.shared.save()
		}
	}

	init() {
		selectedModel = TranscriptionSettings.shared.selectedModel
		Task { await refreshDownloadedModels() }
	}

	func refreshDownloadedModels() async {
		for model in Self.models where isDownloaded(model.id) {
			downloadedModels.insert(model.id)
		}
		if selectedModel == nil {
			selectedModel = Self.models.first(where: { downloadedModels.contains($0.id) })?.id
		}
	}

	func download(_ variant: String) async {
		downloadingModel = variant
		downloadProgress = 0
		do {
			_ = try await WhisperKit.download(
				variant: variant,
				progressCallback: { [weak self] progress in
					Task { @MainActor [weak self] in
						self?.downloadProgress = progress.fractionCompleted
					}
				})
			downloadedModels.insert(variant)
			if selectedModel == nil { selectedModel = variant }
		} catch {
			// download failed — user can retry
		}
		downloadingModel = nil
	}

	func uninstall(_ variant: String) {
		guard
			let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
		else { return }
		let modelPath =
			docs
			.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
			.appendingPathComponent(variant)
		try? FileManager.default.removeItem(at: modelPath)
		downloadedModels.remove(variant)
		if selectedModel == variant {
			selectedModel = Self.models.first(where: { downloadedModels.contains($0.id) })?.id
		}
	}

	private func isDownloaded(_ variant: String) -> Bool {
		guard
			let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
		else { return false }
		let modelPath =
			docs
			.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
			.appendingPathComponent(variant)
		return FileManager.default.fileExists(atPath: modelPath.path)
	}

}
