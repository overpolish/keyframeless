/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Describes a dropped template whose bundled media couldn't be resolved,
/// pending the user's "Import without image" / "Cancel" decision.
struct MissingMediaInfo: Identifiable {
	let id = UUID()
	let sourceURL: URL
	let templateName: String
	let missing: [String]
}

/// Installs a dropped `.moti` title into the Motion Templates library.
///
/// A loose `.moti` (e.g. sitting in ~/Downloads) referenced in place makes Final
/// Cut Pro consolidate a title that isn't in a valid
/// `Titles.localized/<Theme>/<Name>/<Name>.moti` structure, which aborts inside
/// `+[FFMotionEffect createIntermediateDirectoriesInDestContainingFolderURL:sourceContainingFolderURL:]`.
/// Copying the template into the canonical location first avoids that.
enum CustomTemplateInstaller {

	enum Result {
		/// Installed cleanly; the URL is the canonical `.moti` inside the library.
		case installed(URL)
		/// The template references bundled media that doesn't resolve on disk.
		/// The author shipped an incomplete template. The array holds the missing
		/// relative paths (e.g. `Media/Foo.png`) for display.
		case missingMedia([String])
		/// A filesystem or parse failure. The string is user-facing.
		case failed(String)
	}

	/// Deliberately NOT "Keyframeless": that folder is scanned by
	/// `CaptionTemplateScanner` and would double-list every drop (once as a
	/// scanned title, once via `CustomTemplateStore`). Custom drops live in their
	/// own theme folder so they stay owned by `CustomTemplateStore` alone.
	static let category = "Keyframeless Custom"

	static let installBase: URL = {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(
				"Movies/Motion Templates.localized/Titles.localized/\(category)")
	}()

	private static let motionTemplatesBase: String = {
		(FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Movies/Motion Templates.localized")
			.standardizedFileURL.path as NSString).resolvingSymlinksInPath
	}()

	/// Returns `true` if `url` already lives inside the Motion Templates library.
	static func isAlreadyInstalled(_ url: URL) -> Bool {
		let path = (url.standardizedFileURL.path as NSString).resolvingSymlinksInPath
		return path.hasPrefix(motionTemplatesBase + "/")
	}

	/// Relative media paths referenced by the `.moti` that don't exist next to it.
	static func unresolvedMedia(in motiURL: URL) -> [String] {
		guard let data = try? Data(contentsOf: motiURL, options: .mappedIfSafe),
			let content = String(data: data, encoding: .utf8)
		else { return [] }

		let sourceDir = motiURL.deletingLastPathComponent()
		let pattern = "<relativeURL>([^<]+)</relativeURL>"
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

		var missing: [String] = []
		let matches = regex.matches(
			in: content, range: NSRange(content.startIndex..., in: content))
		for match in matches {
			let encoded = (content as NSString).substring(with: match.range(at: 1))
			let relative = encoded.removingPercentEncoding ?? encoded
			let resolved = sourceDir.appendingPathComponent(relative)
			if !FileManager.default.fileExists(atPath: resolved.path) {
				missing.append(relative)
			}
		}
		return missing
	}

	/// Installs a copy of the template with every unresolved `<relativeURL>` media
	/// pointer deleted. The clip stays (Motion already flags it `<missing…>`), but
	/// with no external path FCP has nothing to consolidate, so it can't abort.
	/// This is the "Import without image" path: the missing image simply won't
	/// render. Deleting only the leaf `<relativeURL>` avoids dangling
	/// `Source Media` references that removing the whole footage would create.
	static func installStrippingMedia(from url: URL) -> Result {
		guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
			let content = String(data: data, encoding: .utf8)
		else { return .failed(String(localized: "Couldn't read the template file.")) }

		let sourceDir = url.deletingLastPathComponent()
		let pattern = "[\\t ]*<relativeURL>([^<]+)</relativeURL>\\n?"
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			return .failed(String(localized: "Couldn't process the template file."))
		}

		let ns = content as NSString
		let stripped = NSMutableString(string: content)
		let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
		for match in matches.reversed() {
			let encoded = ns.substring(with: match.range(at: 1))
			let relative = encoded.removingPercentEncoding ?? encoded
			let resolved = sourceDir.appendingPathComponent(relative)
			guard !FileManager.default.fileExists(atPath: resolved.path) else { continue }
			stripped.deleteCharacters(in: match.range)
		}

		let name = url.deletingPathExtension().lastPathComponent
		let destDir = installBase.appendingPathComponent(name)
		let destMoti = destDir.appendingPathComponent("\(name).moti")
		let fm = FileManager.default
		do {
			try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
			if fm.fileExists(atPath: destMoti.path) {
				try fm.removeItem(at: destMoti)
			}
			try (stripped as String).write(to: destMoti, atomically: true, encoding: .utf8)
			try copySiblings(from: sourceDir, to: destDir)
		} catch {
			return .failed(error.localizedDescription)
		}
		return .installed(destMoti)
	}

	static func install(from url: URL) -> Result {
		// Already in the library: nothing to copy, reference as-is.
		if isAlreadyInstalled(url) {
			let missing = unresolvedMedia(in: url)
			return missing.isEmpty ? .installed(url) : .missingMedia(missing)
		}

		let missing = unresolvedMedia(in: url)
		guard missing.isEmpty else { return .missingMedia(missing) }

		let name = url.deletingPathExtension().lastPathComponent
		let sourceDir = url.deletingLastPathComponent()
		let destDir = installBase.appendingPathComponent(name)
		let destMoti = destDir.appendingPathComponent("\(name).moti")
		let fm = FileManager.default

		do {
			try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

			if fm.fileExists(atPath: destMoti.path) {
				try fm.removeItem(at: destMoti)
			}
			try fm.copyItem(at: url, to: destMoti)
			try copySiblings(from: sourceDir, to: destDir)
		} catch {
			return .failed(error.localizedDescription)
		}

		return .installed(destMoti)
	}

	/// Carry sibling assets FCP / the scanner expect alongside the template.
	private static func copySiblings(from sourceDir: URL, to destDir: URL) throws {
		let fm = FileManager.default
		for sibling in ["Media", "large.png", "small.png", "preview.gif", "author.txt"] {
			let src = sourceDir.appendingPathComponent(sibling)
			guard fm.fileExists(atPath: src.path) else { continue }
			let dst = destDir.appendingPathComponent(sibling)
			if fm.fileExists(atPath: dst.path) {
				try fm.removeItem(at: dst)
			}
			try fm.copyItem(at: src, to: dst)
		}
	}
}
