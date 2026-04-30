/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Darwin
import Foundation
import WhisperKit

@MainActor
class WhisperModelManager: ObservableObject {

	struct ModelInfo: Identifiable {
		let id: String
		let displayName: String
		let sizeDescription: String
		let hint: String
	}

	nonisolated static let simulateIntel = false

	nonisolated static let isAppleSilicon: Bool = {
		if simulateIntel { return false }
		var size = 0
		return sysctlbyname("hw.optional.arm64", nil, &size, nil, 0) == 0
	}()

	private nonisolated static let siliconModels: [ModelInfo] = [
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

	private nonisolated static let intelModels: [ModelInfo] = [
		ModelInfo(
			id: "ggml-tiny-q5_1", displayName: "Tiny", sizeDescription: "~200 MB",
			hint: "Fastest, best for rough drafts"),
		ModelInfo(
			id: "ggml-base-q5_1", displayName: "Base", sizeDescription: "~300 MB",
			hint: "Good speed and accuracy"),
		ModelInfo(
			id: "ggml-small-q5_1", displayName: "Small", sizeDescription: "~600 MB",
			hint: "Best accuracy for Intel"),
	]

	nonisolated static let models: [ModelInfo] = isAppleSilicon ? siliconModels : intelModels

	static var recommendedModelId: String {
		if isAppleSilicon {
			let ramGB = Int(ProcessInfo.processInfo.physicalMemory / (1_073_741_824))
			if ramGB >= 16 { return "openai_whisper-large-v3" }
			if ramGB >= 8 { return "openai_whisper-small" }
			return "openai_whisper-base"
		}
		return "ggml-base-q5_1"
	}

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

	@Published var terms: [String] = [] {
		didSet {
			AudioSetupSettings.shared.terms = terms
			AudioSetupSettings.shared.save()
		}
	}

	init() {
		var model = AudioSetupSettings.shared.selectedModel
		if let m = model { model = Self.migrateModelId(m) }
		selectedModel = model
		selectedLanguage = AudioSetupSettings.shared.selectedLanguage
		translateToEnglish = AudioSetupSettings.shared.translateToEnglish
		terms = AudioSetupSettings.shared.terms
		Task { await refreshDownloadedModels() }
	}

	func refreshDownloadedModels() async {
		for model in Self.models where isDownloaded(model.id) {
			downloadedModels.insert(model.id)
		}
		let validModelIds = Set(Self.models.map(\.id))
		if let current = selectedModel,
			!validModelIds.contains(current) || !downloadedModels.contains(current)
		{
			selectedModel = Self.models.first(where: { downloadedModels.contains($0.id) })?.id
		} else if selectedModel == nil {
			selectedModel = Self.models.first(where: { downloadedModels.contains($0.id) })?.id
		}
	}

	func download(_ variant: String) async {
		downloadingModel = variant
		downloadProgress = 0

		if Self.isAppleSilicon {
			await downloadWhisperKit(variant)
		} else {
			await downloadGGML(variant)
		}

		downloadingModel = nil
	}

	func uninstall(_ variant: String) {
		if Self.isAppleSilicon {
			uninstallWhisperKit(variant)
		} else {
			uninstallGGML(variant)
		}
		downloadedModels.remove(variant)
		if selectedModel == variant {
			selectedModel = Self.models.first(where: { downloadedModels.contains($0.id) })?.id
		}
	}

	nonisolated static func modelFileURL(for variant: String) -> URL {
		if isAppleSilicon {
			return whisperKitModelDirectory(for: variant)
		} else {
			return ggmlModelsDirectory.appendingPathComponent("\(variant).bin")
		}
	}

	private func isDownloaded(_ variant: String) -> Bool {
		let path = Self.modelFileURL(for: variant).path
		return FileManager.default.fileExists(atPath: path)
	}

	// Silicon — WhisperKit

	private nonisolated static func whisperKitModelDirectory(for variant: String) -> URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
			.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
			.appendingPathComponent(variant)
	}

	private func downloadWhisperKit(_ variant: String) async {
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
			print("[WhisperModelManager] WhisperKit download failed: \(error)")
		}
	}

	private func uninstallWhisperKit(_ variant: String) {
		let modelPath = Self.whisperKitModelDirectory(for: variant)
		try? FileManager.default.removeItem(at: modelPath)
	}

	// Intel — whisper.cpp (GGML)

	private nonisolated static var ggmlModelsDirectory: URL {
		FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
			.appendingPathComponent("whisper-models")
	}

	private func downloadGGML(_ variant: String) async {
		let filename = "\(variant).bin"
		let url = URL(
			string:
				"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
		let destination = Self.ggmlModelsDirectory.appendingPathComponent(filename)

		do {
			let modelsDir = Self.ggmlModelsDirectory
			try FileManager.default.createDirectory(
				at: modelsDir, withIntermediateDirectories: true)

			let delegate = DownloadDelegate(
				onProgress: { [weak self] fraction in
					Task { @MainActor [weak self] in
						self?.downloadProgress = fraction
					}
				},
				destination: destination
			)
			let session = URLSession(
				configuration: .default, delegate: delegate, delegateQueue: nil)
			let task = session.downloadTask(with: url)
			task.resume()
			try await delegate.waitForCompletion()

			downloadedModels.insert(variant)
			if selectedModel == nil { selectedModel = variant }
		} catch {
			print("[WhisperModelManager] GGML download failed: \(error)")
		}
	}

	private func uninstallGGML(_ variant: String) {
		let modelFile = Self.ggmlModelsDirectory.appendingPathComponent("\(variant).bin")
		try? FileManager.default.removeItem(at: modelFile)
	}

	// Migration

	private static let modelIdMigration: [String: String] = [
		"tiny-q5_1": "ggml-tiny-q5_1",
		"base-q5_1": "ggml-base-q5_1",
		"small-q5_1": "ggml-small-q5_1",
		"large-v3-turbo-q5_0": "ggml-small-q5_1",
		"large-v3-q5_0": "ggml-small-q5_1",
	]

	private static func migrateModelId(_ old: String) -> String {
		if isAppleSilicon {
			if old.hasPrefix("openai_whisper-") { return old }
			if old.hasPrefix("ggml-") { return "openai_whisper-base" }
			return "openai_whisper-base"
		} else {
			if old.hasPrefix("ggml-") { return old }
			return modelIdMigration[old] ?? "ggml-base-q5_1"
		}
	}
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
	let onProgress: (Double) -> Void
	let destination: URL
	private var continuation: CheckedContinuation<Void, Error>?

	init(onProgress: @escaping (Double) -> Void, destination: URL) {
		self.onProgress = onProgress
		self.destination = destination
	}

	func waitForCompletion() async throws {
		try await withCheckedThrowingContinuation { self.continuation = $0 }
	}

	func urlSession(
		_ session: URLSession, downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		guard totalBytesExpectedToWrite > 0 else { return }
		onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
	}

	func urlSession(
		_ session: URLSession, downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		do {
			if FileManager.default.fileExists(atPath: destination.path) {
				try FileManager.default.removeItem(at: destination)
			}
			try FileManager.default.moveItem(at: location, to: destination)
		} catch {
			continuation?.resume(throwing: error)
			continuation = nil
		}
	}

	func urlSession(
		_ session: URLSession, task: URLSessionTask,
		didCompleteWithError error: Error?
	) {
		if let error {
			continuation?.resume(throwing: error)
		} else {
			continuation?.resume()
		}
		continuation = nil
	}
}
