/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Darwin
import Foundation
import MLX
import os

private let helperLog = Logger(subsystem: "co.overpolish.keyframeless", category: "ai.helper")

/// Entry point for the bundled `kk-ai-helper` executable: a shared, singleton
/// child process that runs MLX local inference out-of-process for ALL clients
/// (FxPlug plugins + the FCP workflow extension). It binds a Unix-domain socket
/// in the app-group container; the first client to need inference spawns it, and
/// every other client connects to the same socket - so the model loads once and
/// serves everyone, regardless of how many plugin instances or extensions are
/// open.
///
/// Lifecycle by connection count: each connected client holds its socket open
/// for its whole process lifetime, so the count of open connections IS the live
/// client count. When the last client disconnects (quit or crash closes its
/// socket) and a short grace passes, the helper exits and unloads the model.
///
/// Protocol per connection: length-prefixed `HelperRequest` in, `HelperResponse`
/// out (see HelperFraming), looping until the peer closes.
public enum LocalAIHelperServer {
	/// Runs the singleton server forever. Call from the helper executable's
	/// `main.swift`: `import KeyframelessAI; LocalAIHelperServer.run()`. Never
	/// returns (exits the process when idle).
	/// Retains the latency-critical activity for the process lifetime (see run()).
	nonisolated(unsafe) private static var activityToken: NSObjectProtocol?

	public static func run() -> Never {
		// Writes to a closed client socket must not kill us.
		signal(SIGPIPE, SIG_IGN)

		// CRITICAL for speed: this helper is a headless, "NotVisible", "not GPU
		// managed" background process, so macOS energy-throttles it (App Nap + a
		// low GPU performance state), crushing MLX inference to ~1 tok/s even with
		// the GPU otherwise idle. Declare the work latency-critical so the OS runs
		// us at full CPU+GPU performance. Hold the token for the whole lifetime.
		activityToken = ProcessInfo.processInfo.beginActivity(
			options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
			reason: "kk-ai-helper local inference")
		helperLog.notice("helper: began latency-critical activity (anti-throttle)")

		// The spawning client (which holds the app-group entitlement) passes the
		// socket path via `--socket <path>`, so the helper itself needs NO
		// entitlement - it just binds the path it's handed (filesystem access to
		// the group container is inherited from the spawner's sandbox). Fall back
		// to resolving it directly only if the helper happens to be entitled.
		let argv = CommandLine.arguments
		let pathFromArg = argv.firstIndex(of: "--socket").flatMap { i in
			i + 1 < argv.count ? argv[i + 1] : nil
		}
		guard let path = pathFromArg ?? LocalAIHelperSocket.sharedSocketPath() else {
			helperLog.error("helper: no socket path (no --socket arg, no app-group); exiting")
			exit(1)
		}
		guard let serverFd = LocalAIHelperSocket.serverBind(path: path) else {
			// Another instance already owns the socket (we lost the spawn race) -
			// that's fine, the winner serves everyone.
			helperLog.notice(
				"helper: socket already served; exiting (pid \(getpid(), privacy: .public))")
			exit(0)
		}
		helperLog.notice(
			"helper: listening at \(path, privacy: .public) (pid \(getpid(), privacy: .public))")

		let runner = MLXLocalLLMRunner()
		let tracker = ConnectionTracker()

		// Accept loop blocks; run it on a background thread and hand the main
		// thread to dispatchMain() so complete()'s MainActor hops are serviced.
		let acceptThread = Thread {
			while true {
				guard let conn = LocalAIHelperSocket.acceptConn(serverFd) else { continue }
				tracker.opened()
				let worker = Thread {
					serveConnection(conn, runner: runner)
					tracker.closed()
				}
				worker.stackSize = 8 << 20
				worker.qualityOfService = .userInitiated
				worker.start()
			}
		}
		acceptThread.stackSize = 1 << 20
		acceptThread.start()
		dispatchMain()
	}

	/// Start the socket server on a BACKGROUND thread and RETURN, leaving the
	/// caller's main thread to run its own event loop. Use this from a real
	/// **agent app** (`NSApplication`) so the process is a managed app WITH a GPU
	/// role (the bare CLI `run()` is gpuRole:None and gets throttled). The app's
	/// run loop services the MainActor hops inside complete(). Unlike `run()`,
	/// this does NOT exit on idle - the app owns its lifecycle (it can unload the
	/// model when idle later; for now the model just stays warm).
	///
	/// Call once, e.g. from the App's `init`:
	///   `import KeyframelessAI; LocalAIHelperServer.startInBackground()`
	public static func startInBackground() {
		signal(SIGPIPE, SIG_IGN)

		guard let path = LocalAIHelperSocket.sharedSocketPath() else {
			helperLog.error("agent: no app-group socket path (entitlement?); not serving")
			return
		}
		guard let serverFd = LocalAIHelperSocket.serverBind(path: path) else {
			helperLog.notice("agent: socket already served by another instance")
			return
		}
		helperLog.notice(
			"agent: listening at \(path, privacy: .public) (pid \(getpid(), privacy: .public))")

		let runner = MLXLocalLLMRunner()
		let acceptThread = Thread {
			while true {
				guard let conn = LocalAIHelperSocket.acceptConn(serverFd) else { continue }
				helperLog.notice("agent: client connected")
				let worker = Thread {
					serveConnection(conn, runner: runner)
					helperLog.notice("agent: client disconnected")
				}
				worker.stackSize = 8 << 20
				worker.qualityOfService = .userInitiated
				worker.start()
			}
		}
		acceptThread.stackSize = 1 << 20
		acceptThread.qualityOfService = .userInitiated
		acceptThread.start()
	}

	/// Serve one client connection until it closes.
	private static func serveConnection(_ fd: Int32, runner: MLXLocalLLMRunner) {
		let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
		while true {
			let reqData: Data?
			do {
				reqData = try HelperFraming.read(from: h)
			} catch {
				break
			}
			guard let reqData else { break }  // clean EOF: client gone

			let req: HelperRequest
			do {
				req = try JSONDecoder().decode(HelperRequest.self, from: reqData)
			} catch {
				let bad = HelperResponse(result: nil, error: "helper: bad request: \(error)")
				if !writeFrame(bad, to: h) { break }
				continue
			}

			// CONTROL requests (status / cancel / shutdown) are handled right here on
			// this connection's own thread - never touching the MLX actor - so they
			// answer instantly even when another connection is stuck mid-generation.
			if let control = req.control {
				switch control {
				case "status":
					_ = writeFrame(
						HelperResponse(
							result: nil, error: nil, activeJobs: JobRegistry.shared.count),
						to: h)
				case "cancel":
					let n = JobRegistry.shared.cancelAll()
					helperLog.notice("helper: cancel requested (\(n, privacy: .public) job(s))")
					_ = writeFrame(
						HelperResponse(
							result: nil, error: nil, activeJobs: JobRegistry.shared.count),
						to: h)
				case "shutdown":
					helperLog.notice("helper: shutdown requested; exiting")
					_ = writeFrame(HelperResponse(result: nil, error: nil, done: true), to: h)
					exit(0)
				default:
					_ = writeFrame(
						HelperResponse(result: nil, error: "helper: unknown control \(control)"),
						to: h)
				}
				continue
			}

			// Streaming answers emit many chunk frames then a done frame; everything
			// else is one result frame. Either path returns false on a write failure
			// (peer closed) so we stop serving this connection.
			let ok =
				req.stream == true
				? streamResponse(req, runner: runner, to: h)
				: writeFrame(handle(req, runner: runner, to: h), to: h)
			if !ok { break }
		}
		try? h.close()
	}

	private static func writeFrame(_ resp: HelperResponse, to h: FileHandle) -> Bool {
		do {
			try HelperFraming.write(try JSONEncoder().encode(resp), to: h)
			return true
		} catch {
			return false  // peer closed mid-write
		}
	}

	private static func handle(
		_ req: HelperRequest, runner: MLXLocalLLMRunner, to h: FileHandle
	) -> HelperResponse {
		// Bridge the actor's async API to this synchronous (background-thread)
		// loop. Safe because complete()'s MainActor hops are serviced by
		// dispatchMain() on the main thread, not this one. The actor serialises
		// concurrent connections' calls onto the single loaded model.
		let sem = DispatchSemaphore(value: 0)
		let box = ResultBox()
		let sink = FrameSink(h)
		// Register this generation so a "cancel" control request can stop it
		// (MLX honours Task cancellation between tokens). Reserve the id first so
		// the count is right even before the Task handle exists.
		let jobID = JobRegistry.shared.reserve()
		let task = Task(priority: .userInitiated) {
			defer {
				JobRegistry.shared.remove(jobID)
				sem.signal()
			}
			// Forward the runner's coarse status ("Loading model…"/"Thinking…") to
			// the client as status frames, written before the terminal result frame
			// (the runner reports them during the awaited call below).
			await LocalRunnerStatus.$sink.withValue({ status in
				sink.send(HelperResponse(result: nil, error: nil, status: status))
			}) {
				do {
					let text = try await runner.complete(
						modelID: req.modelID, system: req.system, user: req.user,
						jsonSchemaJSON: req.jsonSchemaJSON, enableThinking: req.enableThinking)
					box.value = .success(text)
				} catch {
					box.value = .failure(error)
				}
			}
		}
		JobRegistry.shared.attach(jobID, task)
		sem.wait()

		switch box.value {
		case .success(let text): return HelperResponse(result: text, error: nil)
		case .failure(let err): return HelperResponse(result: nil, error: err.localizedDescription)
		case .none: return HelperResponse(result: nil, error: "helper: no result")
		}
	}

	/// Stream a plain-text answer: forward each chunk from the runner as its own
	/// frame, then a `done` frame (or an `error` frame on failure). Blocks this
	/// connection thread until the stream completes - the model is single-GPU and
	/// serialised by the actor anyway - and only this thread writes to `h` while it
	/// runs, so frames never interleave. Returns false if a frame write fails.
	private static func streamResponse(
		_ req: HelperRequest, runner: MLXLocalLLMRunner, to h: FileHandle
	) -> Bool {
		let sem = DispatchSemaphore(value: 0)
		let writeOK = FlagBox()
		let sink = FrameSink(h)
		let jobID = JobRegistry.shared.reserve()
		let task = Task(priority: .userInitiated) {
			defer {
				JobRegistry.shared.remove(jobID)
				sem.signal()
			}
			func send(_ resp: HelperResponse) -> Bool {
				let ok = writeFrame(resp, to: h)
				if !ok { writeOK.value = false }
				return ok
			}
			// Status frames ("Loading model…"/"Thinking…") precede the chunk frames,
			// emitted by the runner during the awaited call below.
			await LocalRunnerStatus.$sink.withValue({ status in
				sink.send(HelperResponse(result: nil, error: nil, status: status))
			}) {
				do {
					let stream = await runner.completeStreaming(
						modelID: req.modelID, system: req.system, user: req.user)
					for try await chunk in stream {
						if !send(HelperResponse(result: nil, error: nil, chunk: chunk)) { break }
					}
					if writeOK.value {
						_ = send(HelperResponse(result: nil, error: nil, done: true))
					}
				} catch {
					_ = send(HelperResponse(result: nil, error: error.localizedDescription))
				}
			}
		}
		JobRegistry.shared.attach(jobID, task)
		sem.wait()
		return writeOK.value
	}

	/// Tracks in-flight generations so a "status" control request can report how
	/// many are running and a "cancel" can stop them. `reserve()` bumps the count
	/// before the Task handle exists (so a status query mid-spawn is accurate);
	/// `attach` stores the cancellable handle; `remove` clears it on completion.
	final class JobRegistry: @unchecked Sendable {
		static let shared = JobRegistry()
		private let lock = NSLock()
		private var nextID = 0
		private var inFlight = Set<Int>()
		private var tasks = [Int: Task<Void, Never>]()
		// Set by cancelAll: once the cancelled generations finish unwinding and the
		// helper goes idle, release MLX's pooled GPU buffers so cancelling actually
		// gives the memory back (MLX keeps a buffer cache, so RSS otherwise stays
		// at the in-generation high-water mark). Not done on NORMAL completion -
		// that would clear the cache between an agent's sequential passes and force
		// a costly re-alloc each time.
		private var clearCacheWhenIdle = false

		func reserve() -> Int {
			lock.lock()
			defer { lock.unlock() }
			let id = nextID
			nextID += 1
			inFlight.insert(id)
			return id
		}
		func attach(_ id: Int, _ t: Task<Void, Never>) {
			lock.lock()
			if inFlight.contains(id) { tasks[id] = t }
			lock.unlock()
		}
		func remove(_ id: Int) {
			lock.lock()
			inFlight.remove(id)
			tasks[id] = nil
			let drainedAfterCancel = inFlight.isEmpty && clearCacheWhenIdle
			if drainedAfterCancel { clearCacheWhenIdle = false }
			lock.unlock()
			if drainedAfterCancel {
				helperLog.notice("helper: cancelled jobs drained; clearing MLX cache")
				Memory.clearCache()
			}
		}
		var count: Int {
			lock.lock()
			defer { lock.unlock() }
			return inFlight.count
		}
		/// Cancel every in-flight generation; returns how many were running. Arms a
		/// cache clear for when they finish, so the GPU memory is actually reclaimed.
		func cancelAll() -> Int {
			lock.lock()
			let handles = Array(tasks.values)
			let n = inFlight.count
			if n > 0 { clearCacheWhenIdle = true }
			lock.unlock()
			handles.forEach { $0.cancel() }
			return n
		}
	}

	private final class ResultBox: @unchecked Sendable {
		var value: Result<String, Error>?
	}

	private final class FlagBox: @unchecked Sendable {
		var value = true
	}

	/// Sendable wrapper so a status frame can be written from the runner's
	/// `@Sendable` status sink without capturing the non-Sendable FileHandle
	/// directly. Best-effort (status is non-critical); errors are swallowed.
	private final class FrameSink: @unchecked Sendable {
		private let h: FileHandle
		init(_ h: FileHandle) { self.h = h }
		func send(_ resp: HelperResponse) {
			guard let out = try? JSONEncoder().encode(resp) else { return }
			try? HelperFraming.write(out, to: h)
		}
	}

	/// Tracks open client connections and exits the process when the last one
	/// closes (after a grace period). Also arms an initial timer so a helper that
	/// nobody ever connects to (spawner died) doesn't linger forever.
	private final class ConnectionTracker: @unchecked Sendable {
		private let lock = NSLock()
		private var count = 0
		// Stay warm across a whole editing session so coming back to the tool
		// doesn't re-pay the ~5s model load (and any first-time Metal-kernel
		// compile). Only matters after the LAST client disconnects - an open
		// plugin/extension holds its connection, keeping the helper alive
		// regardless. The model is ~16 GB resident while warm, so this trades that
		// memory for responsiveness; 30 min covers typical step-away gaps.
		private let grace: TimeInterval = 1800
		private let queue = DispatchQueue(label: "co.overpolish.ai.helper.idle")

		init() {
			armIdleCheck()  // exit if no one connects within `grace`
		}

		func opened() {
			lock.lock()
			count += 1
			let c = count
			lock.unlock()
			helperLog.notice("helper: client connected (\(c, privacy: .public) active)")
		}

		func closed() {
			lock.lock()
			count -= 1
			let c = count
			lock.unlock()
			helperLog.notice("helper: client disconnected (\(c, privacy: .public) active)")
			if c <= 0 { armIdleCheck() }
		}

		private func armIdleCheck() {
			queue.asyncAfter(deadline: .now() + grace) { [self] in
				lock.lock()
				let c = count
				lock.unlock()
				if c <= 0 {
					helperLog.notice("helper: idle \(Int(self.grace), privacy: .public)s, exiting")
					exit(0)
				}
			}
		}
	}
}
