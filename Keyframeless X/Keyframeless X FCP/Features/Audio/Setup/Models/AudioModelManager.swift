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
class AudioModelManager: ObservableObject {

	enum Engine {
		case whisperKit
		case whisperCpp
		case parakeet
	}

	struct ModelInfo: Identifiable {
		let id: String
		let displayName: String
		/// Download size on disk (what actually comes over the wire).
		let sizeDescription: String
		/// Minimum system RAM to run comfortably, mirroring Kai's RAM badge.
		let minRAMGB: Int
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
			minRAMGB: 8,
			hint: String(localized: "Fastest, best for rough drafts"), engine: .whisperKit),
		ModelInfo(
			id: "openai_whisper-base", displayName: "Base", sizeDescription: "~670 MB",
			minRAMGB: 8,
			hint: String(localized: "Good speed and accuracy"), engine: .whisperKit),
		ModelInfo(
			id: "openai_whisper-small", displayName: "Small", sizeDescription: "~1.4 GB",
			minRAMGB: 8,
			hint: String(localized: "Handles accents and noise"), engine: .whisperKit),
		ModelInfo(
			id: "openai_whisper-large-v3_turbo", displayName: "Large v3 Turbo",
			sizeDescription: "~1.6 GB",
			minRAMGB: 16,
			hint: String(localized: "Near-large accuracy at speed"), engine: .whisperKit),
		ModelInfo(
			id: "openai_whisper-large-v3", displayName: "Large v3", sizeDescription: "~6 GB",
			minRAMGB: 16,
			hint: String(localized: "Best accuracy, final exports"), engine: .whisperKit),
		// Parakeet download sizes are the CoreML repo totals (HF API): the
		// "0.6b" in the name is parameter count, NOT megabytes.
		ModelInfo(
			id: "parakeet-tdt-0.6b-v2", displayName: "Parakeet 0.6B v2",
			sizeDescription: "~2.6 GB",
			minRAMGB: 8,
			hint: String(localized: "English only, fastest"), engine: .parakeet),
		ModelInfo(
			id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet 0.6B v3",
			sizeDescription: "~3 GB",
			minRAMGB: 8,
			hint: String(localized: "25 European languages, fast"), engine: .parakeet),
	]

	private nonisolated static let intelModels: [ModelInfo] = [
		ModelInfo(
			id: "ggml-tiny-q5_1", displayName: "Tiny", sizeDescription: "~200 MB",
			minRAMGB: 8,
			hint: String(localized: "Fastest, best for rough drafts"), engine: .whisperCpp),
		ModelInfo(
			id: "ggml-base-q5_1", displayName: "Base", sizeDescription: "~300 MB",
			minRAMGB: 8,
			hint: String(localized: "Good speed and accuracy"), engine: .whisperCpp),
		ModelInfo(
			id: "ggml-small-q5_1", displayName: "Small", sizeDescription: "~600 MB",
			minRAMGB: 8,
			hint: String(localized: "Best accuracy for Intel"), engine: .whisperCpp),
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
	@Published var hasCtcModel: Bool = false
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
		normalizeLanguageForSelectedModel()
		Task { await refreshDownloadedModels() }
	}

	func refreshDownloadedModels() async {
		for model in Self.models where isDownloaded(model.id) {
			downloadedModels.insert(model.id)
		}
		hasCtcModel = Self.ctcModelExists()
		let validModelIds = Set(Self.models.map(\.id))
		if let current = selectedModel,
			!validModelIds.contains(current) || !downloadedModels.contains(current)
		{
			selectedModel = Self.models.first(where: { downloadedModels.contains($0.id) })?.id
		} else if selectedModel == nil {
			selectedModel = Self.models.first(where: { downloadedModels.contains($0.id) })?.id
		}
	}

	private var hasAnyParakeetInstalled: Bool {
		downloadedModels.contains(where: { Self.engine(for: $0) == .parakeet })
	}

	nonisolated static func ctcModelExists() -> Bool {
		let dir = CtcModels.defaultCacheDirectory(for: .ctc110m)
		// CtcModels has no public modelsExist helper; check the cache directory for files.
		guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
			return false
		}
		return !contents.isEmpty
	}

	func retryDownloadCtcEngine(triggeredBy variant: String) async {
		guard downloadingModel == nil else { return }
		downloadingModel = variant
		downloadProgress = 0
		await downloadCtcEngineIfNeeded()
		downloadingModel = nil
	}

	private func downloadCtcEngineIfNeeded() async {
		if Self.ctcModelExists() {
			hasCtcModel = true
			return
		}
		do {
			_ = try await CtcModels.download(variant: .ctc110m)
			hasCtcModel = Self.ctcModelExists()
		} catch {
			print("[AudioModelManager] CTC engine download failed: \(error)")
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

	// Silicon - WhisperKit

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
			print("[AudioModelManager] WhisperKit download failed: \(error)")
		}
	}

	private func uninstallWhisperKit(_ variant: String) {
		let modelPath = Self.whisperKitModelDirectory(for: variant)
		try? FileManager.default.removeItem(at: modelPath)
	}

	// Parakeet - FluidAudio

	private func downloadParakeet(_ variant: String) async {
		guard let version = Self.parakeetVersion(for: variant) else { return }
		// FluidAudio's progressHandler activates its delegate-session download
		// path, whose empty didFinishDownloadingTo swallows the async
		// download(for:) completion - the await never resumes and the download
		// hangs. So transport runs WITHOUT a handler (plain shared session) and
		// progress is derived by polling bytes on disk against the known repo
		// size: completed files land in the cache dir, the in-flight file is
		// URLSession's CFNetworkDownload_*.tmp.
		let expected = Self.parakeetExpectedBytes(for: version)
		let cacheDir = AsrModels.defaultCacheDirectory(for: version)
		let poller = Task.detached { [weak self] in
			while !Task.isCancelled {
				let bytes =
					Self.directoryBytes(at: cacheDir) + Self.inflightDownloadBytes()
				await MainActor.run { [weak self] in
					self?.downloadProgress = min(
						Double(bytes) / Double(expected), 0.99)
				}
				try? await Task.sleep(nanoseconds: 500_000_000)
			}
		}
		defer { poller.cancel() }
		do {
			_ = try await AsrModels.download(version: version)
			downloadProgress = 1
			downloadedModels.insert(variant)
			if selectedModel == nil { selectedModel = variant }
		} catch {
			print("[AudioModelManager] Parakeet download failed: \(error)")
			return
		}
		await downloadCtcEngineIfNeeded()
	}

	/// Repo totals from the HuggingFace API (July 2026). Only scale the
	/// progress bar; the poll clamps at 99% until the download returns.
	private nonisolated static func parakeetExpectedBytes(
		for version: AsrModelVersion
	) -> Int64 {
		switch version {
		case .v2: return 2_575_000_000
		case .v3: return 2_991_000_000
		default: return 2_800_000_000
		}
	}

	private nonisolated static func directoryBytes(at url: URL) -> Int64 {
		guard
			let enumerator = FileManager.default.enumerator(
				at: url, includingPropertiesForKeys: [.fileSizeKey])
		else { return 0 }
		var total: Int64 = 0
		for case let file as URL in enumerator {
			total += Int64(
				(try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
		}
		return total
	}

	private nonisolated static func inflightDownloadBytes() -> Int64 {
		let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
		guard
			let items = try? FileManager.default.contentsOfDirectory(
				at: tmp, includingPropertiesForKeys: [.fileSizeKey])
		else { return 0 }
		return
			items
			.filter { $0.lastPathComponent.hasPrefix("CFNetworkDownload") }
			.compactMap {
				(try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
			}
			.map(Int64.init)
			.reduce(0, +)
	}

	private func uninstallParakeet(_ variant: String) {
		guard let version = Self.parakeetVersion(for: variant) else { return }
		let dir = AsrModels.defaultCacheDirectory(for: version)
		try? FileManager.default.removeItem(at: dir)
		downloadedModels.remove(variant)
		if !hasAnyParakeetInstalled {
			let ctcDir = CtcModels.defaultCacheDirectory(for: .ctc110m)
			try? FileManager.default.removeItem(at: ctcDir)
			hasCtcModel = false
		}
	}

	// Intel - whisper.cpp (GGML)

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
			print("[AudioModelManager] GGML download failed: \(error)")
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
