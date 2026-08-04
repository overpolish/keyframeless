/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

public struct AIKnowledgeTopic: Sendable, Identifiable {
	public let id: String
	public let summary: String
	public let content: String

	public init(id: String, summary: String, content: String) {
		self.id = id
		self.summary = summary
		self.content = content
	}
}

public protocol AIKnowledgeProvider: Sendable {
	/// Display name for the source (e.g. "Keyframeless X", "Canvas plugin").
	/// Used to namespace topic IDs in the LLM prompt.
	var name: String { get }
	func topics() async -> [AIKnowledgeTopic]
}

@MainActor
public final class AIKnowledgeRegistry {
	public static let shared = AIKnowledgeRegistry()
	/// Local inference pays for every prompt token before it can emit the first
	/// word. Keep individual retrieval units small enough that one unusually large
	/// manual (for example Mirage's directives reference) cannot stall the model.
	nonisolated static let retrievalChunkCharacterLimit = 4_000
	nonisolated static let retrievalContextCharacterLimit = 10_000

	private var providers: [any AIKnowledgeProvider] = []

	private init() {}

	public func register(_ provider: any AIKnowledgeProvider) {
		guard !providers.contains(where: { $0.name == provider.name }) else { return }
		providers.append(provider)
	}

	public func allEntries() async -> [(source: String, topic: AIKnowledgeTopic)] {
		var result: [(source: String, topic: AIKnowledgeTopic)] = []
		for provider in providers {
			let topics = await provider.topics()
			for topic in topics {
				result.append((source: provider.name, topic: topic))
			}
		}
		return result
	}

	/// The documentation chunks most relevant to `prompt`, capped by both count and
	/// total characters. Dumping the whole knowledge base into a local model's
	/// prompt is the single biggest cost on
	/// device: a ~10k-token context takes ~70s to prefill for a one-line answer,
	/// while decode itself runs at 30+ tok/s. Large markdown topics are split on
	/// headings and, when needed, paragraphs before scoring. This matters because a
	/// count limit alone is meaningless when one topic can contain 80k characters.
	/// Matches in the short, representative id/summary/heading outweigh body
	/// matches. Falls back to the first chunks when the prompt shares no terms (e.g.
	/// "what does this do") so a general question still gets some context.
	public func relevantEntries(
		to prompt: String, limit: Int, topicIDs: Set<String>? = nil,
		characterBudget: Int = 10_000
	) async -> [(source: String, topic: AIKnowledgeTopic)] {
		let raw = await allEntries().filter { entry in
			guard let topicIDs else { return true }
			return topicIDs.contains(entry.topic.id)
		}
		let all = raw.flatMap(Self.retrievalChunks)
		let terms = Self.queryTerms(prompt)
		func score(_ e: (source: String, topic: AIKnowledgeTopic)) -> Int {
			let head = (e.source + " " + e.topic.id + " " + e.topic.summary).lowercased()
			let body = e.topic.content.lowercased()
			var s = 0
			for t in terms {
				if head.contains(t) { s += 6 }
				if body.contains(t) { s += 1 }
			}
			return s
		}
		var ranked:
			[(
				index: Int, entry: (source: String, topic: AIKnowledgeTopic), score: Int
			)] = []
		for (index, entry) in all.enumerated() {
			ranked.append((index: index, entry: entry, score: score(entry)))
		}
		ranked.sort { lhs, rhs in
			lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score
		}
		let hits = terms.isEmpty ? all : ranked.filter { $0.score > 0 }.map { $0.entry }
		let candidates = hits.isEmpty ? all : hits

		var result: [(source: String, topic: AIKnowledgeTopic)] = []
		var used = 0
		for entry in candidates where result.count < max(0, limit) {
			let size = entry.topic.content.count
			guard used + size <= max(0, characterBudget) else { continue }
			result.append(entry)
			used += size
		}
		return result
	}

	/// Convert a markdown topic into retrieval-sized, heading-aware chunks. Small
	/// topics remain byte-for-byte intact. Continuation chunks repeat their heading
	/// breadcrumb so they still make sense after being retrieved independently.
	static func retrievalChunks(
		_ entry: (source: String, topic: AIKnowledgeTopic)
	) -> [(source: String, topic: AIKnowledgeTopic)] {
		guard entry.topic.content.count > retrievalChunkCharacterLimit else { return [entry] }

		var headings: [String] = []
		var sectionLines: [String] = []
		var sectionBreadcrumb = ""
		var sections: [(breadcrumb: String, text: String)] = []
		var inFence = false

		func flushSection() {
			let text = sectionLines.joined(separator: "\n")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			if !text.isEmpty { sections.append((sectionBreadcrumb, text)) }
			sectionLines.removeAll(keepingCapacity: true)
		}

		for lineSub in entry.topic.content.split(separator: "\n", omittingEmptySubsequences: false)
		{
			let line = String(lineSub)
			let trimmed = line.trimmingCharacters(in: .whitespaces)
			if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
				inFence.toggle()
				sectionLines.append(line)
				continue
			}
			if !inFence, let heading = Self.markdownHeading(trimmed) {
				flushSection()
				if headings.count >= heading.level {
					headings.removeSubrange((heading.level - 1)..<headings.count)
				}
				while headings.count < heading.level - 1 { headings.append("") }
				headings.append(heading.title)
				sectionBreadcrumb = headings.filter { !$0.isEmpty }.joined(separator: " > ")
			}
			sectionLines.append(line)
		}
		flushSection()

		var output: [(source: String, topic: AIKnowledgeTopic)] = []
		var ordinal = 0
		for section in sections {
			for piece in Self.splitForRetrieval(section.text, breadcrumb: section.breadcrumb) {
				ordinal += 1
				let detail = section.breadcrumb.isEmpty ? "part \(ordinal)" : section.breadcrumb
				output.append(
					(
						source: entry.source,
						topic: AIKnowledgeTopic(
							id: "\(entry.topic.id)#\(ordinal)",
							summary: "\(entry.topic.summary) — \(detail)",
							content: piece)
					))
			}
		}
		return output.isEmpty ? [entry] : output
	}

	private static func markdownHeading(_ line: String) -> (level: Int, title: String)? {
		let hashes = line.prefix { $0 == "#" }.count
		guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
		let title = line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
		return title.isEmpty ? nil : (hashes, title)
	}

	private static func splitForRetrieval(_ text: String, breadcrumb: String) -> [String] {
		let prefix = breadcrumb.isEmpty ? "" : "Context: \(breadcrumb)\n\n"
		let payloadLimit = max(500, retrievalChunkCharacterLimit - prefix.count)
		let paragraphs = text.components(separatedBy: "\n\n")
		var pieces: [String] = []
		var current = ""

		func flush() {
			let body = current.trimmingCharacters(in: .whitespacesAndNewlines)
			if !body.isEmpty { pieces.append(prefix + body) }
			current = ""
		}

		for paragraph in paragraphs {
			if paragraph.count > payloadLimit {
				flush()
				var remainder = paragraph[...]
				while !remainder.isEmpty {
					let end = remainder.index(
						remainder.startIndex, offsetBy: min(payloadLimit, remainder.count))
					pieces.append(prefix + String(remainder[..<end]))
					remainder = remainder[end...]
				}
				continue
			}
			let separator = current.isEmpty ? "" : "\n\n"
			if current.count + separator.count + paragraph.count > payloadLimit { flush() }
			current += (current.isEmpty ? "" : "\n\n") + paragraph
		}
		flush()
		return pieces
	}

	private static func queryTerms(_ s: String) -> [String] {
		let stop: Set<String> = [
			"the", "and", "are", "for", "does", "what", "how", "why", "this", "that",
			"with", "can", "you", "your", "its", "has", "have", "will", "when", "where",
		]
		return Set(
			s.lowercased()
				.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
				.map(String.init)
				.filter { $0.count > 2 && !stop.contains($0) }
		).sorted()
	}
}
