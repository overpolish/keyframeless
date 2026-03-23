/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Combine
import Darwin
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

	static var recommendedModelId: String {
		var size = 0
		let isAppleSilicon = sysctlbyname("hw.optional.arm64", nil, &size, nil, 0) == 0
		let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1_073_741_824))
		if isAppleSilicon {
			if ramGB >= 16 { return "openai_whisper-large-v3" }
			if ramGB >= 8 { return "openai_whisper-small" }
		}
		return "openai_whisper-base"
	}

	static let models: [ModelInfo] = [
		ModelInfo(
			id: "openai_whisper-tiny", displayName: "Tiny", sizeDescription: "~390 MB",
			hint: "Fastest, best for rough drafts"),
		ModelInfo(
			id: "openai_whisper-base", displayName: "Base", sizeDescription: "~670 MB",
			hint: "Good speed and accuracy"),
		ModelInfo(
			id: "openai_whisper-small", displayName: "Small", sizeDescription: "~1.4 GB",
			hint: "Handles accents and noise"),
		ModelInfo(
			id: "openai_whisper-large-v3", displayName: "Large v3", sizeDescription: "~6 GB",
			hint: "Best accuracy, final exports"),
	]

	@Published var downloadedModels: Set<String> = []
	@Published var downloadingModel: String? = nil
	@Published var downloadProgress: Double = 0
	@Published var selectedModel: String? {
		didSet {
			AudioSetupSettings.shared.selectedModel = selectedModel
			AudioSetupSettings.shared.save()
		}
	}

	@Published var selectedLanguage: String? {
		didSet {
			AudioSetupSettings.shared.selectedLanguage = selectedLanguage
			AudioSetupSettings.shared.save()
			if selectedLanguage == "en" { translateToEnglish = false }
		}
	}

	@Published var translateToEnglish: Bool = false {
		didSet {
			AudioSetupSettings.shared.translateToEnglish = translateToEnglish
			AudioSetupSettings.shared.save()
		}
	}

	@Published var hotWords: [String] = [] {
		didSet {
			AudioSetupSettings.shared.hotWords = hotWords
			AudioSetupSettings.shared.save()
		}
	}

	init() {
		selectedModel = AudioSetupSettings.shared.selectedModel
		selectedLanguage = AudioSetupSettings.shared.selectedLanguage
		translateToEnglish = AudioSetupSettings.shared.translateToEnglish
		hotWords = AudioSetupSettings.shared.hotWords
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
