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
		let entries = await AIKnowledgeRegistry.shared.allEntries()
		let docsSection = Self.renderDocs(entries)

		let system = """
			You are the assistant inside \(productContext).

			Your output must be in ONE of exactly two shapes - nothing else, no preamble, no labels:

			Shape A (the user wants to transform the selected transcription text - translate, rephrase, \
			fix capitalization, strip filler words, change tone, etc.):
			    Output exactly: <TRANSFORM>concise imperative instruction</TRANSFORM>
			    Example user message: "can you translate these to german?"
			    Example output:    <TRANSFORM>translate to german</TRANSFORM>
			    Nothing before or after the tag. No explanation.

			Shape B (the user is asking a question about the tool, OR transforms can't run right now, \
			OR anything that isn't a clear transformation request):
			    Output the answer text directly. 1-3 sentences.
			    Do NOT prefix with "ANSWER", "Answer:", "Yes,", "Sure,", "Great question", or any \
			other label or filler. Start with the substantive content.
			    Example user message: "does this support srt export?"
			    Example output:    Steno exports SRT in two ways: a standalone .srt file via the SRT Export button, and SRT-format captions delivered to FCP's caption track via the Caption type's SRT format option.

			HARD RULE: If the user's message says 0 transcription lines are selected, you MUST use \
			Shape B - there is nothing to transform. Even if their wording sounds like a transform \
			request ("translate this", "fix the captions"), respond in Shape B and tell them they \
			need to select transcriptions first.

			When in Shape B, only use facts present in the REFERENCE DOCS. If the docs don't cover \
			the question, say so honestly. Never invent features.

			If unsure between A and B, prefer B.

			\(docsSection)
			"""

		let userMessage =
			"[\(selectedCount) transcription line(s) selected]\n\n\(userPrompt)"

		let raw = try await AITransform.transform(
			instruction: userMessage,
			text: "",
			overrideSystemPrompt: system
		)
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

		if let extracted = extractTransform(from: trimmed) {
			return .transform(instruction: extracted)
		}
		return .answer(reply: stripAnswerLabel(trimmed))
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
