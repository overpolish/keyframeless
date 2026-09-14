/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import SwiftUI

public struct AIProviderLogo: View {
	public let provider: AIProvider

	public init(provider: AIProvider) {
		self.provider = provider
	}

	public var body: some View {
		// The local provider has no brand asset; render an SF Symbol instead of
		// a bundled template image.
		if provider == .local {
			Image(systemName: "desktopcomputer")
				.resizable()
				.scaledToFit()
				.foregroundStyle(.primary)
		} else {
			Image(imageName, bundle: .module)
				.resizable()
				.renderingMode(.template)
				.scaledToFit()
				.foregroundStyle(.primary)
		}
	}

	private var imageName: String {
		switch provider {
		case .anthropic: return "logo-anthropic"
		case .openai: return "logo-openai"
		case .local: return ""
		}
	}
}
