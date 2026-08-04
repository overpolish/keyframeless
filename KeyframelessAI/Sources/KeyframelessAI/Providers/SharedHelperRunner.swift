/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Darwin
import Foundation
import os

private let clientLog = Logger(subsystem: "com.keyframeless", category: "ai.helper")

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
		case timedOut
		/// The user cancelled the download; the helper stopped the fetch and dropped
		/// the partial. Not surfaced as an error in the UI.
		case downloadCancelled
		public var errorDescription: String? {
			switch self {
			case .spawnFailed(let m): return "Couldn't start local AI helper: \(m)"
			case .notConnected: return "Not connected to the local AI helper."
			case .helperExited: return "Local AI helper exited unexpectedly."
			case .helperError(let m): return m
			case .timedOut:
				return "The local AI didn't respond in time and was stopped. Try again."
			case .downloadCancelled: return "Download cancelled."
			}
		}
	}

	/// Max silence (seconds) to wait for the next frame from the helper before
	/// treating the connection as stuck. The helper emits status frames at the
	/// start of generation and a result/chunk frame at the end, so the only long
	/// silence is one model load or one pass (tens of seconds with the slim
	/// prompt); this is well above that, but bounds a genuine hang so a dead
	/// session can't freeze the inspector forever.
	private static let idleTimeout: TimeInterval = 120

	private let socketPath: String
	private let queue = DispatchQueue(label: "com.keyframeless.ai.helper.client")
	private var conn: FileHandle?

	/// Fails to init when the app-group socket path is unavailable (missing
	/// `group.com.keyframeless` entitlement) - local inference is then
	/// unavailable and the caller (`LocalLLM.defaultRunner`) returns nil.
	public init?() {
		guard let path = LocalAIHelperSocket.sharedSocketPath() else { return nil }
		self.socketPath = path
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
						guard let data = try self.readFrame(from: conn) else {
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
						if let chunk = resp.chunk, !chunk.isEmpty { continuation.yield(chunk) }
					}
					continuation.finish()
				} catch {
					if let helperError = error as? HelperError, case .timedOut = helperError {
						// The data connection timing out does not itself cancel MLX. Tell
						// the helper to stop over its independent control connection so a
						// dead answer cannot keep using the GPU after the UI unblocks.
						_ = try? self.controlExchange("cancel")
						clientLog.notice(
							"client: streaming helper timed out; cancelled active jobs")
					}
					// A dead socket leaves the connection unusable; drop it so the next
					// call reconnects/respawns.
					self.teardown()
					continuation.finish(throwing: error)
				}
			}
		}
	}

	/// Number of generations the helper is currently running (across every client),
	/// or 0 if the helper isn't up. Uses a SEPARATE short-lived connection - the
	/// main one may be blocked mid-generation on the serial queue - so it must NOT
	/// run on `queue`. Call off the main thread (blocking socket I/O).
	public func activeJobCount() -> Int {
		(try? controlExchange("status"))?.activeJobs ?? 0
	}

	/// The model the helper is currently downloading (started by ANY client) and its
	/// fraction (0...1), or nil if no download is in flight or the helper isn't up.
	/// Uses a short-lived control connection that does NOT wake the helper - a status
	/// poll must never launch it. Off-main (blocking socket I/O).
	public func currentDownload() -> (id: String, progress: Double)? {
		guard let resp = try? controlExchange("status"), let id = resp.downloadingModelID
		else { return nil }
		return (id, resp.downloadProgress ?? 0)
	}

	/// Cancel every in-flight generation on the helper (MLX stops between tokens,
	/// so the stuck pass throws and its waiting client unblocks). Best-effort;
	/// no-op if the helper isn't up. Off-main (blocking socket I/O).
	public func cancelActiveJobs() {
		_ = try? controlExchange("cancel")
	}

	/// Stop the in-flight model download and drop its partial bytes from the shared
	/// cache (frees disk). The initiating client's `downloadModel` then throws
	/// `.downloadCancelled`. Best-effort; no-op if nothing is downloading or the helper
	/// isn't up. Off-main (blocking socket I/O).
	public func cancelDownload() {
		_ = try? controlExchange("cancel-download")
	}

	/// Open a fresh connection, send one CONTROL request, read one reply, close.
	/// Independent of the serial request queue so it works while a generation is
	/// stuck. Returns nil-ish via throw when the helper isn't listening.
	private func controlExchange(_ control: String) throws -> HelperResponse {
		guard let fd = LocalAIHelperSocket.clientConnect(path: socketPath) else {
			throw HelperError.notConnected  // helper not running - nothing to control
		}
		let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
		defer { try? h.close() }
		let req = HelperRequest(
			modelID: "", system: "", user: "", jsonSchemaJSON: nil,
			enableThinking: false, control: control)
		try HelperFraming.write(try JSONEncoder().encode(req), to: h)
		guard let data = try readFrame(from: h) else { throw HelperError.helperExited }
		return try JSONDecoder().decode(HelperResponse.self, from: data)
	}

	/// Queue-isolated: ensure connected, send one request, read one response. On a
	/// transport failure (helper idle-exited / crashed) reconnect once and retry.
	private func exchange(_ req: HelperRequest) throws -> String {
		try ensureConnected()
		do {
			return try roundtrip(req)
		} catch let e as HelperError where isTransport(e) {
			// A timed-out (hung) helper won't recover by retrying into the same
			// stall - surface the error now so the inspector unblocks. Dropping the
			// connection lets the NEXT prompt reconnect (and respawn a fresh helper
			// if this one has gone away).
			if case .timedOut = e {
				_ = try? controlExchange("cancel")
				teardown()
				clientLog.notice("client: helper timed out; cancelled jobs and dropped connection")
				throw e
			}
			teardown()
			clientLog.notice(
				"client: transport lost (\(e.localizedDescription, privacy: .public)); reconnecting"
			)
			try ensureConnected()
			return try roundtrip(req)
		}
	}

	private func isTransport(_ e: HelperError) -> Bool {
		switch e {
		case .helperExited, .notConnected, .timedOut: return true
		default: return false
		}
	}

	/// Read one length-prefixed frame with an IDLE timeout, so a hung helper can't
	/// block this connection (and thus every queued pass) forever. Returns nil on
	/// a clean EOF (peer closed); throws `.timedOut` if no bytes arrive within
	/// `idleTimeout`. Client-only (the helper's own reads legitimately wait
	/// forever for the next request, so HelperFraming.read stays untimed there).
	private func readFrame(from h: FileHandle) throws -> Data? {
		let fd = h.fileDescriptor
		guard let header = try readN(4, fd: fd) else { return nil }
		let len = UInt32(bigEndian: header.withUnsafeBytes { $0.load(as: UInt32.self) })
		if len == 0 { return Data() }
		guard let body = try readN(Int(len), fd: fd) else {
			throw HelperError.helperExited  // header arrived, body truncated: peer died
		}
		return body
	}

	private func readN(_ n: Int, fd: Int32) throws -> Data? {
		var buf = Data()
		buf.reserveCapacity(n)
		while buf.count < n {
			var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
			let pr = poll(&pfd, 1, Int32(Self.idleTimeout * 1000))
			if pr == 0 { throw HelperError.timedOut }
			if pr < 0 {
				if errno == EINTR { continue }
				throw HelperError.helperExited
			}
			let want = n - buf.count
			var tmp = [UInt8](repeating: 0, count: want)
			let r = tmp.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
			if r == 0 { return buf.isEmpty ? nil : buf }  // EOF
			if r < 0 {
				if errno == EINTR { continue }
				throw HelperError.helperExited
			}
			buf.append(contentsOf: tmp[0..<r])
		}
		return buf
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
				respData = try readFrame(from: conn)
			} catch let e as HelperError {
				throw e  // preserve .timedOut vs other transport errors
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

	/// Return a connected socket fd, waking the helper (launchd) if nothing is
	/// listening yet. Bind + listen happens immediately at helper start (before the
	/// slow model load), so this resolves within ~a second; allow headroom. Returns
	/// nil if the helper can't be reached within ~10s.
	private func connectOrWake() -> Int32? {
		if let fd = LocalAIHelperSocket.clientConnect(path: socketPath) { return fd }
		try? wakeHelper()
		for _ in 0..<200 {  // ~10s at 50ms
			if let fd = LocalAIHelperSocket.clientConnect(path: socketPath) { return fd }
			usleep(50_000)
		}
		return nil
	}

	private func ensureConnected() throws {
		if conn != nil { return }
		guard let fd = connectOrWake() else {
			throw HelperError.spawnFailed("helper did not come up at \(socketPath)")
		}
		conn = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
		clientLog.notice("client: connected to helper socket")
	}

	/// Ask the helper to download a model's files into the shared cache, forwarding
	/// progress (0...1). Runs on a background queue over its OWN connection so it
	/// doesn't block generation on the serial queue; wakes the helper first if
	/// needed. Returns when the download completes, throws on failure.
	public func downloadModel(
		_ modelID: String, progress: @escaping @Sendable (Double) -> Void
	) async throws {
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			DispatchQueue.global(qos: .utility).async {
				guard let fd = self.connectOrWake() else {
					cont.resume(throwing: HelperError.notConnected)
					return
				}
				let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
				defer { try? h.close() }
				do {
					let req = HelperRequest(
						modelID: modelID, system: "", user: "", jsonSchemaJSON: nil,
						enableThinking: false, control: "download")
					try HelperFraming.write(try JSONEncoder().encode(req), to: h)
					while true {
						guard let data = try self.readFrame(from: h) else {
							throw HelperError.helperExited
						}
						let resp = try JSONDecoder().decode(HelperResponse.self, from: data)
						if let err = resp.error { throw HelperError.helperError(err) }
						if resp.cancelled == true { throw HelperError.downloadCancelled }
						if let p = resp.downloadProgress { progress(p) }
						if resp.done == true { break }
					}
					cont.resume()
				} catch {
					cont.resume(throwing: error)
				}
			}
		}
	}

	/// Start the shared helper without exec'ing it ourselves. The sandbox forbids a
	/// plugin from launching an out-of-bundle binary, but it CAN look up an app-group
	/// Mach service - and the helper is installed once (by the "Keyframeless AI"
	/// package) as an on-demand LaunchAgent that vends exactly that service. Opening
	/// the connection and sending one message makes launchd launch the helper, which
	/// then binds its socket and serves as before. On a dev machine with no installed
	/// LaunchAgent, `KKAI_HELPER_PATH` spawns a built helper directly instead.
	private func wakeHelper() throws {
		#if DEBUG
			if let devPath = ProcessInfo.processInfo.environment["KKAI_HELPER_PATH"] {
				try spawnHelperDev(URL(fileURLWithPath: devPath))
				return
			}
		#endif
		let c = NSXPCConnection(machServiceName: LocalAIHelperSocket.machServiceName, options: [])
		c.remoteObjectInterface = NSXPCInterface(with: KKAIHelperWake.self)
		c.resume()
		let sema = DispatchSemaphore(value: 0)
		let proxy = c.remoteObjectProxyWithErrorHandler { err in
			// A connection error still triggered the launch attempt; log and move on -
			// the socket poll below is the real readiness signal.
			clientLog.notice(
				"client: wake xpc error (\(err.localizedDescription, privacy: .public))")
			sema.signal()
		}
		(proxy as? KKAIHelperWake)?.ping { sema.signal() }
		_ = sema.wait(timeout: .now() + 2)
		c.invalidate()
	}

	#if DEBUG
		/// Dev-only: spawn a locally built helper (no installer/LaunchAgent present).
		/// Mirrors the shipped launch: user-initiated QoS + the shared HF cache.
		private func spawnHelperDev(_ exe: URL) throws {
			guard FileManager.default.fileExists(atPath: exe.path) else {
				throw HelperError.spawnFailed("KKAI_HELPER_PATH missing at \(exe.path)")
			}
			let p = Process()
			p.executableURL = exe
			p.qualityOfService = .userInitiated
			p.arguments = ["--socket", socketPath]
			if let cacheDir = LocalAIHelperSocket.sharedModelCacheDir() {
				var env = ProcessInfo.processInfo.environment
				env["HF_HUB_CACHE"] = cacheDir.path
				p.environment = env
			}
			p.standardInput = FileHandle.nullDevice
			p.standardOutput = FileHandle.nullDevice
			p.standardError = FileHandle.nullDevice
			try p.run()
			clientLog.notice(
				"client: spawned DEV helper pid \(p.processIdentifier, privacy: .public)")
		}
	#endif

	private func teardown() {
		try? conn?.close()
		conn = nil
	}

	deinit {
		teardown()
	}
}
