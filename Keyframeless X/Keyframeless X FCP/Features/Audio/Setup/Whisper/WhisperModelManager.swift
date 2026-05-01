/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Darwin
import FluidAudio
import Foundation
import WhisperKit

@MainActor
class WhisperModelManager: ObservableObject {

	enum Engine {
		case whisperKit
		case whisperCpp
		case parakeet
	}

	struct ModelInfo: Identifiable {
		let id: String
		let displayName: String
		let sizeDescription: String
		let hint: String
		let engine: Engine
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
			hint: "Fastest, best for rough drafts", engine: .whisperKit),
		ModelInfo(
			id: "openai_whisper-base", displayName: "Base", sizeDescription: "~670 MB",
			hint: "Good speed and accuracy", engine: .whisperKit),
		ModelInfo(
			id: "openai_whisper-small", displayName: "Small", sizeDescription: "~1.4 GB",
			hint: "Handles accents and noise", engine: .whisperKit),
		ModelInfo(
			id: "openai_whisper-large-v3_turbo", displayName: "Large v3 Turbo",
			sizeDescription: "~1.6 GB",
			hint: "Near-large accuracy at speed", engine: .whisperKit),
		ModelInfo(
			id: "openai_whisper-large-v3", displayName: "Large v3", sizeDescription: "~6 GB",
			hint: "Best accuracy, final exports", engine: .whisperKit),
		ModelInfo(
			id: "parakeet-tdt-0.6b-v2", displayName: "Parakeet 0.6B v2",
			sizeDescription: "~600 MB",
			hint: "English only, fastest", engine: .parakeet),
		ModelInfo(
			id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet 0.6B v3",
			sizeDescription: "~600 MB",
			hint: "25 European languages, fast", engine: .parakeet),
	]

	private nonisolated static let intelModels: [ModelInfo] = [
		ModelInfo(
			id: "ggml-tiny-q5_1", displayName: "Tiny", sizeDescription: "~200 MB",
			hint: "Fastest, best for rough drafts", engine: .whisperCpp),
		ModelInfo(
			id: "ggml-base-q5_1", displayName: "Base", sizeDescription: "~300 MB",
			hint: "Good speed and accuracy", engine: .whisperCpp),
		ModelInfo(
			id: "ggml-small-q5_1", displayName: "Small", sizeDescription: "~600 MB",
			hint: "Best accuracy for Intel", engine: .whisperCpp),
	]

	nonisolated static func engine(for variantId: String) -> Engine? {
		models.first(where: { $0.id == variantId })?.engine
	}

	nonisolated static func parakeetVersion(for variantId: String) -> AsrModelVersion? {
		switch variantId {
		case "parakeet-tdt-0.6b-v2": return .v2
		case "parakeet-tdt-0.6b-v3": return .v3
		default: return nil
		}
	}

	nonisolated static let parakeetV3Languages: Set<String> = [
		"bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
		"el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk",
		"sl", "es", "sv", "ru", "uk",
	]

	var currentEngine: Engine? {
		guard let id = selectedModel else { return nil }
		return Self.engine(for: id)
	}

	var currentParakeetVersion: AsrModelVersion? {
		guard let id = selectedModel else { return nil }
		return Self.parakeetVersion(for: id)
	}

	static func parakeetSupports(language code: String?, version: AsrModelVersion) -> Bool {
		switch version {
		case .v2: return code == "en"
		case .v3: return code.map { parakeetV3Languages.contains($0) } ?? false
		default: return false
		}
	}

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
			normalizeLanguageForSelectedModel()
		}
	}

	private func normalizeLanguageForSelectedModel() {
		guard let version = currentParakeetVersion else { return }
		if !Self.parakeetSupports(language: selectedLanguage, version: version) {
			selectedLanguage = "en"
		}
		if translateToEnglish { translateToEnglish = false }
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

		switch Self.engine(for: variant) {
		case .whisperKit:
			await downloadWhisperKit(variant)
		case .whisperCpp:
			await downloadGGML(variant)
		case .parakeet:
			await downloadParakeet(variant)
		case nil:
			break
		}

		downloadingModel = nil
	}

	func uninstall(_ variant: String) {
		switch Self.engine(for: variant) {
		case .whisperKit:
			uninstallWhisperKit(variant)
		case .whisperCpp:
			uninstallGGML(variant)
		case .parakeet:
			uninstallParakeet(variant)
		case nil:
			break
		}
		downloadedModels.remove(variant)
		if selectedModel == variant {
			selectedModel = Self.models.first(where: { downloadedModels.contains($0.id) })?.id
		}
	}

	nonisolated static func modelFileURL(for variant: String) -> URL {
		switch engine(for: variant) {
		case .whisperKit:
			return whisperKitModelDirectory(for: variant)
		case .parakeet:
			let version = parakeetVersion(for: variant) ?? .v3
			return AsrModels.defaultCacheDirectory(for: version)
		case .whisperCpp, nil:
			return ggmlModelsDirectory.appendingPathComponent("\(variant).bin")
		}
	}

	private func isDownloaded(_ variant: String) -> Bool {
		switch Self.engine(for: variant) {
		case .parakeet:
			guard let version = Self.parakeetVersion(for: variant) else { return false }
			let dir = AsrModels.defaultCacheDirectory(for: version)
			return AsrModels.modelsExist(at: dir, version: version)
		case .whisperKit, .whisperCpp, nil:
			let path = Self.modelFileURL(for: variant).path
			return FileManager.default.fileExists(atPath: path)
		}
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

	// Parakeet — FluidAudio

	private func downloadParakeet(_ variant: String) async {
		guard let version = Self.parakeetVersion(for: variant) else { return }
		do {
			_ = try await AsrModels.download(version: version)
			downloadedModels.insert(variant)
			if selectedModel == nil { selectedModel = variant }
		} catch {
			print("[WhisperModelManager] Parakeet download failed: \(error)")
		}
	}

	private func uninstallParakeet(_ variant: String) {
		guard let version = Self.parakeetVersion(for: variant) else { return }
		let dir = AsrModels.defaultCacheDirectory(for: version)
		try? FileManager.default.removeItem(at: dir)
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
			if old.hasPrefix("parakeet-") { return old }
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
