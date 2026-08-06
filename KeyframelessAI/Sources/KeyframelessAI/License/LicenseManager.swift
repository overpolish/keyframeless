/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import CryptoKit
import Foundation

public struct LicenseRecord: Equatable {
	public let licenseKey: String
	public let buyerEmail: String?
	public let activatedAt: Date
}

public enum LicenseError: LocalizedError {
	case invalidKey
	case disabled
	case storageUnavailable
	case network(String)
	case unexpected(Int)
	case untrustedResponse

	public var errorDescription: String? {
		switch self {
		case .invalidKey:
			return AILoc("License key not recognized. Check it matches your receipt.")
		case .disabled:
			return AILoc("This license key has been disabled.")
		case .storageUnavailable:
			return AILoc(
				"Activation could not access shared license storage. Reinstall the latest version and try again."
			)
		case .network(let msg):
			return String(format: AILoc("Network error: %@"), msg)
		case .unexpected(let code):
			return String(format: AILoc("Unexpected response (HTTP %d)"), code)
		case .untrustedResponse:
			return AILoc("Activation response could not be verified.")
		}
	}
}

/// Product IDs matching KeyframelessKit's `KKLicenseProduct*` constants.
public enum LicenseProduct {
	public static let mirage = "mirage"
	public static let canvas = "canvas"
	public static let steno = "steno"
}

/// One-time license activation. A key is verified once - by the activation
/// Worker, which holds the Payhip product secret so it never ships to users -
/// and the Worker returns a SIGNED record that is persisted to the shared
/// app-group defaults suite. There is no re-verification and no phone-home
/// after that: every later check is a local signature verification against a
/// public key compiled into the binary, so activation survives indefinitely
/// offline while a hand-written defaults entry fails.
///
/// KeyframelessKit verifies the same record from ObjC in `KKLicenseIsActivated()`
/// to gate render watermarks; keep this format in sync with KKLicense.m.
public enum LicenseManager {
	static let suiteName = "group.com.keyframeless"

	/// Stateless activation endpoint: verifies the key against Payhip, then
	/// signs. Holds the only copy of the private key.
	static let activationURL = URL(string: "https://license.keyframeless.com/activate")!

	/// P-256 public key (X9.63 uncompressed point). Must be byte-identical to
	/// `kKKLicensePublicKey` in KKLicense.m, or the UI and the render disagree
	/// about whether the product is activated.
	static let publicKeyX963 = Data([
		0x04, 0x07, 0x0a, 0x25, 0x33, 0xf2, 0xb5, 0x7d, 0x76, 0x5f, 0x99,
		0xae, 0x0a, 0xa7, 0x0a, 0xa6, 0x16, 0x51, 0x21, 0xf0, 0x3c, 0xc0,
		0x3b, 0x5d, 0x6a, 0x93, 0x85, 0x14, 0x8b, 0x57, 0x5e, 0x3b, 0xe0,
		0x55, 0x30, 0x23, 0x29, 0x17, 0x3f, 0xbd, 0xcd, 0x38, 0x7f, 0xf8,
		0x61, 0xa3, 0x5e, 0x83, 0x30, 0x0d, 0x10, 0xd6, 0xe5, 0x6d, 0xb5,
		0xd1, 0xce, 0x30, 0x2c, 0x8b, 0x14, 0xea, 0xfb, 0x34, 0x95,
	])

	static func defaultsKey(for productID: String) -> String {
		"com.keyframeless.license.\(productID)"
	}

	/// The stored record, or nil when there is none or its signature does not
	/// check out. Mirrors `KKLicenseIsActivated()` exactly.
	public static func record(for productID: String) -> LicenseRecord? {
		guard let defaults = UserDefaults(suiteName: suiteName),
			let dict = defaults.dictionary(forKey: defaultsKey(for: productID))
		else { return nil }
		return record(from: dict, for: productID)
	}

	private static func record(
		from dict: [String: Any], for productID: String
	) -> LicenseRecord? {
		guard
			let payloadB64 = dict["payload"] as? String,
			let signatureB64 = dict["sig"] as? String,
			let payload = Data(base64Encoded: payloadB64),
			let signature = Data(base64Encoded: signatureB64),
			verify(payload: payload, signature: signature, productID: productID)
		else { return nil }
		let claims = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
		let issued = (claims?["issuedAt"] as? TimeInterval).map(
			Date.init(timeIntervalSince1970:))
		return LicenseRecord(
			licenseKey: dict["key"] as? String ?? "",
			buyerEmail: claims?["email"] as? String ?? dict["email"] as? String,
			activatedAt: issued ?? Date())
	}

	/// Signature + claims check, matching KKLicense.m. Kept here (rather than
	/// trusting the ObjC side) so the trial banner can never show "activated"
	/// while the renders still watermark.
	static func verify(payload: Data, signature: Data, productID: String) -> Bool {
		guard let key = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
			let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature),
			key.isValidSignature(sig, for: payload),
			let claims = (try? JSONSerialization.jsonObject(with: payload))
				as? [String: Any],
			claims["product"] as? String == productID
		else { return false }
		guard let bound = claims["machineID"] as? String, !bound.isEmpty,
			let here = LicenseInstallationID.current(), bound == here
		else { return false }
		return true
	}

	public static func isActivated(_ productID: String) -> Bool {
		record(for: productID) != nil
	}

	@discardableResult
	public static func activate(
		licenseKey: String, productID: String
	) async throws -> LicenseRecord {
		let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw LicenseError.invalidKey }

		var request = URLRequest(url: activationURL)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.timeoutInterval = 15
		guard let installationID = LicenseInstallationID.current() else {
			throw LicenseError.storageUnavailable
		}
		let body: [String: String] = [
			"licenseKey": trimmed,
			"product": productID,
			// Kept as `machineID` for wire compatibility with the deployed
			// Worker. The value is an opaque shared installation UUID.
			"machineID": installationID,
		]
		request.httpBody = try? JSONSerialization.data(withJSONObject: body)

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
		case 403: throw LicenseError.disabled
		case 400..<500: throw LicenseError.invalidKey
		default: throw LicenseError.unexpected(http.statusCode)
		}

		// The Worker returns the exact signed bytes plus the signature over
		// them. Both are stored verbatim: re-encoding the payload here would
		// change the bytes and invalidate the signature.
		guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let payloadB64 = root["payload"] as? String,
			let signatureB64 = root["signature"] as? String,
			let payload = Data(base64Encoded: payloadB64),
			let signature = Data(base64Encoded: signatureB64),
			verify(payload: payload, signature: signature, productID: productID)
		else { throw LicenseError.untrustedResponse }

		guard
			let stored = store(
				payloadB64: payloadB64, signatureB64: signatureB64,
				licenseKey: trimmed, for: productID)
		else { throw LicenseError.storageUnavailable }
		return stored
	}

	static func store(
		payloadB64: String, signatureB64: String, licenseKey: String,
		for productID: String
	) -> LicenseRecord? {
		guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
		// `key` is kept for display and for re-activation on another machine;
		// it is NOT what grants activation - only the signature does.
		defaults.set(
			[
				"payload": payloadB64,
				"sig": signatureB64,
				"key": licenseKey,
				"date": Date().timeIntervalSince1970,
			], forKey: defaultsKey(for: productID))
		// `synchronize()` is only a best-effort flush; its return value is not a
		// reliable indication that an app-group write succeeded. Read back from
		// the same preferences instance and validate the exact signed record.
		_ = defaults.synchronize()
		guard let stored = defaults.dictionary(forKey: defaultsKey(for: productID))
		else { return nil }
		return record(from: stored, for: productID)
	}
}
