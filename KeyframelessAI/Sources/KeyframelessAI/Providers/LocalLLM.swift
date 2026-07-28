/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation
import os

private let llmLog = Logger(subsystem: "com.keyframeless", category: "ai.helper")

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

	/// Poll how many local generations the shared helper is running (0 when local
	/// isn't the shared helper, or the helper is down). The socket I/O is done off
	/// the main thread; the result is delivered back on the main actor. Drives the
	/// popover's job/queue indicator.
	@MainActor public static func activeJobCount(_ completion: @escaping @MainActor (Int) -> Void) {
		guard let shared = runner as? SharedHelperRunner else {
			completion(0)
			return
		}
		DispatchQueue.global(qos: .utility).async {
			let n = shared.activeJobCount()
			DispatchQueue.main.async { completion(n) }
		}
	}

	/// Cancel every in-flight local generation (the popover's Stop button). No-op
	/// unless the shared helper is the active runner.
	@MainActor public static func cancelActiveJobs() {
		guard let shared = runner as? SharedHelperRunner else { return }
		DispatchQueue.global(qos: .userInitiated).async { shared.cancelActiveJobs() }
	}

	/// The runner is ALWAYS the shared out-of-process helper (installed once by the
	/// "Keyframeless AI" package, launched on demand by launchd). MLX is never linked
	/// in-process here - this is the thin client every plugin/extension links.
	/// `SharedHelperRunner` init returns nil without the `group.com.keyframeless`
	/// entitlement (no app-group socket path); local inference is then unavailable and
	/// the `.local` dispatch throws rather than runs.
	@MainActor static func defaultRunner() -> LocalLLMRunner? {
		if let shared = SharedHelperRunner() {
			llmLog.notice("LocalLLM: shared out-of-process helper (app-group)")
			return shared
		}
		llmLog.error("LocalLLM: no app-group socket; local disabled (install Keyframeless AI)")
		return nil
	}

	/// Strip a `<think>...</think>` reasoning prefix from a model reply, returning the
	/// trimmed answer. Lives here (thin) so plugin code can call it without linking the
	/// MLX engine; the in-process runner uses it too.
	public static func stripThink(_ s: String) -> String {
		guard let r = s.range(of: "</think>") else {
			return s.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
	}
}
