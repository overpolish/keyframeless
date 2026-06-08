/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Local inference, behind a protocol so the engine is swappable. The default is
/// `MLXLocalLLMRunner` - Apple's MLX, in-process (no helper / XPC / launch
/// infrastructure). Plugins need no setup.
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
	/// Defaults to the in-process MLX runner. Overridable for tests / alternate
	/// engines. Load or inference failure surfaces as a thrown error at call time.
	@MainActor public static var runner: LocalLLMRunner? = MLXLocalLLMRunner()
}
