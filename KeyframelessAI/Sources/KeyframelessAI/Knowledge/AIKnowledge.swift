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

	/// The topics most relevant to `prompt`, capped at `limit`. Dumping the WHOLE
	/// knowledge base into a local model's prompt is the single biggest cost on
	/// device: a ~10k-token context takes ~70s to prefill for a one-line answer,
	/// while decode itself runs at 30+ tok/s. Cheap lexical scoring (word overlap,
	/// no embeddings) keeps only the handful of topics that actually match, so the
	/// prompt drops to ~1-2k tokens. Matches in the short, representative
	/// id/summary outweigh body matches. Falls back to the first `limit` entries
	/// when the prompt shares no terms (e.g. "what does this do") so a general
	/// question still gets some context.
	public func relevantEntries(
		to prompt: String, limit: Int
	) async -> [(source: String, topic: AIKnowledgeTopic)] {
		let all = await allEntries()
		let terms = Self.queryTerms(prompt)
		guard !terms.isEmpty, all.count > limit else { return Array(all.prefix(limit)) }
		func score(_ e: (source: String, topic: AIKnowledgeTopic)) -> Int {
			let head = (e.topic.id + " " + e.topic.summary).lowercased()
			let body = e.topic.content.lowercased()
			var s = 0
			for t in terms {
				if head.contains(t) { s += 3 }
				if body.contains(t) { s += 1 }
			}
			return s
		}
		let ranked = all.map { (entry: $0, score: score($0)) }
			.sorted { $0.score > $1.score }
		let hits = ranked.filter { $0.score > 0 }.map { $0.entry }
		return hits.isEmpty ? Array(all.prefix(limit)) : Array(hits.prefix(limit))
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
