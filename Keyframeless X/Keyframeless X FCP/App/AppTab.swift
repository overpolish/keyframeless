/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

enum AppTab: CaseIterable {
	case audio

	var label: String {
		switch self {
		case .audio: String(localized: "Steno")
		}
	}

	var icon: String {
		switch self {
		case .audio: "waveform"
		}
	}

	var isEnabled: Bool {
		switch self {
		case .audio: true
		}
	}
}
