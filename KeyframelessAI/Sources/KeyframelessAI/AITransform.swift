/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

public enum AITransformError: LocalizedError {
	case noActiveProvider
	case noKey
	case http(Int, String)
	case decoding(String)
	case empty

	public var errorDescription: String? {
		switch self {
		case .noActiveProvider: return "No AI provider configured"
		case .noKey: return "Missing API key"
		case .http(let code, let body): return "HTTP \(code): \(body)"
		case .decoding(let msg): return "Couldn't read response: \(msg)"
		case .empty: return "Empty response from provider"
		}
	}
}

public enum AITransform {
	/// Run a user instruction (e.g. "translate to german", "fix capitalization")
	/// against a plain-text input. Returns the transformed text only - no preamble,
	/// no surrounding quotes, no commentary. Caller is responsible for re-aligning
	/// per-word timing against the original word array.
	public static func transform(
		instruction: String,
		text: String,
		overrideSystemPrompt: String? = nil,
		modelOverride: String? = nil
	) async throws -> String {
		let provider = await MainActor.run { AIKeyState.shared.activeProvider }
		guard let key = try AIKeychain.load(provider) else { throw AITransformError.noKey }

		let system =
			overrideSystemPrompt ?? """
				You are a text transformation function, not a conversational assistant.

				Apply the user's instruction to the input text and output the result. \
				Output ONLY the transformed text. No preamble, no quotes around the \
				output, no commentary, no explanation, no apology, no questions back.

				Rules:
				- If the instruction is already satisfied (e.g. asked to translate to a \
				language the text is already in), output the input text verbatim.
				- If the instruction is unclear or impossible, output the input text \
				verbatim. Do not explain.
				- Never write phrases like "The text is already...", "Here is the...", \
				"I cannot...". These are forbidden.
				- Preserve word boundaries (spaces between words).
				- Do not add or remove sentences unless the instruction explicitly says to.
				"""

		// Mark the system prompt as cacheable when it's big enough to be worth
		// it. Anthropic charges 125% to write the cache and 10% to read, so the
		// breakeven is one cache hit — only worth it when system is large.
		let cacheSystem = system.utf8.count >= 4_000

		switch provider {
		case .anthropic:
			return try await callAnthropic(
				key: key, system: system, cache: cacheSystem,
				instruction: instruction, text: text,
				model: modelOverride ?? "claude-haiku-4-5-20251001")
		case .openai:
			return try await callOpenAI(
				key: key, system: system, instruction: instruction, text: text,
				model: modelOverride ?? "gpt-4o-mini")
		}
	}

	private static func callAnthropic(
		key: String, system: String, cache: Bool, instruction: String, text: String,
		model: String
	) async throws -> String {
		var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
		request.httpMethod = "POST"
		request.setValue(key, forHTTPHeaderField: "x-api-key")
		request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.timeoutInterval = 60

		let systemField: Any
		if cache {
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

		let body: [String: Any] = [
			"model": model,
			"max_tokens": 4096,
			"system": systemField,
			"messages": [
				[
					"role": "user",
					"content": "Instruction: \(instruction)\n\nText:\n\(text)",
				]
			],
		]
		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw AITransformError.decoding("Not an HTTP response")
		}
		guard (200..<300).contains(http.statusCode) else {
			let body = String(data: data, encoding: .utf8) ?? "<binary>"
			throw AITransformError.http(http.statusCode, body)
		}

		struct Response: Decodable {
			struct Block: Decodable {
				let type: String
				let text: String?
			}
			let content: [Block]
		}
		let decoded = try JSONDecoder().decode(Response.self, from: data)
		let combined = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
		let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw AITransformError.empty }
		return trimmed
	}

	private static func callOpenAI(
		key: String, system: String, instruction: String, text: String,
		model: String
	) async throws -> String {
		var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
		request.httpMethod = "POST"
		request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.timeoutInterval = 60

		let body: [String: Any] = [
			"model": model,
			"messages": [
				["role": "system", "content": system],
				["role": "user", "content": "Instruction: \(instruction)\n\nText:\n\(text)"],
			],
		]
		request.httpBody = try JSONSerialization.data(withJSONObject: body)

		let (data, response) = try await URLSession.shared.data(for: request)
		guard let http = response as? HTTPURLResponse else {
			throw AITransformError.decoding("Not an HTTP response")
		}
		guard (200..<300).contains(http.statusCode) else {
			let body = String(data: data, encoding: .utf8) ?? "<binary>"
			throw AITransformError.http(http.statusCode, body)
		}

		struct Response: Decodable {
			struct Choice: Decodable {
				struct Message: Decodable { let content: String? }
				let message: Message
			}
			let choices: [Choice]
		}
		let decoded = try JSONDecoder().decode(Response.self, from: data)
		let content = decoded.choices.first?.message.content ?? ""
		let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw AITransformError.empty }
		return trimmed
	}
}
