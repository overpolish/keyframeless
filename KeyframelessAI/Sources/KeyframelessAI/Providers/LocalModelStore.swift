/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation
import os

private let storeLog = Logger(subsystem: "com.keyframeless", category: "ai.local")

/// Tracks which local models are downloaded + which is selected. The actual bytes
/// live in the shared app-group HuggingFace cache; the DOWNLOAD runs in the helper
/// (so plugins don't link swift-huggingface / swift-nio), driven here over the socket.
/// "Downloaded" is derived from that shared cache on disk, so a model fetched by any
/// client shows up for all of them.
@MainActor
public final class LocalModelStore: ObservableObject {
	public static let shared = LocalModelStore()

	@Published public private(set) var downloadedModels: Set<String> = []
	@Published public private(set) var downloadingModel: String? = nil
	@Published public private(set) var downloadProgress: Double = 0
	/// Last download/load error, surfaced in the UI.
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

	private static let selectedKey = "com.keyframeless.ai.local.selectedModel"

	/// True while THIS process is the one running the active download (its own socket
	/// stream drives `downloadProgress`). When false, the helper-sync poll is free to
	/// mirror a download another plugin started.
	private var ownsActiveDownload = false
	/// Polls the helper for a download in flight (possibly started by another plugin)
	/// while the models UI is on screen. nil when not polling.
	private var helperSyncTask: Task<Void, Never>?

	private init() {
		selectedModelID = UserDefaults.standard.string(forKey: Self.selectedKey)
		refreshDownloaded()
	}

	/// Re-derive the downloaded set from the shared model cache on disk (a model's
	/// `snapshots/` dir holds files once fetched), then reconcile the selection.
	public func refreshDownloaded() {
		var found: Set<String> = []
		for model in LocalModelCatalog.models where Self.isDownloaded(model.repoID) {
			found.insert(model.id)
		}
		downloadedModels = found
		if let cur = selectedModelID, !found.contains(cur) {
			selectedModelID = found.first
		} else if selectedModelID == nil {
			selectedModelID = found.first
		}
	}

	/// Begin mirroring the helper's live download state while the models UI is visible,
	/// so a plugin that DIDN'T start a download still shows its progress (the download
	/// stream only reaches the initiating process). Call from the view's `onAppear`;
	/// pair with `stopHelperSync()` in `onDisappear`. Cheap: one control roundtrip/sec,
	/// and it never wakes the helper (no download in flight => helper stays down).
	public func startHelperSync() {
		guard helperSyncTask == nil else { return }
		refreshDownloaded()
		helperSyncTask = Task { @MainActor in
			while !Task.isCancelled {
				await reconcileHelperDownload()
				try? await Task.sleep(nanoseconds: 1_000_000_000)
			}
		}
	}

	public func stopHelperSync() {
		helperSyncTask?.cancel()
		helperSyncTask = nil
	}

	/// One poll tick: ask the helper what it's downloading and mirror it. Skips while
	/// WE own the active download (our own stream already drives the UI). When the
	/// helper reports nothing and we were mirroring a foreign download, treat it as
	/// finished and reconcile against the on-disk marker.
	private func reconcileHelperDownload() async {
		if ownsActiveDownload { return }
		let runner = LocalLLM.runner as? SharedHelperRunner
		let cur: (id: String, progress: Double)? = await withCheckedContinuation { cont in
			DispatchQueue.global(qos: .utility).async {
				cont.resume(returning: runner?.currentDownload())
			}
		}
		if let cur, LocalModelCatalog.model(id: cur.id) != nil {
			downloadingModel = cur.id
			downloadProgress = cur.progress
		} else if downloadingModel != nil {
			downloadingModel = nil
			downloadProgress = 0
			refreshDownloaded()
		}
	}

	/// Download the model's files into the shared cache via the helper, forwarding
	/// its progress. The helper is woken on demand; the bytes land in the shared
	/// cache so the runner's later load is a cache hit.
	public func download(_ id: String) async {
		guard downloadingModel == nil, LocalModelCatalog.model(id: id) != nil else { return }
		guard let runner = LocalLLM.runner as? SharedHelperRunner else {
			lastError = "Local AI engine unavailable - install Keyframeless AI."
			return
		}
		downloadingModel = id
		downloadProgress = 0
		lastError = nil
		ownsActiveDownload = true
		do {
			try await runner.downloadModel(id) { frac in
				Task { @MainActor in
					let s = LocalModelStore.shared
					if s.downloadingModel == id { s.downloadProgress = frac }
				}
			}
			downloadProgress = 1.0
			downloadedModels.insert(id)
			if selectedModelID == nil { selectedModelID = id }
		} catch SharedHelperRunner.HelperError.downloadCancelled {
			// User cancelled; the helper already stopped and dropped the partial. Not
			// an error - just fall through and clear the UI.
			storeLog.notice("download cancelled \(id, privacy: .public)")
		} catch {
			// The progress stream can drop (socket timeout / close) during the helper's
			// long post-download verification even though the fetch itself finished and
			// stamped the completion marker - the helper ignores the terminal frame's
			// write result, so a lost `done` frame leaves us pinned at 99%. Reconcile
			// against the on-disk marker before surfacing an error, so a download that
			// actually completed isn't frozen until the next launch.
			refreshDownloaded()
			if downloadedModels.contains(id) {
				downloadProgress = 1.0
				if selectedModelID == nil { selectedModelID = id }
				storeLog.notice(
					"download stream ended early but \(id, privacy: .public) is complete on disk"
				)
			} else {
				lastError = error.localizedDescription
				storeLog.error(
					"download failed \(id, privacy: .public): \(error.localizedDescription, privacy: .public)"
				)
			}
		}
		ownsActiveDownload = false
		downloadingModel = nil
	}

	/// Cancel the active download: tell the helper to stop the fetch and drop the
	/// partial from the shared cache (frees disk), then reset the UI. The helper clears
	/// its download registry, so the sync poll stops mirroring it in every plugin.
	public func cancelDownload() {
		downloadingModel = nil
		downloadProgress = 0
		let runner = LocalLLM.runner as? SharedHelperRunner
		Task.detached { runner?.cancelDownload() }
	}

	public func uninstall(_ id: String) {
		downloadedModels.remove(id)
		if selectedModelID == id { selectedModelID = downloadedModels.first }
		// Free the disk: delete the repo's cache dir (blobs + snapshots + refs).
		guard let model = LocalModelCatalog.model(id: id),
			let dir = LocalAIHelperSocket.repoCacheDir(model.repoID)
		else { return }
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

	/// True only when the helper has stamped the repo's completion marker - i.e. the
	/// download fully finished. A partial or cancelled download leaves blobs on disk
	/// but no marker, so it correctly reads as NOT downloaded (the old "snapshot has
	/// any file" check reported partials as done, so every plugin saw a half-finished
	/// model as ready).
	private static func isDownloaded(_ repoID: String) -> Bool {
		guard let marker = LocalAIHelperSocket.repoCompleteMarker(repoID) else { return false }
		return FileManager.default.fileExists(atPath: marker.path)
	}
}
