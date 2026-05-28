/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Combine
import Foundation

@MainActor
public final class AIKeyState: ObservableObject {
	public static let shared = AIKeyState()

	@Published public private(set) var configuredProviders: [AIProvider] = []
	@Published public var activeProvider: AIProvider = .anthropic {
		didSet {
			UserDefaults.standard.set(activeProvider.rawValue, forKey: Self.activeKey)
		}
	}

	public var hasAnyKey: Bool { !configuredProviders.isEmpty }
	public var activeIsConfigured: Bool { configuredProviders.contains(activeProvider) }

	private static let activeKey = "com.overpolish.ai.activeProvider"

	private init() {
		let saved = UserDefaults.standard.string(forKey: Self.activeKey)
			.flatMap(AIProvider.init(rawValue:))
		activeProvider = saved ?? .anthropic
		refresh()
	}

	public func refresh() {
		configuredProviders = AIKeychain.providersWithKeys()

		if !configuredProviders.isEmpty, !configuredProviders.contains(activeProvider) {
			activeProvider = configuredProviders.first!
		}
	}
}
