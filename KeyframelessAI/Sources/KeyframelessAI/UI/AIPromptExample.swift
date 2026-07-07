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

extension AIPromptExample {
	public static let stenoDefaults: [AIPromptExample] = [
		.init(label: AILoc("Translate to…"), value: AILoc("Translate into ")),
		.init(
			label: AILoc("Fix capitalization"), value: AILoc("Fix capitalization and punctuation")),
		.init(
			label: AILoc("Strip filler words"),
			value: AILoc("Remove filler words like uh, um, like, you know")),
		.init(label: AILoc("Make formal"), value: AILoc("Rewrite in a formal tone")),
		.init(
			label: AILoc("Expand contractions"),
			value: AILoc("Expand all contractions (don't → do not)")),
	]
}
