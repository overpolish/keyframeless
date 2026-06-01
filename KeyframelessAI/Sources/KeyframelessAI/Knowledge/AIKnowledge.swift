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
}
