/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Adopt catalog models the user already downloaded OUTSIDE Keyframeless (mlx_lm,
/// huggingface-cli, LM Studio's HF mirror - anything that fills the standard
/// HuggingFace hub cache), so the same bytes aren't downloaded twice.
///
/// An adoption is a shell in the shared app-group cache: a REAL repo directory
/// holding the `.kkcomplete` marker (a real file, so the sandboxed plugins'
/// "is downloaded" stat works) plus symlinks to the external repo's
/// `snapshots` / `blobs` / `refs`. The unsandboxed helper loads weights through
/// the links; the user's original download is never moved or modified, and
/// deleting the model from Kai removes only the shell.
///
/// The SCAN must run in the helper: plugins are sandboxed and cannot see
/// `~/.cache`. The logic lives here in the thin library so the package tests
/// can drive it with fabricated directories, and so the plugin-side uninstall
/// shares the same names for the marker and tombstone.
public enum ModelAdoption {

	/// Manifest the helper writes into every adoption shell (a real file, so the
	/// sandboxed plugins can render name/size without stat-ing through the
	/// symlinks, which their sandbox denies). Sizes are computed at adoption.
	public static let manifestName = ".kkadopt.json"

	public struct ExternalModel: Sendable, Equatable {
		public let repoID: String
		public let modelType: String
		public let sizeBytes: Int64
		public init(repoID: String, modelType: String, sizeBytes: Int64) {
			self.repoID = repoID
			self.modelType = modelType
			self.sizeBytes = sizeBytes
		}
	}

	/// Tombstone written next to (not inside) a removed adopted repo, so the next
	/// scan doesn't immediately re-adopt what the user just deleted. Cleared when
	/// the user explicitly downloads that model through Kai.
	public static func tombstoneURL(repoID: String, base: URL) -> URL {
		base.appendingPathComponent(Self.repoDirName(repoID) + ".kkignore")
	}

	/// `models--org--name`, the HF hub directory name for a repo id.
	public static func repoDirName(_ repoID: String) -> String {
		"models--" + repoID.replacingOccurrences(of: "/", with: "--")
	}

	/// Whether the repo dir in the SHARED cache is an adoption shell rather than
	/// a real download (its `snapshots` is a symlink).
	public static func isAdopted(repoDir: URL) -> Bool {
		let values = try? repoDir.appendingPathComponent("snapshots")
			.resourceValues(forKeys: [.isSymbolicLinkKey])
		return values?.isSymbolicLink == true
	}

	/// The standard external HF hub caches on this machine, existing ones only.
	/// `HF_HUB_CACHE` / `HF_HOME` are honoured when the process has them (a dev
	/// helper); the launchd helper sees only the default location.
	public static func externalHubCaches() -> [URL] {
		var candidates: [URL] = []
		let env = ProcessInfo.processInfo.environment
		if let hub = env["HF_HUB_CACHE"], !hub.isEmpty {
			candidates.append(URL(fileURLWithPath: hub))
		}
		if let home = env["HF_HOME"], !home.isEmpty {
			candidates.append(URL(fileURLWithPath: home).appendingPathComponent("hub"))
		}
		candidates.append(
			FileManager.default.homeDirectoryForCurrentUser
				.appendingPathComponent(".cache/huggingface/hub"))
		// The shared cache itself must never count as "external".
		let shared = LocalAIHelperSocket.sharedModelCacheDir()?.standardizedFileURL.path
		var seen = Set<String>()
		return candidates.filter { url in
			let path = url.standardizedFileURL.path
			guard path != shared, !seen.contains(path) else { return false }
			seen.insert(path)
			var isDir: ObjCBool = false
			guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
				isDir.boolValue
			else { return false }
			return true
		}
	}

	/// Whether an external repo directory holds a COMPLETE download worth
	/// adopting: its newest snapshot has a `config.json` and at least one
	/// weights file, and every file in that snapshot resolves (hub snapshots are
	/// symlinks into `blobs/`; a partial download leaves dangling links).
	public static func repoLooksComplete(_ repoDir: URL) -> Bool {
		let fm = FileManager.default
		guard let newest = newestSnapshot(repoDir),
			let files = try? fm.contentsOfDirectory(atPath: newest.path)
		else { return false }
		guard files.contains("config.json") else { return false }
		guard files.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
		for name in files {
			// fileExists follows symlinks: false = dangling = incomplete blob.
			let f = newest.appendingPathComponent(name)
			if !fm.fileExists(atPath: f.path) { return false }
		}
		return true
	}

	/// The most recently touched revision dir under `snapshots/`, nil when none.
	static func newestSnapshot(_ repoDir: URL) -> URL? {
		let snapshots = repoDir.appendingPathComponent("snapshots")
		let revisions = (try? FileManager.default.contentsOfDirectory(
			at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles])) ?? []
		return revisions.max { a, b in
			let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
				.contentModificationDate ?? .distantPast
			let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
				.contentModificationDate ?? .distantPast
			return da < db
		}
	}

	/// The repo id a hub cache dir name encodes, or nil for a name that isn't
	/// `models--org--name` (extra `--` runs are ambiguous; HF writes one per
	/// path separator, and org/name contain none).
	public static func repoID(fromDirName name: String) -> String? {
		guard name.hasPrefix("models--") else { return nil }
		let parts = name.dropFirst("models--".count).components(separatedBy: "--")
		guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
		return parts.joined(separator: "/")
	}

	/// Every COMPLETE repo in `externals` with a parsable `config.json`
	/// model_type, with its total blob size. This is the raw discovery; the
	/// caller filters by supported type and catalog membership.
	public static func discoverExternalRepos(scanning externals: [URL]) -> [ExternalModel] {
		let fm = FileManager.default
		var found: [ExternalModel] = []
		var seen = Set<String>()
		for hub in externals {
			guard
				let entries = try? fm.contentsOfDirectory(
					at: hub, includingPropertiesForKeys: nil,
					options: [.skipsHiddenFiles])
			else { continue }
			for dir in entries {
				guard let repoID = repoID(fromDirName: dir.lastPathComponent),
					!seen.contains(repoID),
					repoLooksComplete(dir),
					let type = modelType(ofRepo: dir)
				else { continue }
				seen.insert(repoID)
				found.append(
					ExternalModel(
						repoID: repoID, modelType: type,
						sizeBytes: blobsSize(ofRepo: dir)))
			}
		}
		return found
	}

	/// `model_type` from the newest snapshot's config.json, nil when unreadable.
	static func modelType(ofRepo repoDir: URL) -> String? {
		guard let snapshot = newestSnapshot(repoDir),
			let data = try? Data(
				contentsOf: snapshot.appendingPathComponent("config.json")),
			let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }
		return obj["model_type"] as? String
	}

	static func blobsSize(ofRepo repoDir: URL) -> Int64 {
		let fm = FileManager.default
		let blobs = repoDir.appendingPathComponent("blobs")
		guard let names = try? fm.contentsOfDirectory(atPath: blobs.path) else {
			return 0
		}
		return names.reduce(Int64(0)) { total, name in
			let attrs = try? fm.attributesOfItem(
				atPath: blobs.appendingPathComponent(name).path)
			return total + ((attrs?[.size] as? Int64) ?? 0)
		}
	}

	/// Scan `externals` for complete copies of `repoIDs` and adopt each one the
	/// shared cache doesn't already have. A repo is skipped when its shared dir
	/// already exists (downloaded, adopting, or a lingering partial - never mix
	/// into an existing dir) or when the user deleted a previous adoption (the
	/// tombstone). Returns the repo ids adopted this pass.
	@discardableResult
	public static func adopt(
		repoIDs: [String], into base: URL, scanning externals: [URL]
	) -> [String] {
		let fm = FileManager.default
		var adopted: [String] = []
		for repoID in repoIDs {
			let dirName = repoDirName(repoID)
			let sharedRepo = base.appendingPathComponent(dirName)
			guard !fm.fileExists(atPath: sharedRepo.path) else { continue }
			guard !fm.fileExists(atPath: tombstoneURL(repoID: repoID, base: base).path)
			else { continue }
			guard
				let source = externals.map({ $0.appendingPathComponent(dirName) })
					.first(where: { repoLooksComplete($0) })
			else { continue }
			if makeShell(for: repoID, source: source, in: base) {
				adopted.append(repoID)
			}
		}
		return adopted
	}

	/// Adopt every discovered external model that is NOT a catalog repo and whose
	/// `model_type` the local runner supports. Same shell + tombstone semantics
	/// as catalog adoption. Returns the adopted models.
	@discardableResult
	public static func adoptCustom(
		into base: URL, scanning externals: [URL], supportedTypes: Set<String>,
		excludingRepoIDs catalog: Set<String>
	) -> [ExternalModel] {
		let fm = FileManager.default
		var adopted: [ExternalModel] = []
		for found in discoverExternalRepos(scanning: externals) {
			guard !catalog.contains(found.repoID),
				supportedTypes.contains(found.modelType)
			else { continue }
			let sharedRepo = base.appendingPathComponent(repoDirName(found.repoID))
			guard !fm.fileExists(atPath: sharedRepo.path),
				!fm.fileExists(
					atPath: tombstoneURL(repoID: found.repoID, base: base).path)
			else { continue }
			let source = externals
				.map { $0.appendingPathComponent(repoDirName(found.repoID)) }
				.first { repoLooksComplete($0) }
			guard let source, makeShell(for: found.repoID, source: source, in: base)
			else { continue }
			adopted.append(found)
		}
		return adopted
	}

	/// Build one adoption shell: real dir, symlinked content, manifest, marker
	/// LAST (the marker is the "downloaded" signal, so everything else must be
	/// in place before it lands). Tears the shell down on any failure.
	private static func makeShell(for repoID: String, source: URL, in base: URL) -> Bool {
		let fm = FileManager.default
		let sharedRepo = base.appendingPathComponent(repoDirName(repoID))
		do {
			try fm.createDirectory(at: sharedRepo, withIntermediateDirectories: true)
			for sub in ["snapshots", "blobs", "refs"]
			where fm.fileExists(atPath: source.appendingPathComponent(sub).path) {
				try fm.createSymbolicLink(
					at: sharedRepo.appendingPathComponent(sub),
					withDestinationURL: source.appendingPathComponent(sub))
			}
			let manifest: [String: Any] = [
				"repoID": repoID,
				"modelType": modelType(ofRepo: source) ?? "",
				"sizeBytes": blobsSize(ofRepo: source),
			]
			try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
				.write(to: sharedRepo.appendingPathComponent(manifestName))
			try Data([1]).write(
				to: sharedRepo.appendingPathComponent(
					LocalAIHelperSocket.completeMarkerName))
			return true
		} catch {
			// Half-made shells read as "downloaded" the moment the marker lands,
			// so on any failure tear the shell down rather than leave one.
			try? fm.removeItem(at: sharedRepo)
			return false
		}
	}

	/// Read a shell's manifest. nil for a real (downloaded) repo or a pre-manifest
	/// adoption.
	public static func manifest(ofShell repoDir: URL) -> ExternalModel? {
		guard
			let data = try? Data(
				contentsOf: repoDir.appendingPathComponent(manifestName)),
			let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			let repoID = obj["repoID"] as? String
		else { return nil }
		return ExternalModel(
			repoID: repoID, modelType: obj["modelType"] as? String ?? "",
			sizeBytes: (obj["sizeBytes"] as? NSNumber)?.int64Value ?? 0)
	}
}
