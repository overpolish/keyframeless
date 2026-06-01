/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

public enum AIKeyValidationError: LocalizedError {
	case unauthorized
	case network(String)
	case unexpected(Int)

	public var errorDescription: String? {
		switch self {
		case .unauthorized: return "Key rejected by provider"
		case .network(let msg): return "Network error: \(msg)"
		case .unexpected(let code): return "Unexpected response (HTTP \(code))"
		}
	}
}

public enum AIKeyValidator {
	public static func validate(_ key: String, for provider: AIProvider) async throws {
		var request: URLRequest
		switch provider {
		case .anthropic:
			request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
			request.setValue(key, forHTTPHeaderField: "x-api-key")
			request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
		case .openai:
			request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
			request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
		}
		request.timeoutInterval = 15

		do {
			let (_, response) = try await URLSession.shared.data(for: request)
			guard let http = response as? HTTPURLResponse else {
				throw AIKeyValidationError.unexpected(0)
			}
			switch http.statusCode {
			case 200..<300: return
			case 401, 403: throw AIKeyValidationError.unauthorized
			default: throw AIKeyValidationError.unexpected(http.statusCode)
			}
		} catch let e as AIKeyValidationError {
			throw e
		} catch {
			throw AIKeyValidationError.network(error.localizedDescription)
		}
	}
}
