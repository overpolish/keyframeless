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
	/// Which scheme `contentHash` was built with; see
	/// `SonarSourceStore.identityVersion`. Nil means the original
	/// absolute-path scheme. Optional for the same reason as `contentHash`.
	var identityVersion: Int?
	/// Portable key of every clip in the selection, sorted.
	///
	/// This is the only record of *what was published*. `contentHash` is
	/// one-way, so without these a republish - here or on another Mac - can't
	/// know which clips to select, and the user is left guessing at the picks
	/// they made weeks ago. Optional because it postdates the format; nil just
	/// means the selection can't be restored, not that the source is invalid.
	var clipKeys: [String]?
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

	/// Scheme behind a source's `contentHash`. Version 2 hashes portable clip
	/// identity; version 1 (nil) hashed absolute paths.
	///
	/// Bumping this invalidates every existing binding by definition - a shader
	/// looks a source up by a hash of its `contentHash`, so one hashed the old
	/// way can never be found again. Older entries are therefore dropped rather
	/// than left sitting in the list looking publishable while matching nothing,
	/// which would also make a republish collide with its own ghost and land as
	/// "Music 2" beside it.
	static let identityVersion = 2

	static func url(for id: String) -> URL? {
		directory?.appendingPathComponent("\(id).kksg")
	}

	/// Published sources, newest first. Reading the manifest means a plugin can
	/// populate a menu without opening and parsing every float grid.
	static func sources() -> [SonarSource] {
		guard let manifestURL, let data = try? Data(contentsOf: manifestURL),
			let list = try? JSONDecoder().decode([SonarSource].self, from: data)
		else { return [] }
		let current = list.filter { $0.identityVersion == identityVersion }
		if current.count != list.count {
			purge(list, keeping: current, manifestURL: manifestURL)
		}
		return current.sorted { $0.publishedAt > $1.publishedAt }
	}

	/// Drops sources from a superseded identity scheme, grid and all. Runs off
	/// the first read that sees one and then never again, since the rewritten
	/// manifest has none left.
	private static func purge(
		_ all: [SonarSource], keeping current: [SonarSource], manifestURL: URL
	) {
		let keep = Set(current.map(\.id))
		for source in all where !keep.contains(source.id) {
			if let url = url(for: source.id) { try? FileManager.default.removeItem(at: url) }
		}
		guard let data = try? JSONEncoder().encode(current) else { return }
		try? data.write(to: manifestURL, options: .atomic)
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
			contentHash: hash,
			identityVersion: identityVersion,
			clipKeys: clipKeys(for: clips)
		)
		var list = sources().filter { $0.id != source.id }
		list.append(source)
		let encoder = JSONEncoder()
		encoder.outputFormatting = .prettyPrinted
		try encoder.encode(list).write(to: manifestURL, options: .atomic)
		return source
	}

	/// Identity of a selection: the same clips with the same edits, in any order,
	/// hash the same. Re-publishing after a volume tweak counts as new content
	/// and refreshes rather than duplicating.
	///
	/// Deliberately the PORTABLE fingerprint, not the local one. A shader binds
	/// to a hash of this, so keying it on absolute paths would mean a project
	/// carried to another Mac could never reconnect: the media resolves
	/// elsewhere, every hash shifts, and republishing the same clips mints a
	/// source the shader has never heard of. Filenames travel; paths don't.
	static func contentHash(for clips: [FCPXMLParser.AudioClip]) -> String {
		hash36(clips.map(AudioClipFingerprint.identity).sorted().joined(separator: "\n"))
	}

	/// Portable key for each clip in the selection, sorted.
	///
	/// Hashed rather than stored whole: the identity string carries the file
	/// name plus every edit, and a ticket holding fifty of them verbatim would
	/// ride around inside the FCP library forever. Sorted so the same selection
	/// always writes the same manifest.
	static func clipKeys(for clips: [FCPXMLParser.AudioClip]) -> [String] {
		clips.map(clipKey(for:)).sorted()
	}

	/// One clip's portable key. The same clip on another Mac hashes the same,
	/// which is what lets a republish there rebuild the identical selection.
	static func clipKey(for clip: FCPXMLParser.AudioClip) -> String {
		hash36(AudioClipFingerprint.identity(clip))
	}

	/// djb2 over UTF-8, base 36.
	///
	/// Hand-rolled on purpose: `Hasher` is seeded per process, so it gives a
	/// different answer on every launch. These hashes are written to disk and
	/// compared across machines, which needs a function that is stable
	/// everywhere and forever. Changing it silently invalidates every published
	/// source and every shader bound to one, so it is versioned by
	/// `identityVersion`.
	private static func hash36(_ string: String) -> String {
		var hash: UInt64 = 5381
		for byte in string.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
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
			publishedAt: old.publishedAt, contentHash: old.contentHash,
			identityVersion: old.identityVersion, clipKeys: old.clipKeys)
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
		if out.isEmpty { return "source-\(hash36(name))" }
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
