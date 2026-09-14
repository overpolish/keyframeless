/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

public enum AIIntent {
	case transform(instruction: String)
	case answer(reply: String)
}

public enum AIRouter {
	/// Routes a user prompt to either a transform instruction (run on selected
	/// transcriptions) or a free-form answer (help / Q&A). One LLM call.
	public static func route(
		_ userPrompt: String,
		selectedCount: Int,
		productContext: String
	) async throws -> AIIntent {
		let (system, userMessage) = await buildPrompt(
			userPrompt, selectedCount: selectedCount, productContext: productContext)
		let raw = try await AITransform.transform(
			instruction: userMessage, text: "", overrideSystemPrompt: system)
		return classify(raw)
	}

	/// Like `route`, but streams a Shape B (answer) reply into `onAnswerChunk` as
	/// it's generated instead of returning it all at once. The decision is made from
	/// the FIRST non-whitespace token: a transform always starts with `<TRANSFORM>`,
	/// so a leading `<` means "buffer silently, it's a transform" and anything else
	/// means "this is an answer, stream it". A transform never calls `onAnswerChunk`.
	/// `onAnswerChunk` receives the cumulative answer text so far (already label-
	/// stripped). Cloud providers don't stream token-by-token (the underlying call is
	/// atomic), so there the answer arrives as a single final chunk - still correct,
	/// just not incremental. The returned intent is authoritative; the final answer
	/// reply equals the last streamed value.
	public static func routeStreaming(
		_ userPrompt: String,
		selectedCount: Int,
		productContext: String,
		onAnswerChunk: @escaping @MainActor (String) -> Void
	) async throws -> AIIntent {
		let (system, userMessage) = await buildPrompt(
			userPrompt, selectedCount: selectedCount, productContext: productContext)
		let decision = DecisionBox()
		let raw = try await AITransform.transformStreaming(
			instruction: userMessage, text: "", overrideSystemPrompt: system
		) { cumulative in
			if decision.isTransform == nil {
				decision.isTransform = firstShapeIsTransform(cumulative)
			}
			if decision.isTransform == false {
				let shown = stripAnswerLabel(
					cumulative.trimmingCharacters(in: .whitespacesAndNewlines))
				await onAnswerChunk(shown)
			}
		}
		return classify(raw)
	}

	/// nil until the first non-whitespace char arrives, then true if it's `<` (a
	/// `<TRANSFORM>` tag is opening) else false (a Shape B answer).
	private static func firstShapeIsTransform(_ cumulative: String) -> Bool? {
		guard let first = cumulative.first(where: { !$0.isWhitespace }) else { return nil }
		return first == "<"
	}

	private static func classify(_ raw: String) -> AIIntent {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if let extracted = extractTransform(from: trimmed) {
			return .transform(instruction: extracted)
		}
		return .answer(reply: stripAnswerLabel(trimmed))
	}

	/// Holds the streamed transform-vs-answer decision. A reference box so the
	/// `@Sendable` streaming callback can flip it (the callback is invoked serially).
	private final class DecisionBox: @unchecked Sendable {
		var isTransform: Bool?
	}

	/// Builds the routing system prompt + user message. Local models prefill slowly,
	/// so they get only the prompt-relevant docs (a 10k-token jam = ~70s on-device);
	/// cloud keeps the full docs (fast prefill, big context).
	private static func buildPrompt(
		_ userPrompt: String, selectedCount: Int, productContext: String
	) async -> (system: String, userMessage: String) {
		let useLocal = await MainActor.run { AIKeyState.shared.activeProvider == .local }
		let entries =
			useLocal
			? await AIKnowledgeRegistry.shared.relevantEntries(to: userPrompt, limit: 4)
			: await AIKnowledgeRegistry.shared.allEntries()
		let docsSection = Self.renderDocs(entries)

		let system = """
			You are the assistant inside \(productContext).

			Your output must be in ONE of exactly two shapes - nothing else, no preamble, no labels:

			Shape A (the user wants to transform the selected items - translate text, rephrase, \
			fix capitalization, strip filler words, change tone, etc. - this only applies when \
			the tool actually supports transforming a selection of items):
			    Output exactly: <TRANSFORM>concise imperative instruction</TRANSFORM>
			    Example user message: "can you translate these to german?"
			    Example output:    <TRANSFORM>translate to german</TRANSFORM>
			    Nothing before or after the tag. No explanation.

			Shape B (the user is asking a question about the tool, OR transforms can't run right now, \
			OR anything that isn't a clear transformation request):
			    Output the answer text directly. 1-3 sentences.
			    Do NOT prefix with "ANSWER", "Answer:", "Yes,", "Sure,", "Great question", or any \
			other label or filler. Start with the substantive content.
			    Stick to facts present in the reference docs; if the docs don't cover the \
			question, say so honestly.

			HARD RULE: If the user's message says 0 items are selected, you MUST use Shape B - \
			there is nothing to transform. Even if their wording sounds like a transform request, \
			respond in Shape B. If the tool doesn't support transforms at all (no selection \
			concept), every response uses Shape B.

			When in Shape B, only use facts present in the REFERENCE DOCS. If the docs don't cover \
			the question, say so honestly. Never invent features.

			If unsure between A and B, prefer B.

			\(docsSection)
			"""

		let userMessage = "[\(selectedCount) item(s) selected]\n\n\(userPrompt)"
		return (system, userMessage)
	}

	private static func stripAnswerLabel(_ raw: String) -> String {
		var s = raw
		let prefixes = [
			"ANSWER\n\n", "ANSWER\n", "ANSWER:\n", "ANSWER: ", "ANSWER\n", "Answer:\n", "Answer: ",
			"Answer\n",
		]
		for p in prefixes {
			if s.hasPrefix(p) {
				s = String(s.dropFirst(p.count))
				break
			}
		}
		return s.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func renderDocs(_ entries: [(source: String, topic: AIKnowledgeTopic)]) -> String
	{
		guard !entries.isEmpty else { return "REFERENCE DOCS:\n(none registered)" }
		let bySource = Dictionary(grouping: entries) { $0.source }
		var out = "REFERENCE DOCS:\n"
		for (source, items) in bySource.sorted(by: { $0.key < $1.key }) {
			out += "\n# \(source)\n"
			for entry in items {
				out += "\n## \(entry.topic.id) - \(entry.topic.summary)\n"
				out += entry.topic.content + "\n"
			}
		}
		return out
	}

	private static func extractTransform(from raw: String) -> String? {
		let open = "<TRANSFORM>"
		let close = "</TRANSFORM>"
		guard let openRange = raw.range(of: open),
			let closeRange = raw.range(of: close, range: openRange.upperBound..<raw.endIndex)
		else { return nil }
		let inner = raw[openRange.upperBound..<closeRange.lowerBound]
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return inner.isEmpty ? nil : inner
	}
}
