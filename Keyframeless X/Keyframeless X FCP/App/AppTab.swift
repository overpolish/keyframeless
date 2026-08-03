/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

enum AppTab: String, CaseIterable, Codable {
	case audio
	case sonar

	var label: String {
		switch self {
		case .audio: String(localized: "Steno")
		case .sonar: String(localized: "Sonar")
		}
	}

	var icon: String {
		switch self {
		case .audio: "waveform"
		case .sonar: "dot.radiowaves.left.and.right"
		}
	}

	var isEnabled: Bool {
		switch self {
		case .audio: true
		case .sonar: true
		}
	}
}
