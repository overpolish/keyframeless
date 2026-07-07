/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

enum CaptionImportType: String, Codable, CaseIterable, Identifiable {
	case title
	case subtitles
	case caption

	var id: String { rawValue }
}

enum CaptionFormat: String, Codable, CaseIterable, Identifiable {
	case itt
	case srt
	case cea608

	var id: String { rawValue }

	var label: String {
		switch self {
		case .itt: return "iTT"
		case .srt: return "SRT"
		case .cea608: return "CEA-608"
		}
	}

	/// FCPXML caption role. Must be the full `<token>?captionFormat=<token>.<language>` form
	/// with the EXACT casing/punctuation FCP uses for its built-in caption-format roles
	/// (`iTT`, `SRT`, `CEA-608` per FFRoleCaptionFormatShortName_*); the short `iTT.en` form or
	/// the wrong casing (`ITT`, `CEA608`) makes FCP create a duplicate plain role instead of
	/// reusing the built-in caption-format role (which also breaks rendering / makes the
	/// import-side AVF validator emit stricter spacing than the paste-side validator).
	func role(language: String) -> String {
		"\(roleToken)?captionFormat=\(captionFormatToken).\(language)"
	}

	private var roleToken: String {
		switch self {
		case .itt: return "iTT"
		case .srt: return "SRT"
		case .cea608: return "CEA-608"
		}
	}

	/// `captionFormat=` value in the FCPXML role string. FCP's own FCPXML export uses a
	/// suffix WITHOUT the dash for CEA-608 (verified against a roundtrip export), even
	/// though the role-token prefix keeps the dash. Mirror FCP's exact form so the
	/// import-side validator accepts the captions cleanly.
	private var captionFormatToken: String {
		switch self {
		case .itt: return "iTT"
		case .srt: return "SRT"
		case .cea608: return "CEA608"
		}
	}

	/// Library-stable caption-format role UID used by the native proFFPasteboard paste/drag.
	/// FCP recreates the matching caption-format role from this UID (it survives role deletion).
	var pasteboardRoleUID: String {
		switch self {
		case .itt: return "C6sjHp6VtTbaskVYqCwDIDg"
		case .srt: return "CwZ0GCFaCTF+IQUGtfR7STg"
		case .cea608: return "CZ+RKRCgpTtONojdJNN964w"
		}
	}

	var pcClassName: String {
		switch self {
		case .itt: return "PCMutableCaptioniTT"
		case .srt: return "PCMutableCaptionSRT"
		case .cea608: return "PCCaptionCEA608"
		}
	}

	var pcClassChain: [String] {
		switch self {
		case .itt: return ["PCMutableCaptioniTT", "PCCaptioniTT", "PCCaption", "NSObject"]
		case .srt: return ["PCMutableCaptionSRT", "PCCaptionSRT", "PCCaption", "NSObject"]
		case .cea608: return ["PCCaptionCEA608", "PCCaption", "NSObject"]
		}
	}

	var pcFormatNumber: Int {
		switch self {
		case .itt: return 2
		case .srt: return 3
		case .cea608: return 1
		}
	}
}
