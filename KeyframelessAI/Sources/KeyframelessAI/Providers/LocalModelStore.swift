/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers
import os

/// Download progress diagnostics; view in Console.app, subsystem
/// `com.overpolish.keyframeless`, category `ai.local`.
private let storeLog = Logger(subsystem: "com.overpolish.keyframeless", category: "ai.local")

/// Tracks which local models are downloaded + which is selected. With MLX, the
/// model is a HuggingFace repo that MLX/Hub downloads and caches on demand, so
/// "download" just pre-fetches it and we record the installed set in
/// UserDefaults (the Hub owns the bytes on disk).
@MainActor
public final class LocalModelStore: ObservableObject {
	public static let shared = LocalModelStore()

	@Published public private(set) var downloadedModels: Set<String> = []
	@Published public private(set) var downloadingModel: String? = nil
	@Published public private(set) var downloadProgress: Double = 0
	/// Last download/load error, surfaced in the UI. Temporary diagnostic until
	/// local is confirmed working end to end.
	@Published public private(set) var lastError: String? = nil
	@Published public var selectedModelID: String? {
		didSet {
			UserDefaults.standard.set(selectedModelID, forKey: Self.selectedKey)
			// Deferred so it never runs synchronously during init (which would
			// re-enter AIKeyState.shared while it is still being constructed).
			Task { @MainActor in AIKeyState.shared.refresh() }
		}
	}

	/// The local provider counts as "configured" once a model is downloaded and
	/// selected - the equivalent of having a saved API key.
	public var hasReadyModel: Bool {
		guard let id = selectedModelID else { return false }
		return downloadedModels.contains(id)
	}

	/// Total bytes for the active download, learned from the Hub progress handler;
	/// the on-disk poll divides by this to compute the real fraction.
	private var downloadTotalBytes: Int64 = 0

	private static let selectedKey = "com.overpolish.ai.local.selectedModel"
	private static let downloadedKey = "com.overpolish.ai.local.downloadedModels"

	private init() {
		let saved = Set(UserDefaults.standard.stringArray(forKey: Self.downloadedKey) ?? [])
		// Only trust entries still in the catalog.
		let valid = Set(LocalModelCatalog.models.map(\.id))
		downloadedModels = saved.intersection(valid)
		selectedModelID = UserDefaults.standard.string(forKey: Self.selectedKey)
		if let current = selectedModelID, !downloadedModels.contains(current) {
			selectedModelID = downloadedModels.first
		} else if selectedModelID == nil {
			selectedModelID = downloadedModels.first
		}
	}

	public func refreshDownloaded() {
		// Source of truth is our persisted set; MLX/Hub owns the actual cache.
		let valid = Set(LocalModelCatalog.models.map(\.id))
		downloadedModels = downloadedModels.intersection(valid)
	}

	/// Pre-fetch (and cache) the model files via HuggingFace Hub. We download the
	/// snapshot directly rather than going through `loadModelContainer` - the
	/// latter loads the whole model (up to ~16 GB) into memory just to discard
	/// it, which is wasteful and reports no progress during the load phase. The
	/// bytes land in the Hub cache, so the runner's later load is a cache hit.
	public func download(_ id: String) async {
		guard downloadingModel == nil, let model = LocalModelCatalog.model(id: id) else { return }
		guard let repo = Repo.ID(rawValue: model.repoID) else {
			lastError = "\(model.repoID): invalid repository id"
			return
		}
		downloadingModel = id
		downloadProgress = 0
		downloadTotalBytes = 0
		lastError = nil

		// swift-huggingface only bumps its Progress counter when each large shard
		// FINISHES (bytes stream to CFNetworkDownload_*.tmp meanwhile), so its bar
		// sits at the metadata size then jumps. Poll real bytes on disk instead:
		// completed shards live in the repo's blobs/, in-flight ones in the temp
		// dir. The HuggingFace Progress handler is used only to learn the total.
		let blobsDir = Self.repoCacheDir(model.repoID).appendingPathComponent("blobs")
		let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
		// Ignore CFNetworkDownload temp files left over from earlier (interrupted)
		// downloads - counting those orphans pinned the bar at 99%. Only new temp
		// files created for THIS download count toward in-flight bytes.
		let baselineTemps = Self.tempDownloadNames(tmpDir)
		let poll = Task.detached { [weak self] in
			while !Task.isCancelled {
				let bytes =
					Self.directorySize(blobsDir)
					+ Self.tempDownloadSize(tmpDir, excluding: baselineTemps)
				await MainActor.run { [weak self] in
					guard let self, self.downloadTotalBytes > 0 else { return }
					self.downloadProgress = min(
						0.99, Double(bytes) / Double(self.downloadTotalBytes))
				}
				try? await Task.sleep(for: .milliseconds(750))
			}
		}

		do {
			let hub = HubClient()
			_ = try await hub.downloadSnapshot(of: repo) { @MainActor [weak self] progress in
				self?.downloadTotalBytes = progress.totalUnitCount
			}
			poll.cancel()
			downloadProgress = 1.0
			downloadedModels.insert(id)
			persistDownloaded()
			lastError = nil
			if selectedModelID == nil { selectedModelID = id }
		} catch {
			poll.cancel()
			lastError = "\(model.repoID): \(error.localizedDescription)"
			storeLog.error(
				"download failed \(model.repoID, privacy: .public): \(error.localizedDescription, privacy: .public)"
			)
		}
		downloadingModel = nil
	}

	/// Soft cancel - resets the UI. MLX's load has no cancellation handle, so an
	/// in-flight fetch may continue in the background.
	public func cancelDownload() {
		downloadingModel = nil
		downloadProgress = 0
	}

	public func uninstall(_ id: String) {
		downloadedModels.remove(id)
		persistDownloaded()
		if selectedModelID == id { selectedModelID = downloadedModels.first }
		// Actually free the disk: delete the repo's Hub cache dir (blobs +
		// snapshots + refs). Without this an "uninstall" only forgot the entry
		// and a re-download finished instantly from the still-present cache.
		guard let model = LocalModelCatalog.model(id: id) else { return }
		let dir = Self.repoCacheDir(model.repoID)
		do {
			try FileManager.default.removeItem(at: dir)
			storeLog.notice("uninstalled \(model.repoID, privacy: .public) (removed cache)")
		} catch {
			storeLog.error(
				"uninstall: failed to remove \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
			)
		}
	}

	public func select(_ id: String) {
		guard downloadedModels.contains(id) else { return }
		selectedModelID = id
	}

	private func persistDownloaded() {
		UserDefaults.standard.set(Array(downloadedModels), forKey: Self.downloadedKey)
	}

	/// The HuggingFace Hub cache directory for a repo, e.g.
	/// `<cache>/models--mlx-community--gemma-4-26b-a4b-it-4bit`.
	private static func repoCacheDir(_ repoID: String) -> URL {
		let dirName = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
		return HubCache.default.cacheDirectory.appendingPathComponent(dirName)
	}

	/// Total byte size of all files under `dir` (0 if it doesn't exist yet).
	nonisolated private static func directorySize(_ dir: URL) -> Int64 {
		let fm = FileManager.default
		guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
			return 0
		}
		var total: Int64 = 0
		for case let url as URL in en {
			total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
		}
		return total
	}

	/// Names of existing `CFNetworkDownload_*.tmp` files - captured at download
	/// start so orphans from earlier attempts can be excluded from the byte count.
	nonisolated private static func tempDownloadNames(_ tmpDir: URL) -> Set<String> {
		let fm = FileManager.default
		guard let items = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
		else { return [] }
		return Set(
			items.map { $0.lastPathComponent }.filter { $0.hasPrefix("CFNetworkDownload") })
	}

	/// Total bytes of in-flight URLSession downloads (`CFNetworkDownload_*.tmp`)
	/// in the temp dir - the shards stream here before being moved into blobs/.
	/// `excluding` skips orphan temp files from earlier download attempts.
	nonisolated private static func tempDownloadSize(
		_ tmpDir: URL, excluding: Set<String>
	) -> Int64 {
		let fm = FileManager.default
		guard
			let items = try? fm.contentsOfDirectory(
				at: tmpDir, includingPropertiesForKeys: [.fileSizeKey])
		else { return 0 }
		var total: Int64 = 0
		for url in items
		where url.lastPathComponent.hasPrefix("CFNetworkDownload")
			&& !excluding.contains(url.lastPathComponent)
		{
			total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
		}
		return total
	}
}
