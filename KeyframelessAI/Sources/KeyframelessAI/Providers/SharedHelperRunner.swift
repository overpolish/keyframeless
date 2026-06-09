/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Darwin
import Foundation
import os

private let clientLog = Logger(subsystem: "co.overpolish.keyframeless", category: "ai.helper")

/// `LocalLLMRunner` that talks to the SHARED out-of-process helper over a
/// Unix-domain socket in the app-group container. Used by every memory-capped or
/// multi-instance client (the FCP workflow extension and FxPlug plugins) so a
/// single helper process - one model load - serves all of them.
///
/// First use connects to the socket; if nobody is listening it spawns the helper
/// (from the client's own bundle, which the sandbox permits) and waits for it to
/// come up. The connection is then held open for the client's whole lifetime:
/// the helper counts open connections as live clients, and shuts down when the
/// last one closes. If the helper idle-exits between requests, the next call
/// transparently reconnects/respawns.
///
/// Requests are serialised on a private queue (one model, one GPU - concurrency
/// wouldn't parallelise, and it keeps the single socket coherent).
public final class SharedHelperRunner: LocalLLMRunner, @unchecked Sendable {
	public enum HelperError: LocalizedError {
		case spawnFailed(String)
		case notConnected
		case helperExited
		case helperError(String)
		public var errorDescription: String? {
			switch self {
			case .spawnFailed(let m): return "Couldn't start local AI helper: \(m)"
			case .notConnected: return "Not connected to the local AI helper."
			case .helperExited: return "Local AI helper exited unexpectedly."
			case .helperError(let m): return m
			}
		}
	}

	private let socketPath: String
	private let helperLocator: @Sendable () -> URL?
	private let queue = DispatchQueue(label: "co.overpolish.ai.helper.client")
	private var conn: FileHandle?

	/// Fails to init when the app-group socket path is unavailable (missing
	/// entitlement) - the caller should then fall back.
	/// - Parameter helperLocator: returns the helper binary in the client's own
	///   bundle (sandbox only permits exec'ing in-bundle binaries).
	public init?(helperLocator: @escaping @Sendable () -> URL?) {
		guard let path = LocalAIHelperSocket.sharedSocketPath() else { return nil }
		self.socketPath = path
		self.helperLocator = helperLocator
	}

	public func complete(
		modelID: String, system: String, user: String, jsonSchemaJSON: String?,
		enableThinking: Bool
	) async throws -> String {
		let req = HelperRequest(
			modelID: modelID, system: system, user: user,
			jsonSchemaJSON: jsonSchemaJSON, enableThinking: enableThinking)
		return try await withCheckedThrowingContinuation { cont in
			queue.async {
				do {
					cont.resume(returning: try self.exchange(req))
				} catch {
					cont.resume(throwing: error)
				}
			}
		}
	}

	/// Stream a plain-text answer from the helper: send a `stream` request, then
	/// yield each chunk frame as it arrives until the `done` frame. Runs the whole
	/// exchange on the serial queue (one request at a time over the single socket).
	/// A mid-stream transport failure finishes the stream with an error - unlike a
	/// one-shot call we can't transparently replay a partially-delivered answer.
	public func completeStreaming(
		modelID: String, system: String, user: String
	) async -> AsyncThrowingStream<String, Error> {
		AsyncThrowingStream { continuation in
			queue.async {
				do {
					try self.ensureConnected()
					guard let conn = self.conn else { throw HelperError.notConnected }
					let req = HelperRequest(
						modelID: modelID, system: system, user: user,
						jsonSchemaJSON: nil, enableThinking: false, stream: true)
					try HelperFraming.write(try JSONEncoder().encode(req), to: conn)
					while true {
						guard let data = try HelperFraming.read(from: conn) else {
							throw HelperError.helperExited
						}
						let resp = try JSONDecoder().decode(HelperResponse.self, from: data)
						if let err = resp.error { throw HelperError.helperError(err) }
						if let status = resp.status {
							Self.applyStatus(status)
							continue
						}
						// A stale helper that predates streaming ignores the flag and
						// replies with one `result` frame: deliver it whole and stop, so
						// we don't block forever waiting for chunk/done frames.
						if let result = resp.result {
							continuation.yield(result)
							break
						}
						if resp.done == true { break }
						if let chunk = resp.chunk { continuation.yield(chunk) }
					}
					continuation.finish()
				} catch {
					// A dead socket leaves the connection unusable; drop it so the next
					// call reconnects/respawns.
					self.teardown()
					continuation.finish(throwing: error)
				}
			}
		}
	}

	/// Queue-isolated: ensure connected, send one request, read one response. On a
	/// transport failure (helper idle-exited / crashed) reconnect once and retry.
	private func exchange(_ req: HelperRequest) throws -> String {
		try ensureConnected()
		do {
			return try roundtrip(req)
		} catch let e as HelperError where isTransport(e) {
			clientLog.notice(
				"client: transport lost (\(e.localizedDescription, privacy: .public)); reconnecting"
			)
			teardown()
			try ensureConnected()
			return try roundtrip(req)
		}
	}

	private func isTransport(_ e: HelperError) -> Bool {
		switch e {
		case .helperExited, .notConnected: return true
		default: return false
		}
	}

	private func roundtrip(_ req: HelperRequest) throws -> String {
		guard let conn else { throw HelperError.notConnected }
		let payload = try JSONEncoder().encode(req)
		do {
			try HelperFraming.write(payload, to: conn)
		} catch {
			throw HelperError.helperExited
		}
		// The helper may emit status frames ("Loading model…"/"Thinking…") before
		// the terminal result frame; surface them, keep reading until the result.
		while true {
			let respData: Data?
			do {
				respData = try HelperFraming.read(from: conn)
			} catch {
				throw HelperError.helperExited
			}
			guard let respData else { throw HelperError.helperExited }
			let resp = try JSONDecoder().decode(HelperResponse.self, from: respData)
			if let err = resp.error { throw HelperError.helperError(err) }
			if let status = resp.status {
				Self.applyStatus(status)
				continue
			}
			if let result = resp.result { return result }
			// Unexpected frame (e.g. a stray chunk) - ignore and keep reading.
		}
	}

	/// Mirror a helper status update into THIS process's draft state so the plugin
	/// inspector shows what the helper is actually doing (the helper's own
	/// AIDraftState is in another process and never reaches the UI).
	private static func applyStatus(_ status: String) {
		Task { @MainActor in AIDraftState.shared.routingStatus = status }
	}

	private func ensureConnected() throws {
		if conn != nil { return }

		if let fd = LocalAIHelperSocket.clientConnect(path: socketPath) {
			conn = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
			return
		}

		// Nobody listening - spawn the helper, then poll for the socket. Bind +
		// listen happens immediately at helper start (before the slow model load),
		// so this resolves within ~a second; allow generous headroom.
		try spawnHelper()
		for _ in 0..<200 {  // ~10s at 50ms
			if let fd = LocalAIHelperSocket.clientConnect(path: socketPath) {
				conn = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
				clientLog.notice("client: connected to helper socket")
				return
			}
			usleep(50_000)
		}
		throw HelperError.spawnFailed("helper did not come up at \(socketPath)")
	}

	private func spawnHelper() throws {
		guard let exe = helperLocator() else {
			throw HelperError.spawnFailed("helper binary not found in bundle")
		}
		guard FileManager.default.fileExists(atPath: exe.path) else {
			throw HelperError.spawnFailed("missing at \(exe.path)")
		}
		let p = Process()
		p.executableURL = exe
		// CRITICAL for speed: a detached helper otherwise runs at background QoS
		// (efficiency cores + low GPU priority), making MLX generation ~10-15x
		// slower than the old in-process path. Pin it to user-initiated so it gets
		// performance cores and competes for the GPU with FCP's foreground work.
		p.qualityOfService = .userInitiated
		// Hand the helper the resolved socket path so it needs no app-group
		// entitlement of its own (it binds the path; filesystem access to the
		// group container is inherited from our sandbox).
		p.arguments = ["--socket", socketPath]
		// Point the helper at the SHARED model cache via HF_HUB_CACHE. It's read
		// from the process environment at startup (ProcessInfo snapshots it), so a
		// freshly spawned child picks it up - and every helper, whoever spawns it,
		// then loads from the one app-group cache instead of re-downloading.
		if let cacheDir = LocalAIHelperSocket.sharedModelCacheDir() {
			var env = ProcessInfo.processInfo.environment
			env["HF_HUB_CACHE"] = cacheDir.path
			p.environment = env
		}
		// The protocol is the socket; silence the child's stdout/stderr (MLX is
		// chatty) so it never pollutes the spawner. The helper logs via os.Logger.
		p.standardInput = FileHandle.nullDevice
		p.standardOutput = FileHandle.nullDevice
		p.standardError = FileHandle.nullDevice
		do {
			try p.run()
		} catch {
			clientLog.error("client: spawn FAILED: \(error.localizedDescription, privacy: .public)")
			throw HelperError.spawnFailed(error.localizedDescription)
		}
		// Do NOT wait/retain: the helper detaches and outlives us (reparented to
		// launchd), so it can keep serving other clients after we exit.
		clientLog.notice(
			"client: spawned helper \(exe.lastPathComponent, privacy: .public) pid \(p.processIdentifier, privacy: .public)"
		)
	}

	private func teardown() {
		try? conn?.close()
		conn = nil
	}

	deinit {
		teardown()
	}
}
