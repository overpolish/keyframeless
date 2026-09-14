/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

enum Framerate: String, CaseIterable, Identifiable, Codable {
	case fps2398 = "1001/24000s"
	case fps24 = "100/2400s"
	case fps25 = "100/2500s"
	case fps2997 = "1001/30000s"
	case fps30 = "100/3000s"
	case fps50 = "100/5000s"
	case fps5994 = "1001/60000s"
	case fps60 = "100/6000s"
	case fps120 = "100/12000s"

	var id: String { rawValue }

	var label: String {
		switch self {
		case .fps2398: return "23.98 fps"
		case .fps24: return "24 fps"
		case .fps25: return "25 fps"
		case .fps2997: return "29.97 fps"
		case .fps30: return "30 fps"
		case .fps50: return "50 fps"
		case .fps5994: return "59.94 fps"
		case .fps60: return "60 fps"
		case .fps120: return "120 fps"
		}
	}

	static func from(frameDuration: String) -> Framerate {
		allCases.first { $0.rawValue == frameDuration } ?? .fps30
	}
}
