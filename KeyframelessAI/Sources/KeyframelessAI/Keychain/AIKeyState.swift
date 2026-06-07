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
		// Default to Local where it's supported (Apple Silicon, >=16 GB) -
		// privacy-first, no key needed; cloud otherwise (Intel / low-RAM, where
		// Local is hidden). A saved choice always wins.
		activeProvider = saved ?? (AIPlatform.supportsLocal ? .local : .anthropic)
		refresh()
	}

	public func refresh() {
		var providers = AIKeychain.providersWithKeys()
		// The local provider has no key; it's "configured" once a model is
		// downloaded and selected. Only where local is supported (Apple Silicon,
		// >=16 GB RAM).
		if AIPlatform.supportsLocal, LocalModelStore.shared.hasReadyModel {
			providers.append(.local)
		}
		configuredProviders = providers

		// Auto-pick a configured provider only when the active one is an
		// unconfigured CLOUD provider (e.g. its key was deleted). Never bounce
		// the user off `.local`: sitting on it with no model yet is a valid
		// state - the config tab is where they download one.
		if !configuredProviders.isEmpty, activeProvider != .local,
			!configuredProviders.contains(activeProvider)
		{
			activeProvider = configuredProviders.first!
		}
	}
}
