/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

enum AppTab: CaseIterable {
	case audio

	var label: String {
		switch self {
		case .audio: "Audio"
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
