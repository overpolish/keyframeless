/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

public struct LicenseRecord: Equatable {
	public let licenseKey: String
	public let buyerEmail: String?
	public let activatedAt: Date
}

public enum LicenseError: LocalizedError {
	case invalidKey
	case disabled
	case network(String)
	case unexpected(Int)

	public var errorDescription: String? {
		switch self {
		case .invalidKey:
			return AILoc("License key not recognized. Check it matches your receipt.")
		case .disabled:
			return AILoc("This license key has been disabled.")
		case .network(let msg):
			return String(format: AILoc("Network error: %@"), msg)
		case .unexpected(let code):
			return String(format: AILoc("Unexpected response (HTTP %d)"), code)
		}
	}
}

/// Product IDs matching KeyframelessKit's `KKLicenseProduct*` constants.
public enum LicenseProduct {
	public static let mirage = "mirage"
	public static let canvas = "canvas"
	public static let steno = "steno"
}

/// One-time Payhip license activation. A key is verified once against the
/// Payhip v2 license API and the result is persisted to the shared app-group
/// defaults suite, where every Keyframeless process (inspector ViewBridge,
/// plugin XPC, workflow extension) can read it. There is no re-verification
/// and no phone-home after activation.
///
/// KeyframelessKit reads the same suite key from ObjC via
/// `KKLicenseIsActivated()` to gate render watermarks; keep the storage
/// format in sync with KKLicense.m.
public enum LicenseManager {
	static let suiteName = "group.co.overpolish.keyframeless"

	static func defaultsKey(for productID: String) -> String {
		"co.overpolish.license.\(productID)"
	}

	public static func record(for productID: String) -> LicenseRecord? {
		guard let defaults = UserDefaults(suiteName: suiteName),
			let dict = defaults.dictionary(forKey: defaultsKey(for: productID)),
			let key = dict["key"] as? String, !key.isEmpty
		else { return nil }
		let date = (dict["date"] as? TimeInterval).map(
			Date.init(timeIntervalSince1970:))
		return LicenseRecord(
			licenseKey: key,
			buyerEmail: dict["email"] as? String,
			activatedAt: date ?? Date())
	}

	public static func isActivated(_ productID: String) -> Bool {
		record(for: productID) != nil
	}

	@discardableResult
	public static func activate(
		licenseKey: String, productID: String, productSecret: String
	) async throws -> LicenseRecord {
		let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw LicenseError.invalidKey }

		var components = URLComponents(
			string: "https://payhip.com/api/v2/license/verify")!
		components.queryItems = [
			URLQueryItem(name: "license_key", value: trimmed)
		]
		var request = URLRequest(url: components.url!)
		request.setValue(productSecret, forHTTPHeaderField: "product-secret-key")
		request.timeoutInterval = 15

		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await URLSession.shared.data(for: request)
		} catch {
			throw LicenseError.network(error.localizedDescription)
		}
		guard let http = response as? HTTPURLResponse else {
			throw LicenseError.unexpected(0)
		}
		switch http.statusCode {
		case 200..<300: break
		case 400..<500: throw LicenseError.invalidKey
		default: throw LicenseError.unexpected(http.statusCode)
		}

		// Payhip wraps the license object in "data" in some responses; accept
		// either shape and any of Bool/number/string for "enabled".
		let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		let payload = (root?["data"] as? [String: Any]) ?? root
		guard let payload else { throw LicenseError.invalidKey }
		let enabledRaw = payload["enabled"]
		let enabled =
			(enabledRaw as? Bool)
			?? (enabledRaw as? NSNumber)?.boolValue
			?? ((enabledRaw as? String).map { $0 == "true" || $0 == "1" })
			?? false
		guard enabled else { throw LicenseError.disabled }

		let record = LicenseRecord(
			licenseKey: trimmed,
			buyerEmail: payload["buyer_email"] as? String,
			activatedAt: Date())
		store(record, for: productID)
		return record
	}

	static func store(_ record: LicenseRecord, for productID: String) {
		guard let defaults = UserDefaults(suiteName: suiteName) else { return }
		var dict: [String: Any] = [
			"key": record.licenseKey,
			"date": record.activatedAt.timeIntervalSince1970,
		]
		if let email = record.buyerEmail { dict["email"] = email }
		defaults.set(dict, forKey: defaultsKey(for: productID))
	}
}
