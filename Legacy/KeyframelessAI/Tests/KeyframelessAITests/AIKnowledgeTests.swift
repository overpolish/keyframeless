/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import XCTest

@testable import KeyframelessAI

final class AIKnowledgeTests: XCTestCase {
	@MainActor
	func testLargeTopicIsSplitOnHeadingsUnderChunkLimit() {
		let body = """
			# Controls

			\(String(repeating: "General control details. ", count: 260))

			## Opacity

			\(String(repeating: "Opacity changes transparency. ", count: 220))
			"""
		let entry = (
			source: "Test",
			topic: AIKnowledgeTopic(id: "large", summary: "Large reference", content: body)
		)

		let chunks = AIKnowledgeRegistry.retrievalChunks(entry)

		XCTAssertGreaterThan(chunks.count, 1)
		XCTAssertTrue(
			chunks.allSatisfy {
				$0.topic.content.count <= AIKnowledgeRegistry.retrievalChunkCharacterLimit
			})
		XCTAssertTrue(chunks.contains { $0.topic.summary.contains("Controls > Opacity") })
	}

	@MainActor
	func testRelevantRetrievalFindsMatchingSectionWithinBudget() async {
		let id = "large-\(UUID().uuidString)"
		let body = """
			# Unrelated setup

			\(String(repeating: "Installation and browser details. ", count: 220))

			# Glow

			## Opacity

			The opacity control changes the strength of the glow without changing its radius.

			\(String(repeating: "Glow feather information. ", count: 180))
			"""
		AIKnowledgeRegistry.shared.register(
			TestKnowledgeProvider(
				name: id,
				topic: AIKnowledgeTopic(id: id, summary: "Test manual", content: body)))

		let results = await AIKnowledgeRegistry.shared.relevantEntries(
			to: "How do I change glow opacity?", limit: 4, topicIDs: [id])

		XCTAssertFalse(results.isEmpty)
		XCTAssertTrue(results[0].topic.summary.contains("Glow > Opacity"))
		XCTAssertLessThanOrEqual(
			results.reduce(0) { $0 + $1.topic.content.count },
			AIKnowledgeRegistry.retrievalContextCharacterLimit)
	}
}

private struct TestKnowledgeProvider: AIKnowledgeProvider {
	let name: String
	let topic: AIKnowledgeTopic

	func topics() async -> [AIKnowledgeTopic] { [topic] }
}
