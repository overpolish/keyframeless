/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

enum AppTab: CaseIterable {
	case captions
	case other

	var label: String {
		switch self {
		case .captions: "Captions"
		case .other: "Other"
		}
	}

	var icon: String {
		switch self {
		case .captions: "globe"
		case .other: "sparkles"
		}
	}

	var isEnabled: Bool {
		switch self {
		case .captions: true
		case .other: true
		}
	}
}
