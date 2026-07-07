/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import Foundation
import ProExtensionHost

enum FCPHost {
	static var shared: FCPXHost {
		ProExtensionHostSingleton() as! FCPXHost
	}

	/// Host FCP version as (major, minor), parsed from the host's version string
	/// (e.g. "12.3" or "12.3.1"). nil when the host isn't ready yet — `versionString` is an
	/// implicitly-unwrapped ObjC `String!` that is nil early in launch, so bind it through an
	/// Optional (never force-unwrap) before splitting.
	static var version: (major: Int, minor: Int)? {
		guard let host = ProExtensionHostSingleton() as? FCPXHost else { return nil }
		let raw: String? = host.versionString
		guard let versionString = raw else { return nil }
		let parts = versionString.split(separator: ".").prefix(2).compactMap {
			Int($0.prefix(while: \.isNumber))
		}
		guard let major = parts.first else { return nil }
		return (major, parts.count > 1 ? parts[1] : 0)
	}

	static func versionAtLeast(major: Int, minor: Int) -> Bool {
		guard let v = version else { return false }
		return v.major > major || (v.major == major && v.minor >= minor)
	}

	/// The bundled Subtitle.moti inside the host FCP app, resolved via the running
	/// FCP bundle (not a hard-coded /Applications path). nil if FCP isn't found or the
	/// template doesn't exist (older FCP without the Subtitles feature).
	static var bundledSubtitleMotiURL: URL? {
		guard
			let fcp = NSWorkspace.shared.urlForApplication(
				withBundleIdentifier: "com.apple.FinalCut")
		else { return nil }
		let url = fcp.appendingPathComponent(
			"Contents/PlugIns/MediaProviders/MotionEffect.fxp/Contents/Resources/METemplates.localized/Titles.localized/Subtitles.localized/Subtitle.localized/Subtitle.moti"
		)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	/// FCP 12.3 introduced the native Subtitles title. Gate the Steno option on both the
	/// host version AND the template's presence so only users who can actually render it
	/// see it.
	static var supportsSubtitles: Bool {
		versionAtLeast(major: 12, minor: 3) && bundledSubtitleMotiURL != nil
	}
}
