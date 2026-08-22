/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import XCTest

@testable import KeyframelessAI

/// Fabricated-hub tests for ModelAdoption: build tiny fake HF cache repos in
/// temp dirs and drive the scan against them - no network, no MLX, no real
/// models. The on-disk shapes mirror what `hf download` / mlx_lm leave behind:
/// `models--org--name/{snapshots/<rev>/...,blobs/...,refs/...}` with snapshot
/// files symlinked into blobs.
final class ModelAdoptionTests: XCTestCase {
	var external: URL!
	var shared: URL!
	let fm = FileManager.default

	override func setUpWithError() throws {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("kk-adopt-tests-\(UUID().uuidString)")
		external = root.appendingPathComponent("external-hub")
		shared = root.appendingPathComponent("shared-hub")
		try fm.createDirectory(at: external, withIntermediateDirectories: true)
		try fm.createDirectory(at: shared, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? fm.removeItem(at: external.deletingLastPathComponent())
	}

	/// Lay down a fake hub repo. `complete` controls whether the weights blob
	/// exists (an incomplete download leaves the snapshot symlink dangling).
	@discardableResult
	func makeRepo(
		_ repoID: String, in hub: URL, complete: Bool = true, weights: String = "w"
	) throws -> URL {
		let repo = hub.appendingPathComponent(ModelAdoption.repoDirName(repoID))
		let rev = repo.appendingPathComponent("snapshots/abc123")
		let blobs = repo.appendingPathComponent("blobs")
		try fm.createDirectory(at: rev, withIntermediateDirectories: true)
		try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
		try fm.createDirectory(
			at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
		try Data(#"{"model_type": "qwen3"}"#.utf8).write(
			to: blobs.appendingPathComponent("cfg"))
		try fm.createSymbolicLink(
			atPath: rev.appendingPathComponent("config.json").path,
			withDestinationPath: "../../blobs/cfg")
		if complete {
			try Data(weights.utf8).write(to: blobs.appendingPathComponent("wt"))
		}
		try fm.createSymbolicLink(
			atPath: rev.appendingPathComponent("model.safetensors").path,
			withDestinationPath: "../../blobs/wt")
		return repo
	}

	func testAdoptsCompleteExternalRepo() throws {
		try makeRepo("mlx-community/Test-4bit", in: external, weights: "WEIGHTS")
		let adopted = ModelAdoption.adopt(
			repoIDs: ["mlx-community/Test-4bit"], into: shared, scanning: [external])
		XCTAssertEqual(adopted, ["mlx-community/Test-4bit"])
		let repo = shared.appendingPathComponent("models--mlx-community--Test-4bit")
		// Real dir + real marker (the sandboxed "is downloaded" stat)...
		XCTAssertTrue(fm.fileExists(atPath: repo.path))
		XCTAssertTrue(
			fm.fileExists(
				atPath: repo.appendingPathComponent(".kkcomplete").path))
		XCTAssertTrue(ModelAdoption.isAdopted(repoDir: repo))
		// ...and the weights readable THROUGH the shell, resolving the snapshot's
		// relative blob link against the ORIGINAL repo (the load path).
		let read = try String(
			contentsOf: repo.appendingPathComponent(
				"snapshots/abc123/model.safetensors"),
			encoding: .utf8)
		XCTAssertEqual(read, "WEIGHTS")
	}

	func testIgnoresIncompleteAndNonCatalogRepos() throws {
		try makeRepo("mlx-community/Partial-4bit", in: external, complete: false)
		try makeRepo("someone/NotInCatalog", in: external)
		let adopted = ModelAdoption.adopt(
			repoIDs: ["mlx-community/Partial-4bit"], into: shared,
			scanning: [external])
		XCTAssertTrue(adopted.isEmpty)
		XCTAssertEqual(
			try fm.contentsOfDirectory(atPath: shared.path).sorted(), [])
	}

	func testSkipsExistingSharedRepoAndTombstone() throws {
		try makeRepo("mlx-community/Test-4bit", in: external)
		// A real shared-cache download (or lingering partial) is never touched.
		try makeRepo("mlx-community/Test-4bit", in: shared)
		XCTAssertTrue(
			ModelAdoption.adopt(
				repoIDs: ["mlx-community/Test-4bit"], into: shared,
				scanning: [external]
			).isEmpty)
		XCTAssertFalse(
			ModelAdoption.isAdopted(
				repoDir: shared.appendingPathComponent(
					"models--mlx-community--Test-4bit")))
		// Deleted adoption: shell gone, tombstone present -> no re-adoption.
		try fm.removeItem(
			at: shared.appendingPathComponent("models--mlx-community--Test-4bit"))
		try Data([1]).write(
			to: ModelAdoption.tombstoneURL(
				repoID: "mlx-community/Test-4bit", base: shared))
		XCTAssertTrue(
			ModelAdoption.adopt(
				repoIDs: ["mlx-community/Test-4bit"], into: shared,
				scanning: [external]
			).isEmpty)
		// Tombstone cleared (an explicit Kai download does this) -> adopts again.
		try fm.removeItem(
			at: ModelAdoption.tombstoneURL(
				repoID: "mlx-community/Test-4bit", base: shared))
		XCTAssertEqual(
			ModelAdoption.adopt(
				repoIDs: ["mlx-community/Test-4bit"], into: shared,
				scanning: [external]),
			["mlx-community/Test-4bit"])
	}

	func testCustomAdoptionFiltersAndManifests() throws {
		try makeRepo("me/My-Qwen-4bit", in: external, weights: "CUSTOM")
		try makeRepo("mlx-community/Test-4bit", in: external)  // catalog stand-in
		// Unsupported model_type (e.g. whisper) must be ignored.
		let whisper = external.appendingPathComponent("models--me--whisper")
		try makeRepo("me/whisper", in: external)
		try Data(#"{"model_type": "whisper"}"#.utf8).write(
			to: whisper.appendingPathComponent("blobs/cfg"))

		let discovered = ModelAdoption.discoverExternalRepos(scanning: [external])
		XCTAssertEqual(Set(discovered.map(\.repoID)),
			["me/My-Qwen-4bit", "mlx-community/Test-4bit", "me/whisper"])

		let adopted = ModelAdoption.adoptCustom(
			into: shared, scanning: [external],
			supportedTypes: ["qwen3"],
			excludingRepoIDs: ["mlx-community/Test-4bit"])
		XCTAssertEqual(adopted.map(\.repoID), ["me/My-Qwen-4bit"])
		XCTAssertEqual(adopted.first?.modelType, "qwen3")
		XCTAssertGreaterThan(adopted.first?.sizeBytes ?? 0, 0)

		// The shell carries the manifest the sandboxed UI reads.
		let shell = shared.appendingPathComponent("models--me--My-Qwen-4bit")
		let manifest = try XCTUnwrap(ModelAdoption.manifest(ofShell: shell))
		XCTAssertEqual(manifest.repoID, "me/My-Qwen-4bit")
		// Catalog + whisper repos were not adopted.
		XCTAssertEqual(
			try fm.contentsOfDirectory(atPath: shared.path)
				.filter { $0.hasPrefix("models--") }.sorted(),
			["models--me--My-Qwen-4bit"])
	}

	func testDeletingShellKeepsOriginal() throws {
		let source = try makeRepo("mlx-community/Test-4bit", in: external)
		ModelAdoption.adopt(
			repoIDs: ["mlx-community/Test-4bit"], into: shared, scanning: [external])
		let shell = shared.appendingPathComponent("models--mlx-community--Test-4bit")
		try fm.removeItem(at: shell)
		// The user's original download is intact, weights and all.
		XCTAssertTrue(
			fm.fileExists(
				atPath: source.appendingPathComponent("blobs/wt").path))
		XCTAssertTrue(
			ModelAdoption.repoLooksComplete(source))
	}
}

/// Opt-in integration pass against the REAL caches on this machine: adopts any
/// catalog model found in ~/.cache/huggingface/hub into the real shared cache,
/// exactly as the helper's scan does. Gated so CI and normal `swift test` runs
/// never touch the developer's caches. Run with:
///   KK_ADOPT_INTEGRATION=1 swift test --filter RealCacheAdoption
final class RealCacheAdoptionTests: XCTestCase {
	func testAdoptFromRealExternalCaches() throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["KK_ADOPT_INTEGRATION"] == "1")
		let base = try XCTUnwrap(LocalAIHelperSocket.modelCacheBase())
		let externals = ModelAdoption.externalHubCaches()
		print("shared cache:", base.path)
		print("external caches:", externals.map(\.path))
		let adopted = ModelAdoption.adopt(
			repoIDs: LocalModelCatalog.models.map(\.repoID), into: base,
			scanning: externals)
		print("adopted:", adopted)
		let customs = ModelAdoption.adoptCustom(
			into: base, scanning: externals,
			supportedTypes: ["qwen2", "qwen3", "qwen3_moe", "llama", "gemma3_text"],
			excludingRepoIDs: Set(LocalModelCatalog.models.map(\.repoID)))
		print("custom adopted:", customs.map { "\($0.repoID) [\($0.modelType), \($0.sizeBytes) bytes]" })
		for repoID in adopted {
			let shell = base.appendingPathComponent(
				ModelAdoption.repoDirName(repoID))
			XCTAssertTrue(ModelAdoption.isAdopted(repoDir: shell))
			// The config must be readable THROUGH the shell (the helper's load path).
			let refs = shell.appendingPathComponent("refs/main")
			let rev = try String(contentsOf: refs, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines)
			let cfg = shell.appendingPathComponent("snapshots/\(rev)/config.json")
			XCTAssertNoThrow(try Data(contentsOf: cfg))
			print("verified read-through:", cfg.path)
		}
	}
}
