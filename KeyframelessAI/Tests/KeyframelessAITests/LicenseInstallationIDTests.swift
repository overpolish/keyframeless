/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import XCTest

@testable import KeyframelessAI

final class LicenseInstallationIDTests: XCTestCase {
	func testIdentityPersistsAcrossReads() throws {
		let container = try temporaryContainer()
		defer { try? FileManager.default.removeItem(at: container) }

		let first = try XCTUnwrap(LicenseInstallationID.loadOrCreate(in: container))
		let second = try XCTUnwrap(LicenseInstallationID.loadOrCreate(in: container))

		XCTAssertEqual(first, second)
		XCTAssertNotNil(UUID(uuidString: first))
	}

	func testConcurrentCreationConvergesOnOneIdentity() throws {
		let container = try temporaryContainer()
		defer { try? FileManager.default.removeItem(at: container) }

		let lock = NSLock()
		var values: [String] = []
		DispatchQueue.concurrentPerform(iterations: 24) { _ in
			if let value = LicenseInstallationID.loadOrCreate(in: container) {
				lock.lock()
				values.append(value)
				lock.unlock()
			}
		}

		XCTAssertEqual(values.count, 24)
		XCTAssertEqual(Set(values).count, 1)
	}

	func testCorruptIdentityIsReplacedUnderLock() throws {
		let container = try temporaryContainer()
		defer { try? FileManager.default.removeItem(at: container) }
		let directory = container.appendingPathComponent(
			LicenseInstallationID.directoryName, isDirectory: true)
		try FileManager.default.createDirectory(
			at: directory, withIntermediateDirectories: true)
		try Data("not-a-uuid\n".utf8).write(
			to: directory.appendingPathComponent(LicenseInstallationID.fileName))

		let identity = try XCTUnwrap(LicenseInstallationID.loadOrCreate(in: container))

		XCTAssertNotNil(UUID(uuidString: identity))
	}

	private func temporaryContainer() throws -> URL {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("LicenseInstallationIDTests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(
			at: root, withIntermediateDirectories: true)
		return root
	}
}
