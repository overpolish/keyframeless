/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation
import os

private let llmLog = Logger(subsystem: "co.overpolish.keyframeless", category: "ai.helper")

/// Local inference, behind a protocol so the engine is swappable. Two concrete
/// runners ship: `SharedHelperRunner` (talks to one shared out-of-process helper
/// over an app-group socket) and `MLXLocalLLMRunner` (Apple MLX, in-process).
/// The right one is chosen automatically - see `LocalLLM.defaultRunner`.
public protocol LocalLLMRunner: Sendable {
	/// Run one chat completion against the on-demand-loaded local model.
	/// - Parameters:
	///   - modelID: catalog id selecting which model to load.
	///   - jsonSchemaJSON: the JSON Schema serialized to a string for structured
	///     passes (grammar-constrained output); nil for free-form text. (A string
	///     rather than `[String: Any]` so it's Sendable across the actor boundary.)
	///   - enableThinking: set by the pipeline for complex timing/values passes;
	///     triggers a two-pass run (reason freely, then grammar-format to JSON).
	/// - Returns: the assistant message content (JSON string, or plain text).
	func complete(
		modelID: String,
		system: String,
		user: String,
		jsonSchemaJSON: String?,
		enableThinking: Bool
	) async throws -> String

	/// Stream a PLAIN-TEXT completion (an answer) token-by-token so the UI can
	/// show the reply as it's written. No schema, no thinking - streaming only
	/// makes sense for free-form answers (a structured/transform result is applied
	/// atomically, so there's nothing to show mid-flight). Yields incremental
	/// chunks; the consumer accumulates. Default: a single chunk via `complete`.
	func completeStreaming(
		modelID: String, system: String, user: String
	) async -> AsyncThrowingStream<String, Error>
}

extension LocalLLMRunner {
	public func completeStreaming(
		modelID: String, system: String, user: String
	) async -> AsyncThrowingStream<String, Error> {
		AsyncThrowingStream { continuation in
			Task {
				do {
					let text = try await complete(
						modelID: modelID, system: system, user: user,
						jsonSchemaJSON: nil, enableThinking: false)
					continuation.yield(text)
					continuation.finish()
				} catch {
					continuation.finish(throwing: error)
				}
			}
		}
	}
}

public enum LocalLLM {
	/// The active runner. Defaults per host (see `defaultRunner`); overridable for
	/// tests / alternate engines. `nil` means local inference is unavailable and
	/// the `.local` dispatch throws rather than runs.
	@MainActor public static var runner: LocalLLMRunner? = defaultRunner()

	/// Name of the helper executable, embedded in each client's bundle.
	private static let helperName = "kk-ai-helper"

	/// Pick the right engine for the current host:
	/// - If the app-group socket is reachable (the `group.co.overpolish.keyframeless`
	///   entitlement is present), use the SHARED out-of-process helper for EVERY
	///   client - extension AND plugins. One helper process, one model load, serving
	///   them all: it dodges the FCP workflow extension's ~1 GB cap AND stops each
	///   plugin XPC instance from loading its own ~16 GB copy. The first client to
	///   call spawns it from its own bundle; the rest connect over the socket.
	/// - Otherwise (no app-group entitlement wired yet): the memory-capped extension
	///   can't load MLX in-process, so local is disabled (nil); a plugin has the
	///   headroom, so it falls back to the in-process MLX runner.
	@MainActor static func defaultRunner() -> LocalLLMRunner? {
		if let shared = SharedHelperRunner(helperLocator: { helperBinaryURL() }) {
			llmLog.notice("LocalLLM: shared out-of-process helper (app-group)")
			return shared
		}
		guard Bundle.main.bundleURL.pathExtension == "appex" else {
			llmLog.notice("LocalLLM: in-process MLX (plugin, no app-group)")
			return MLXLocalLLMRunner()
		}
		llmLog.error("LocalLLM: extension has no app-group socket; local disabled")
		return nil
	}

	/// The helper executable embedded in THIS client's bundle (sandbox only allows
	/// exec'ing in-bundle binaries). Resolved via the auxiliary-executable lookup,
	/// with a direct Contents/MacOS fallback.
	private static func helperBinaryURL() -> URL? {
		let fm = FileManager.default
		if let aux = Bundle.main.url(forAuxiliaryExecutable: helperName),
			fm.fileExists(atPath: aux.path)
		{
			return aux
		}
		let direct = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)")
		return fm.fileExists(atPath: direct.path) ? direct : nil
	}
}
