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
/// Wake the on-demand helper. The client (thin plugin) looks up the app-group Mach
/// service; that lookup makes launchd launch the helper (which vends this via an
/// `NSXPCListener`). The `ping` reply just confirms liveness - the real data path is
/// the unix socket. `@objc` so `NSXPCInterface` can vend it.
@objc public protocol KKAIHelperWake {
	func ping(reply: @escaping () -> Void)
}

public struct HelperRequest: Codable, Sendable {
	public let modelID: String
	public let system: String
	public let user: String
	public let jsonSchemaJSON: String?
	public let enableThinking: Bool
	/// Stream the reply token-by-token (chunk frames) instead of one result frame.
	/// Optional for wire-compat with a mismatched/stale helper binary (absent = off).
	public var stream: Bool? = nil
	/// Non-generation CONTROL request: "status" (reply with the active job count),
	/// "cancel" (cancel every in-flight generation), or "shutdown" (exit the
	/// helper). Sent on a SEPARATE connection so it's serviced even while another
	/// connection is stuck mid-generation. nil = an ordinary generation request.
	public var control: String? = nil

	public init(
		modelID: String, system: String, user: String, jsonSchemaJSON: String?,
		enableThinking: Bool, stream: Bool? = nil, control: String? = nil
	) {
		self.modelID = modelID
		self.system = system
		self.user = user
		self.jsonSchemaJSON = jsonSchemaJSON
		self.enableThinking = enableThinking
		self.stream = stream
		self.control = control
	}
}

public struct HelperResponse: Codable, Sendable {
	public let result: String?
	public let error: String?
	/// Streaming: an incremental text chunk to append (nil on the final/marker frame).
	public var chunk: String? = nil
	/// Streaming: true on the terminating frame after the last chunk.
	public var done: Bool? = nil
	/// Out-of-band coarse status ("Loading model…", "Thinking…") emitted before the
	/// terminal frame so the client can show what the helper is actually doing.
	public var status: String? = nil
	/// Control "status"/"cancel" reply: the number of in-flight generations (after
	/// the action, for cancel).
	public var activeJobs: Int? = nil
	/// Control "download" progress: fraction downloaded so far (0...1). The terminal
	/// frame carries `done == true`; a failure carries `error`. Also set on a "status"
	/// reply to report an in-flight download's fraction (nil when nothing downloading).
	public var downloadProgress: Double? = nil
	/// Control "status" reply: the catalog id of the model the helper is currently
	/// downloading (started by ANY client), or nil if no download is in flight. Lets a
	/// plugin that didn't start the download mirror its live progress.
	public var downloadingModelID: String? = nil
	/// Terminal frame of a download the user cancelled: the helper stopped the fetch
	/// and deleted the partial. Distinct from `done` (success) and `error` (failure) so
	/// the client neither marks the model downloaded nor shows an error.
	public var cancelled: Bool? = nil

	public init(
		result: String?, error: String?, chunk: String? = nil, done: Bool? = nil,
		status: String? = nil, activeJobs: Int? = nil, downloadProgress: Double? = nil,
		downloadingModelID: String? = nil, cancelled: Bool? = nil
	) {
		self.result = result
		self.error = error
		self.chunk = chunk
		self.done = done
		self.status = status
		self.activeJobs = activeJobs
		self.downloadProgress = downloadProgress
		self.downloadingModelID = downloadingModelID
		self.cancelled = cancelled
	}
}

/// Length-prefixed message framing over a pipe: a 4-byte big-endian payload
/// length, then the payload. Pipes can short-read, so both header and body are
/// read to completion. A 0-byte read on the header is a clean EOF (peer closed).
public enum HelperFraming {
	public static func write(_ payload: Data, to fh: FileHandle) throws {
		var len = UInt32(payload.count).bigEndian
		var frame = Data(bytes: &len, count: 4)
		frame.append(payload)
		try fh.write(contentsOf: frame)
	}

	/// Returns the next payload, or nil at clean EOF (peer closed the pipe).
	public static func read(from fh: FileHandle) throws -> Data? {
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

public enum HelperFramingError: Error { case truncated }
