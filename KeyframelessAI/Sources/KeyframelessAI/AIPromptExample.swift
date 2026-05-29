/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

public struct AIPromptExample: Sendable, Hashable {
	public let label: String
	public let value: String

	public init(label: String, value: String) {
		self.label = label
		self.value = value
	}
}

public extension AIPromptExample {
	static let stenoDefaults: [AIPromptExample] = [
		.init(label: "Translate to…", value: "Translate to "),
		.init(label: "Fix capitalization", value: "Fix capitalization and punctuation"),
		.init(label: "Strip filler words", value: "Remove filler words like uh, um, like, you know"),
		.init(label: "Make formal", value: "Rewrite in a formal tone"),
		.init(label: "Expand contractions", value: "Expand all contractions (don't → do not)"),
	]
}
