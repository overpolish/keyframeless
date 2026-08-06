/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Darwin
import Foundation

/// Stable, per-user installation identity shared by every Keyframeless process.
///
/// `gethostuuid` is not a suitable cross-process contract for sandboxed FxPlug
/// services and app extensions: the value observed while activating can differ
/// from the value observed by a renderer. Instead, all products coordinate on
/// one UUID file in the app-group container. A file lock makes first creation
/// deterministic even when several plugin processes launch together.
enum LicenseInstallationID {
	static let appGroupID = "group.com.keyframeless"
	static let directoryName = "License"
	static let fileName = "installation-id"
	static let lockFileName = ".installation-id.lock"

	static func current() -> String? {
		guard
			let container = FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: appGroupID)
		else { return nil }
		return loadOrCreate(in: container)
	}

	/// Separated from `current()` so the persistence and locking behavior can be
	/// exercised in SwiftPM tests, which do not carry the production app-group
	/// entitlement.
	static func loadOrCreate(
		in container: URL,
		fileManager: FileManager = .default
	) -> String? {
		let directory = container.appendingPathComponent(
			directoryName, isDirectory: true)
		do {
			try fileManager.createDirectory(
				at: directory, withIntermediateDirectories: true)
		} catch {
			return nil
		}

		let lockURL = directory.appendingPathComponent(lockFileName)
		let lockFD = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
		guard lockFD >= 0 else { return nil }
		defer { close(lockFD) }
		guard flock(lockFD, LOCK_EX) == 0 else { return nil }
		defer { flock(lockFD, LOCK_UN) }

		let identityURL = directory.appendingPathComponent(fileName)
		if let existing = read(from: identityURL) {
			return existing
		}

		let generated = UUID().uuidString
		do {
			try Data((generated + "\n").utf8).write(to: identityURL, options: .atomic)
			_ = chmod(identityURL.path, S_IRUSR | S_IWUSR)
			return generated
		} catch {
			return nil
		}
	}

	private static func read(from url: URL) -> String? {
		guard let data = try? Data(contentsOf: url),
			let raw = String(data: data, encoding: .utf8)
		else { return nil }
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		return UUID(uuidString: trimmed)?.uuidString
	}
}
