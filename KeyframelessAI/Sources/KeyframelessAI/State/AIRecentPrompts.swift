/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation

@MainActor
public final class AIRecentPrompts: ObservableObject {
	public static let shared = AIRecentPrompts()

	@Published public private(set) var prompts: [String] = []

	private static let key = "com.overpolish.ai.recentPrompts"
	private static let maxCount = 5

	private init() {
		prompts = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
	}

	public func record(_ prompt: String) {
		let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return }
		var next = prompts.filter { $0 != trimmed }
		next.insert(trimmed, at: 0)
		if next.count > Self.maxCount { next.removeLast(next.count - Self.maxCount) }
		prompts = next
		UserDefaults.standard.set(prompts, forKey: Self.key)
	}

	public func clear() {
		prompts = []
		UserDefaults.standard.removeObject(forKey: Self.key)
	}
}
