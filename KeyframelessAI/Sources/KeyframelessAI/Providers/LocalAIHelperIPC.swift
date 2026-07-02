/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

/// Wire types + framing shared by the out-of-process local-inference helper
/// (`LocalAIHelperServer`, the child) and its client (`HelperProcessRunner`,
/// e.g. Steno's FCP workflow extension). The extension caps at a 1 GB memory
/// watermark that an MLX LLM load blows past, so inference is exiled to a child
/// process spawned over a pipe - which has its own (high) limit.
///
/// One request -> one OR MORE responses, length-prefixed so prompt/schema strings
/// (which contain newlines) frame unambiguously. The client serialises calls, so
/// no request id is needed.
///
/// Two modes: when `stream` is nil/false the helper sends a single response with
/// `result` (or `error`). When `stream == true` it sends a sequence of `chunk`
/// responses as the model generates, terminated by one with `done == true` (or an
/// `error`). Streaming is only meaningful for plain-text answers (no schema).
struct HelperRequest: Codable {
	let modelID: String
	let system: String
	let user: String
	let jsonSchemaJSON: String?
	let enableThinking: Bool
	/// Stream the reply token-by-token (chunk frames) instead of one result frame.
	/// Optional for wire-compat with a mismatched/stale helper binary (absent = off).
	var stream: Bool? = nil
	/// Non-generation CONTROL request: "status" (reply with the active job count),
	/// "cancel" (cancel every in-flight generation), or "shutdown" (exit the
	/// helper). Sent on a SEPARATE connection so it's serviced even while another
	/// connection is stuck mid-generation. nil = an ordinary generation request.
	var control: String? = nil
}

struct HelperResponse: Codable {
	let result: String?
	let error: String?
	/// Streaming: an incremental text chunk to append (nil on the final/marker frame).
	var chunk: String? = nil
	/// Streaming: true on the terminating frame after the last chunk.
	var done: Bool? = nil
	/// Out-of-band coarse status ("Loading model…", "Thinking…") emitted before the
	/// terminal frame so the client can show what the helper is actually doing.
	var status: String? = nil
	/// Control "status"/"cancel" reply: the number of in-flight generations (after
	/// the action, for cancel).
	var activeJobs: Int? = nil
}

/// Length-prefixed message framing over a pipe: a 4-byte big-endian payload
/// length, then the payload. Pipes can short-read, so both header and body are
/// read to completion. A 0-byte read on the header is a clean EOF (peer closed).
enum HelperFraming {
	static func write(_ payload: Data, to fh: FileHandle) throws {
		var len = UInt32(payload.count).bigEndian
		var frame = Data(bytes: &len, count: 4)
		frame.append(payload)
		try fh.write(contentsOf: frame)
	}

	/// Returns the next payload, or nil at clean EOF (peer closed the pipe).
	static func read(from fh: FileHandle) throws -> Data? {
		guard let header = try readExactly(4, from: fh) else { return nil }
		let len = UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) })
		if len == 0 { return Data() }
		guard let body = try readExactly(Int(len), from: fh) else {
			// Header arrived but the body was truncated - peer died mid-frame.
			throw HelperFramingError.truncated
		}
		return body
	}

	private static func readExactly(_ n: Int, from fh: FileHandle) throws -> Data? {
		var buf = Data()
		buf.reserveCapacity(n)
		while buf.count < n {
			let chunk = try fh.read(upToCount: n - buf.count) ?? Data()
			if chunk.isEmpty { return buf.isEmpty ? nil : buf }
			buf.append(chunk)
		}
		return buf
	}
}

enum HelperFramingError: Error { case truncated }
