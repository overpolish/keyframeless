/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// One-shot LLM call that returns a JSON string conforming to a caller-
/// supplied JSON schema. Uses Anthropic's tools API (forced `tool_choice`)
/// or OpenAI's `response_format: json_schema` so the model can't hallucinate
/// the shape - it either returns valid JSON or the call errors out.
enum AIStructuredCall {
	struct Error: Swift.Error, LocalizedError {
		let message: String
		var errorDescription: String? { message }
	}

	/// Returns the JSON string the model emitted. Caller parses it.
	/// `enableThinking` turns on Anthropic extended-thinking so the model can
	/// reason in tokens before committing to the structured output. Worth it
	/// for arithmetic / layout passes; ignored for OpenAI (its reasoning is
	/// per-model rather than per-request).
	/// `cachedSystemPrefix`, when non-nil, is prepended to the system content
	/// and marked as a cache breakpoint. On Anthropic the prefix becomes its
	/// own ephemeral-cached text block (10% read cost vs 100% normal). On
	/// OpenAI we just concatenate; their automatic prefix caching picks it up
	/// as long as the prefix text stays identical across calls. Put STABLE
	/// content (lane schemas, instructions) in the prefix and per-call dynamic
	/// content (current timeline state, prompt-specific framing) in `system`.
	@MainActor
	static func call(
		system: String,
		cachedSystemPrefix: String? = nil,
		userMessage: String,
		schemaName: String,
		schemaDescription: String,
		jsonSchema: [String: Any],
		modelOverride: String? = nil,
		enableThinking: Bool = false,
		/// How hard a thinking model should reason: "high" for the passes where
		/// correctness beats latency (writing a whole shader). nil = provider
		/// default. Ignored without thinking.
		effort: String? = nil
	) async throws -> String {
		let provider = AIKeyState.shared.activeProvider
		if provider == .local {
			// The host's llama.cpp runner grammar-constrains output to the schema,
			// so the model can't emit invalid JSON regardless of size. Cloud
			// `modelOverride` is ignored; the runner loads the selected model.
			guard let runner = LocalLLM.runner else {
				throw AITransformError.localUnavailable
			}
			let combinedSystem: String
			if let prefix = cachedSystemPrefix, !prefix.isEmpty {
				combinedSystem = prefix + "\n\n" + system
			} else {
				combinedSystem = system
			}
			let schemaJSON =
				(try? JSONSerialization.data(withJSONObject: jsonSchema, options: [.sortedKeys]))
				.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
			return try await runner.complete(
				modelID: LocalModelStore.shared.selectedModelID ?? "",
				system: combinedSystem,
				user: userMessage,
				jsonSchemaJSON: schemaJSON,
				enableThinking: enableThinking
			)
		}
		guard let key = try AIKeychain.load(provider) else {
			throw AITransformError.noKey
		}
		switch provider {
		case .anthropic:
			return try await callAnthropic(
				key: key,
				system: system,
				cachedPrefix: cachedSystemPrefix,
				userMessage: userMessage,
				schemaName: schemaName,
				schemaDescription: schemaDescription,
				jsonSchema: jsonSchema,
				model: modelOverride ?? "claude-sonnet-4-6",
				enableThinking: enableThinking,
				effort: effort
			)
		case .openai:
			// OpenAI's "thinking" is per-model (the o-series reasoning models)
			// rather than a request flag. Swap to a reasoning variant when
			// the caller asked for thinking; otherwise stay on gpt-4o.
			let openaiModel: String
			if let override = modelOverride {
				openaiModel = override
			} else if enableThinking {
				openaiModel = "o4-mini"
			} else {
				openaiModel = "gpt-4o-2024-08-06"
			}
			let combinedSystem: String
			if let prefix = cachedSystemPrefix, !prefix.isEmpty {
				combinedSystem = prefix + "\n\n" + system
			} else {
				combinedSystem = system
			}
			return try await callOpenAI(
				key: key,
				system: combinedSystem,
				userMessage: userMessage,
				schemaName: schemaName,
				jsonSchema: jsonSchema,
				model: openaiModel,
				isReasoningModel: enableThinking && modelOverride == nil,
				effort: effort
			)
		case .local:
			throw AITransformError.localUnavailable
		}
	}

	// MARK: - Anthropic

	@MainActor
	private static func callAnthropic(
		key: String, system: String, cachedPrefix: String?, userMessage: String,
		schemaName: String, schemaDescription: String,
		jsonSchema: [String: Any], model: String,
		enableThinking: Bool, effort: String?
	) async throws -> String {
		var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
		request.httpMethod = "POST"
		request.setValue(key, forHTTPHeaderField: "x-api-key")
		request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.timeoutInterval = 90

		// Build the system field. Cacheable prefix (if provided) becomes its
		// own ephemeral-cached block; the dynamic system follows as a normal
		// text block. Fall back to the legacy "cache big system as one block"
		// rule when no explicit prefix was passed.
		let systemField: Any
		if let prefix = cachedPrefix, !prefix.isEmpty {
			systemField = [
				[
					"type": "text",
					"text": prefix,
					"cache_control": ["type": "ephemeral"],
				],
				[
					"type": "text",
					"text": system,
				],
			]
		} else if system.utf8.count >= 4_000 {
			systemField = [
				[
					"type": "text",
					"text": system,
					"cache_control": ["type": "ephemeral"],
				]
			]
		} else {
			systemField = system
		}

		// Extended thinking requires `tool_choice: auto` (Anthropic rejects
		// "tool" and "any" with thinking enabled). We only register one tool
		// and the system prompt makes the call mandatory, so "auto" still
		// produces the structured response in practice.
		let toolChoice: [String: Any] =
			enableThinking
			? ["type": "auto"]
			: ["type": "tool", "name": schemaName]

		var body: [String: Any] = [
			"model": model,
			"max_tokens": enableThinking ? 16_000 : 4096,
			"system": systemField,
			"tools": [
				[
					"name": schemaName,
					"description": schemaDescription,
					"input_schema": jsonSchema,
				]
			],
			"tool_choice": toolChoice,
			"messages": [
				["role": "user", "content": userMessage]
			],
		]
		if enableThinking {
			let thinking = anthropicThinkingParam(model: model)
			body["thinking"] = thinking
			// `effort` only exists on the adaptive-thinking generations.
			if let effort, thinking["type"] as? String == "adaptive" {
				body["output_config"] = ["effort": effort]
			}
			// A reasoning model writing a whole shader can take well over a minute.
			request.timeoutInterval = 300
		}
		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw Error(message: "Not an HTTP response")
		}
		guard (200..<300).contains(http.statusCode) else {
			let body = String(data: data, encoding: .utf8) ?? "<binary>"
			throw Error(message: "HTTP \(http.statusCode): \(body)")
		}

		struct Response: Decodable {
			struct Block: Decodable {
				let type: String
				let input: JSONValue?
			}
			let content: [Block]
		}
		let decoded = try JSONDecoder().decode(Response.self, from: data)
		guard let toolUse = decoded.content.first(where: { $0.type == "tool_use" }),
			let input = toolUse.input
		else {
			throw Error(message: "Anthropic response had no tool_use block")
		}
		let object = input.toAny()
		let outData = try JSONSerialization.data(withJSONObject: object)
		guard let str = String(data: outData, encoding: .utf8) else {
			throw Error(message: "Couldn't reserialize Anthropic tool_use input")
		}
		return str
	}

	/// The thinking shape Anthropic accepts depends on the model generation:
	/// 4.5 and older take a token budget, everything from 4.6 on (Sonnet 4.6,
	/// Opus 4.6+, Sonnet 5, Opus 5, Fable 5) takes adaptive thinking and REJECTS
	/// `budget_tokens` with a 400 on the newest models.
	private static func anthropicThinkingParam(model: String) -> [String: Any] {
		// Only the generations that still take a budget are listed; anything
		// newer (or unknown) gets adaptive, which is where the API is heading.
		let legacy = [
			"claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-5",
			"claude-opus-4-1", "claude-opus-4-2025", "claude-sonnet-4-2025",
			"claude-3",
		]
		if legacy.contains(where: { model.hasPrefix($0) }) {
			return ["type": "enabled", "budget_tokens": 4_000]
		}
		return ["type": "adaptive"]
	}

	// MARK: - OpenAI

	@MainActor
	private static func callOpenAI(
		key: String, system: String, userMessage: String,
		schemaName: String, jsonSchema: [String: Any], model: String,
		isReasoningModel: Bool, effort: String? = nil
	) async throws -> String {
		var request = URLRequest(
			url: URL(string: "https://api.openai.com/v1/chat/completions")!)
		request.httpMethod = "POST"
		request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.timeoutInterval = isReasoningModel ? (effort == "high" ? 300 : 120) : 60

		// Reasoning models (o-series) have a few API quirks:
		// - the system role becomes "developer"
		// - no temperature / top_p (rejected by API)
		// - use max_completion_tokens instead of max_tokens (only matters if
		//   we cap output; we leave both unset to use API defaults)
		// - reasoning_effort selects how much they think before answering
		let systemRole = isReasoningModel ? "developer" : "system"
		var body: [String: Any] = [
			"model": model,
			"messages": [
				["role": systemRole, "content": system],
				["role": "user", "content": userMessage],
			],
			"response_format": [
				"type": "json_schema",
				"json_schema": [
					"name": schemaName,
					"strict": true,
					"schema": jsonSchema,
				],
			],
		]
		if isReasoningModel {
			body["reasoning_effort"] = effort ?? "medium"
		}
		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw Error(message: "Not an HTTP response")
		}
		guard (200..<300).contains(http.statusCode) else {
			let body = String(data: data, encoding: .utf8) ?? "<binary>"
			throw Error(message: "HTTP \(http.statusCode): \(body)")
		}
		struct Response: Decodable {
			struct Choice: Decodable {
				struct Message: Decodable { let content: String? }
				let message: Message
			}
			let choices: [Choice]
		}
		let decoded = try JSONDecoder().decode(Response.self, from: data)
		guard let content = decoded.choices.first?.message.content, !content.isEmpty
		else {
			throw Error(message: "Empty OpenAI response")
		}
		return content
	}
}

/// Tiny JSON tree we use to decode whatever Anthropic put in `tool_use.input`
/// and turn it back into Foundation objects.
enum JSONValue: Decodable {
	case object([String: JSONValue])
	case array([JSONValue])
	case string(String)
	case number(Double)
	case bool(Bool)
	case null

	init(from decoder: Decoder) throws {
		let c = try decoder.singleValueContainer()
		if c.decodeNil() {
			self = .null
			return
		}
		if let v = try? c.decode(Bool.self) {
			self = .bool(v)
			return
		}
		if let v = try? c.decode(Double.self) {
			self = .number(v)
			return
		}
		if let v = try? c.decode(String.self) {
			self = .string(v)
			return
		}
		if let v = try? c.decode([String: JSONValue].self) {
			self = .object(v)
			return
		}
		if let v = try? c.decode([JSONValue].self) {
			self = .array(v)
			return
		}
		throw DecodingError.dataCorruptedError(
			in: c, debugDescription: "Unknown JSON value")
	}

	func toAny() -> Any {
		switch self {
		case .object(let o): return o.mapValues { $0.toAny() }
		case .array(let a): return a.map { $0.toAny() }
		case .string(let s): return s
		case .number(let n):
			if n.rounded() == n && abs(n) < 1e15 { return Int(n) }
			return n
		case .bool(let b): return b
		case .null: return NSNull()
		}
	}
}
