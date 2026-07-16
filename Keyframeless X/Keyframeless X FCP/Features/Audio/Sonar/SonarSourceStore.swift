/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// One published analysis, as advertised to visual plugins.
///
/// The manifest carries everything mutable - clip count, duration, date - so
/// none of it is baked into the filename. That keeps the file identified by
/// project + name alone, which is what makes re-publishing the same source
/// overwrite rather than pile up a new copy every time.
struct SonarSource: Codable, Identifiable, Equatable {
	/// `<project>_<name>` slug; also the `.kksg` filename stem.
	let id: String
	var name: String
	var roles: [String]
	var clipCount: Int
	var duration: Double
	var projectName: String?
	var publishedAt: Date
	/// Fingerprint of the exact clips analysed - the source's real identity.
	///
	/// Optional because it was added after the format shipped: a non-optional
	/// field would fail to decode every manifest written before it and silently
	/// empty the list.
	var contentHash: String?
}

/// Reads and writes Sonar's published analyses in the shared app-group
/// container.
///
/// The container is the whole point: a workflow extension's own
/// `temporaryDirectory` is private to its sandbox, so a plugin in a different
/// sandbox can never see it. Both Keyframeless X and the plugins carry the
/// `group.co.overpolish.keyframeless` entitlement, which makes this directory
/// the one place both sides can reach.
enum SonarSourceStore {
	static let appGroupID = "group.co.overpolish.keyframeless"

	/// Nil without the app-group entitlement, in which case publishing is
	/// unavailable rather than silently writing somewhere unreadable.
	static var directory: URL? {
		guard
			let container = FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: appGroupID)
		else { return nil }
		let dir = container.appendingPathComponent("Sonar", isDirectory: true)
			.appendingPathComponent("Sources", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	private static var manifestURL: URL? {
		directory?.appendingPathComponent("manifest.json")
	}

	static func url(for id: String) -> URL? {
		directory?.appendingPathComponent("\(id).kksg")
	}

	/// Published sources, newest first. Reading the manifest means a plugin can
	/// populate a menu without opening and parsing every float grid.
	static func sources() -> [SonarSource] {
		guard let manifestURL, let data = try? Data(contentsOf: manifestURL),
			let list = try? JSONDecoder().decode([SonarSource].self, from: data)
		else { return [] }
		return list.sorted { $0.publishedAt > $1.publishedAt }
	}

	/// Writes the grid and records it in the manifest.
	///
	/// Identity is the CLIPS, not the name. Re-publishing the same selection
	/// refreshes it in place; publishing a different selection makes a new source
	/// even when both are "Music" - otherwise picking three music cues, then three
	/// others, would silently overwrite the first, and two shaders could never use
	/// different music.
	///
	/// The name is only a label: derived from roles for the common case, and
	/// suffixed ("Music 2") when that label is already taken by different content.
	@discardableResult
	static func publish(
		_ spectrogram: Spectrogram,
		clips: [FCPXMLParser.AudioClip],
		projectName: String?,
		timecodeStart: Double
	) throws -> SonarSource {
		let hash = contentHash(for: clips)
		let existing = sources().first {
			$0.projectName == projectName && $0.contentHash == hash
		}
		let name = existing?.name ?? uniqueName(base: derivedName(for: clips), project: projectName)
		let id = existing?.id ?? sourceID(project: projectName, name: name)
		guard let url = url(for: id), let manifestURL else {
			throw SonarSourceError.noContainer
		}
		try spectrogram.write(to: url, timecodeStart: timecodeStart)
		let source = SonarSource(
			id: id,
			name: name,
			roles: roles(for: clips),
			clipCount: clips.count,
			duration: spectrogram.duration,
			projectName: projectName,
			publishedAt: Date(),
			contentHash: hash
		)
		var list = sources().filter { $0.id != source.id }
		list.append(source)
		let encoder = JSONEncoder()
		encoder.outputFormatting = .prettyPrinted
		try encoder.encode(list).write(to: manifestURL, options: .atomic)
		return source
	}

	/// Identity of a selection: the same clips with the same edits, in any order,
	/// hash the same. Uses the clip fingerprint, so re-publishing after a volume
	/// tweak counts as new content and refreshes rather than duplicating.
	static func contentHash(for clips: [FCPXMLParser.AudioClip]) -> String {
		let joined = clips.map(AudioClipFingerprint.of).sorted().joined(separator: "\n")
		var hash: UInt64 = 5381
		for byte in joined.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
		return String(hash, radix: 36)
	}

	/// "Music", then "Music 2" - a label collision between different selections is
	/// normal, not an error.
	private static func uniqueName(base: String, project: String?) -> String {
		let taken = Set(sources().filter { $0.projectName == project }.map(\.name))
		guard taken.contains(base) else { return base }
		var n = 2
		while taken.contains("\(base) \(n)") { n += 1 }
		return "\(base) \(n)"
	}

	/// Renames a source, moving its file to match.
	///
	/// The filename is the name's slug, so leaving the file put would drift the
	/// two apart until `music.kksg` was called "Drums" - and the readable filename
	/// is the whole reason it isn't a hash. Identity travels with the content
	/// hash, so the source stays the same source.
	static func rename(_ id: String, to newName: String) {
		var list = sources()
		guard let index = list.firstIndex(where: { $0.id == id }) else { return }
		let old = list[index]
		let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != old.name else { return }
		// Suffixes against OTHER sources, so renaming onto a taken name gives
		// "Music 2" rather than two rows claiming the same file.
		let unique = uniqueName(base: trimmed, project: old.projectName)
		let newID = sourceID(project: old.projectName, name: unique)
		if let from = url(for: id), let to = url(for: newID), from != to {
			try? FileManager.default.removeItem(at: to)
			try? FileManager.default.moveItem(at: from, to: to)
		}
		list[index] = SonarSource(
			id: newID, name: unique, roles: old.roles, clipCount: old.clipCount,
			duration: old.duration, projectName: old.projectName,
			publishedAt: old.publishedAt, contentHash: old.contentHash)
		guard let manifestURL, let data = try? JSONEncoder().encode(list) else { return }
		try? data.write(to: manifestURL, options: .atomic)
	}

	static func remove(_ id: String) {
		if let url = url(for: id) { try? FileManager.default.removeItem(at: url) }
		guard let manifestURL else { return }
		let list = sources().filter { $0.id != id }
		guard let data = try? JSONEncoder().encode(list) else { return }
		try? data.write(to: manifestURL, options: .atomic)
	}

	/// Names the analysis after what's in it: pick the Music role and it's
	/// "Music". Derived rather than asked for, so publishing stays one click and
	/// naming is a correction you rarely have to make.
	static func derivedName(for clips: [FCPXMLParser.AudioClip]) -> String {
		let labels = Set(clips.compactMap { RoleColors.label(for: $0.role) }).sorted()
		if labels.isEmpty { return String(localized: "Audio") }
		if labels.count > 3 { return String(localized: "Mixed") }
		return labels.joined(separator: " + ")
	}

	static func roles(for clips: [FCPXMLParser.AudioClip]) -> [String] {
		Set(clips.compactMap(\.role)).sorted()
	}

	/// Filename stem, e.g. `my-doc_music`. The manifest holds this mapping too,
	/// but the project belongs in the name itself: without it, a "Music" in two
	/// different projects slugs to the same file and one silently overwrites the
	/// other. Scoping by project makes overwrite mean "refresh this project's
	/// Music", which is the only place it's the right behaviour.
	static func sourceID(project: String?, name: String) -> String {
		let project = project.map(slug(for:)).flatMap { $0.isEmpty ? nil : $0 } ?? "untitled"
		return "\(project)_\(slug(for: name))"
	}

	/// Slug: readable where it can be, hashed where it can't. A role
	/// named in a script with no ASCII form would slug to nothing, so it falls
	/// back to a stable hash rather than colliding on an empty string.
	static func slug(for name: String) -> String {
		let allowed = CharacterSet.alphanumerics
		var out = ""
		var lastWasDash = false
		for scalar in name.lowercased().unicodeScalars {
			if allowed.contains(scalar), scalar.isASCII {
				out.unicodeScalars.append(scalar)
				lastWasDash = false
			} else if !lastWasDash, !out.isEmpty {
				out.append("-")
				lastWasDash = true
			}
		}
		while out.hasSuffix("-") { out.removeLast() }
		if out.isEmpty {
			var hash: UInt64 = 5381
			for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
			return "source-\(String(hash, radix: 36))"
		}
		return out
	}
}

enum SonarSourceError: LocalizedError {
	case noContainer
	case emptySpectrogram

	var errorDescription: String? {
		switch self {
		case .noContainer:
			return String(
				localized: "Couldn't reach the shared container that plugins read from.")
		case .emptySpectrogram:
			return String(localized: "There's no analysis to publish.")
		}
	}
}
