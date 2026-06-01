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
		Image(imageName, bundle: .module)
			.resizable()
			.renderingMode(.template)
			.scaledToFit()
			.foregroundStyle(.primary)
	}

	private var imageName: String {
		switch provider {
		case .anthropic: return "logo-anthropic"
		case .openai: return "logo-openai"
		}
	}
}
