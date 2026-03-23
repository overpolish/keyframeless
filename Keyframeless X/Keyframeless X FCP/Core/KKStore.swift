/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

enum KKStore {
	static func fileURL(for filename: String) -> URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/\(filename)")
	}

	static func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
		guard let url = fileURL(for: filename),
			let data = try? Data(contentsOf: url),
			let decoded = try? JSONDecoder().decode(type, from: data)
		else { return nil }
		return decoded
	}

	static func save<T: Encodable>(_ value: T, to filename: String) {
		guard let url = fileURL(for: filename) else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(value).write(to: url, options: .atomic)
	}
}
