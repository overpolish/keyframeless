/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Darwin
import Foundation
import HuggingFace
import KeyframelessAI
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

	/// Strong refs for the on-demand wake listener (see `startWakeListener`).
	nonisolated(unsafe) private static var wakeListener: NSXPCListener?
	nonisolated(unsafe) private static var wakeDelegate: WakeDelegate?

	/// The `KKAIHelperWake` endpoint launchd routes a client's service lookup to.
	/// It does nothing but exist + reply: the lookup already woke us, and the real
	/// data path is the unix socket. Vending it satisfies the launchd MachService.
	private final class WakeDelegate: NSObject, NSXPCListenerDelegate, KKAIHelperWake {
		func listener(
			_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection
		) -> Bool {
			conn.exportedInterface = NSXPCInterface(with: KKAIHelperWake.self)
			conn.exportedObject = self
			conn.resume()
			return true
		}
		func ping(reply: @escaping () -> Void) { reply() }
	}

	private static func startWakeListener() {
		let delegate = WakeDelegate()
		let listener = NSXPCListener(machServiceName: LocalAIHelperSocket.machServiceName)
		listener.delegate = delegate
		listener.resume()
		wakeDelegate = delegate
		wakeListener = listener
		helperLog.notice(
			"helper: wake listener up on \(LocalAIHelperSocket.machServiceName, privacy: .public)")
	}

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

		// When launchd launched us on demand (no --socket arg), check in for the
		// app-group Mach service. That's the receive right a client's lookup used to
		// wake us; holding it keeps launchd's on-demand job satisfied and lets future
		// clients wake a fresh instance after idle-exit. A dev spawn passes --socket
		// and has no launchd job, so it skips this.
		if pathFromArg == nil { startWakeListener() }

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
					let dl = DownloadRegistry.shared.current
					_ = writeFrame(
						HelperResponse(
							result: nil, error: nil, activeJobs: JobRegistry.shared.count,
							downloadProgress: dl?.progress, downloadingModelID: dl?.id),
						to: h)
				case "cancel":
					let n = JobRegistry.shared.cancelAll()
					helperLog.notice("helper: cancel requested (\(n, privacy: .public) job(s))")
					_ = writeFrame(
						HelperResponse(
							result: nil, error: nil, activeJobs: JobRegistry.shared.count),
						to: h)
				case "download":
					handleDownload(req, to: h)
				case "cancel-download":
					let had = DownloadRegistry.shared.cancel()
					helperLog.notice(
						"helper: cancel-download (\(had ? "stopped" : "none", privacy: .public))")
					_ = writeFrame(HelperResponse(result: nil, error: nil), to: h)
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

	private final class Int64Box: @unchecked Sendable { var value: Int64 = 0 }
	private final class ErrBox: @unchecked Sendable { var value: Error? }

	/// Download a model's files into the SHARED cache via the HuggingFace Hub, and
	/// stream progress frames (0...1) back to the client, then a `done` frame. Moved
	/// here from the plugin so the plugins don't have to link swift-huggingface/NIO
	/// (~7-8 MB each). Progress is polled from real bytes on disk - the Hub counter
	/// only jumps when a whole shard finishes - so the bar moves smoothly.
	private static func handleDownload(_ req: HelperRequest, to h: FileHandle) {
		guard let model = LocalModelCatalog.model(id: req.modelID),
			let repo = Repo.ID(rawValue: model.repoID),
			let cacheBase = LocalAIHelperSocket.modelCacheBase(),
			let repoDir = LocalAIHelperSocket.repoCacheDir(model.repoID)
		else {
			_ = writeFrame(
				HelperResponse(result: nil, error: "helper: cannot download \(req.modelID)"), to: h)
			return
		}
		helperLog.notice("helper: download \(model.repoID, privacy: .public)")
		// Publish this download so a "status" query from ANY client (a plugin that
		// didn't start it) can mirror its live progress. Cleared on completion/error.
		DownloadRegistry.shared.begin(req.modelID)

		let blobsDir = repoDir.appendingPathComponent("blobs")
		let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
		let baselineTemps = tempDownloadNames(tmpDir)
		let sink = FrameSink(h)
		let totalBox = Int64Box()

		// Poll disk for smooth progress; stop + join before the terminal frame so the
		// poll thread and the final write never interleave on the single FileHandle.
		let pollActive = FlagBox()
		let pollDone = DispatchSemaphore(value: 0)
		let poller = Thread {
			while pollActive.value {
				let total = totalBox.value
				if total > 0 {
					let bytes =
						directorySize(blobsDir) + tempDownloadSize(tmpDir, excluding: baselineTemps)
					let frac = min(0.99, Double(bytes) / Double(total))
					DownloadRegistry.shared.update(frac)
					sink.send(
						HelperResponse(result: nil, error: nil, downloadProgress: frac))
				}
				Thread.sleep(forTimeInterval: 0.75)
			}
			pollDone.signal()
		}
		poller.stackSize = 512 << 10
		poller.start()

		let sem = DispatchSemaphore(value: 0)
		let errBox = ErrBox()
		let dlTask = Task(priority: .userInitiated) {
			defer { sem.signal() }
			do {
				let hub = HubClient(cache: HubCache(cacheDirectory: cacheBase))
				_ = try await hub.downloadSnapshot(of: repo) { progress in
					totalBox.value = progress.totalUnitCount
				}
			} catch {
				errBox.value = error
			}
		}
		DownloadRegistry.shared.attach(dlTask)
		sem.wait()
		pollActive.value = false
		pollDone.wait()
		let wasCancelled = DownloadRegistry.shared.finish()

		if wasCancelled || errBox.value is CancellationError {
			// User cancelled: drop the partial so half-finished bytes don't linger on
			// disk (there's no completion marker, so it already reads as not-downloaded;
			// this frees the space too). Reply with a `cancelled` frame - not an error.
			try? FileManager.default.removeItem(at: repoDir)
			helperLog.notice(
				"helper: download cancelled \(model.repoID, privacy: .public); partial removed")
			_ = writeFrame(HelperResponse(result: nil, error: nil, cancelled: true), to: h)
		} else if let err = errBox.value {
			helperLog.error(
				"helper: download failed \(model.repoID, privacy: .public): \(err.localizedDescription, privacy: .public)"
			)
			_ = writeFrame(HelperResponse(result: nil, error: err.localizedDescription), to: h)
		} else {
			// Stamp the repo complete so a plugin can distinguish a finished download
			// from a partial/cancelled one (which leaves some blobs but no marker).
			if let marker = LocalAIHelperSocket.repoCompleteMarker(model.repoID) {
				try? Data([1]).write(to: marker)
			}
			_ = writeFrame(
				HelperResponse(result: nil, error: nil, done: true, downloadProgress: 1.0), to: h)
		}
	}

	nonisolated private static func directorySize(_ dir: URL) -> Int64 {
		let fm = FileManager.default
		guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
			return 0
		}
		var total: Int64 = 0
		for case let url as URL in en {
			total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
		}
		return total
	}

	nonisolated private static func tempDownloadNames(_ tmpDir: URL) -> Set<String> {
		let fm = FileManager.default
		guard let items = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil)
		else { return [] }
		return Set(items.map { $0.lastPathComponent }.filter { $0.hasPrefix("CFNetworkDownload") })
	}

	nonisolated private static func tempDownloadSize(_ tmpDir: URL, excluding: Set<String>) -> Int64
	{
		let fm = FileManager.default
		guard
			let items = try? fm.contentsOfDirectory(
				at: tmpDir, includingPropertiesForKeys: [.fileSizeKey])
		else { return 0 }
		var total: Int64 = 0
		for url in items
		where url.lastPathComponent.hasPrefix("CFNetworkDownload")
			&& !excluding.contains(url.lastPathComponent)
		{
			total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
		}
		return total
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

	/// The single in-flight model download, so a "status" control request can report
	/// which model is downloading and how far (for clients that didn't start it). At
	/// most one download runs at a time (`LocalModelStore` gates on `downloadingModel`
	/// per process; the Hub client serialises within the helper).
	final class DownloadRegistry: @unchecked Sendable {
		static let shared = DownloadRegistry()
		private let lock = NSLock()
		private var _id: String?
		private var _progress: Double = 0
		private var _task: Task<Void, Never>?
		private var _cancelled = false

		func begin(_ id: String) {
			lock.lock()
			_id = id
			_progress = 0
			_task = nil
			_cancelled = false
			lock.unlock()
		}
		/// Store the cancellable fetch Task so a "cancel-download" control can stop it.
		func attach(_ t: Task<Void, Never>) {
			lock.lock()
			_task = t
			lock.unlock()
		}
		func update(_ p: Double) {
			lock.lock()
			_progress = p
			lock.unlock()
		}
		/// Cancel the in-flight download (if any); swift-huggingface honours Task
		/// cancellation and throws `CancellationError`. Returns whether one was running.
		@discardableResult func cancel() -> Bool {
			lock.lock()
			let t = _task
			let had = _id != nil
			if had { _cancelled = true }
			lock.unlock()
			t?.cancel()
			return had
		}
		/// Clear state at the end of a download; returns whether it was cancelled (so
		/// the caller drops the partial and sends a `cancelled` frame instead of `done`).
		@discardableResult func finish() -> Bool {
			lock.lock()
			let c = _cancelled
			_id = nil
			_progress = 0
			_task = nil
			_cancelled = false
			lock.unlock()
			return c
		}
		var current: (id: String, progress: Double)? {
			lock.lock()
			defer { lock.unlock() }
			guard let id = _id else { return nil }
			return (id, _progress)
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
