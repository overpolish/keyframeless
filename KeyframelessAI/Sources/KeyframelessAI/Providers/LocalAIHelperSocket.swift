/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Darwin
import Foundation

/// POSIX Unix-domain-socket plumbing for the SHARED local-inference helper. The
/// helper is a singleton, installed once and launched on demand by launchd (a
/// client's `SharedHelperRunner` wakes it via the app-group Mach service). On start
/// it binds a socket in the app-group container, and every client (plugin or
/// extension, in any process) connects to that same socket. One model load serves
/// everyone.
///
/// The socket lives in the app-group container so all sandboxed clients can reach
/// it; that requires the `group.co.overpolish.keyframeless` app-group
/// entitlement on every client AND on the helper. Without the entitlement
/// `sharedSocketPath()` returns nil and local inference is unavailable (the caller
/// returns a nil runner).
public enum LocalAIHelperSocket {
	static let appGroupID = "group.co.overpolish.keyframeless"
	/// Short name to stay well under the 104-byte sun_path limit.
	static let socketName = "kkai.sock"

	/// App-group Mach service the installed helper vends (via an on-demand
	/// LaunchAgent). A sandboxed plugin can't exec the helper, but it CAN look up
	/// this name; the lookup makes launchd launch it. Must be prefixed by the app
	/// group id so the sandbox permits the lookup.
	public static let machServiceName = "group.co.overpolish.keyframeless.aihelper"

	/// Shared HuggingFace model cache ("hub") directory in the app-group
	/// container, so EVERY client downloads to - and every spawned helper loads
	/// from - one location. Without this, a helper spawned by a different client
	/// (different sandbox container) doesn't find the model and re-downloads it.
	/// Returns nil without the app-group entitlement. Matches the `HF_HUB_CACHE`
	/// layout (the dir that holds `models--org--name`).
	public static func sharedModelCacheDir() -> URL? {
		guard
			let container = FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: appGroupID)
		else { return nil }
		let dir = container.appendingPathComponent("huggingface", isDirectory: true)
			.appendingPathComponent("hub", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}

	/// Effective model-cache base: the app-group shared cache when the caller is
	/// entitled (installed helper + plugins), else `HF_HUB_CACHE` (a dev helper run
	/// outside the sandbox). Matches how `MLXLocalLLMRunner` resolves it, so the
	/// helper downloads into the same place the loader reads from.
	public static func modelCacheBase() -> URL? {
		if let dir = sharedModelCacheDir() { return dir }
		if let env = ProcessInfo.processInfo.environment["HF_HUB_CACHE"], !env.isEmpty {
			return URL(fileURLWithPath: env)
		}
		return nil
	}

	/// Marker file the helper writes into a repo's cache dir once its download FULLY
	/// completes. Its presence is how a client tells a finished download from a
	/// partial or cancelled one (which leaves some blobs but no marker) - a plain
	/// "snapshot has any file" check reports partials as done.
	public static let completeMarkerName = ".kkcomplete"

	/// The completion-marker URL for a repo, or nil without a cache base. Written by
	/// the helper on success, checked by the plugin's "is downloaded" test, and
	/// removed with the repo dir on uninstall.
	public static func repoCompleteMarker(_ repoID: String) -> URL? {
		repoCacheDir(repoID)?.appendingPathComponent(completeMarkerName)
	}

	/// The HuggingFace hub cache directory for a repo id inside the shared model
	/// cache, e.g. `<container>/huggingface/hub/models--org--name`. nil without a
	/// cache base. Used by the plugin (to check downloaded state / uninstall) and the
	/// helper (which does the actual download).
	public static func repoCacheDir(_ repoID: String) -> URL? {
		guard let base = modelCacheBase() else { return nil }
		let dirName = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
		return base.appendingPathComponent(dirName)
	}

	/// Absolute path of the shared socket, or nil if the app-group container
	/// isn't available (missing entitlement) or the path would exceed sun_path.
	public static func sharedSocketPath() -> String? {
		guard
			let container = FileManager.default.containerURL(
				forSecurityApplicationGroupIdentifier: appGroupID)
		else { return nil }
		let path = container.appendingPathComponent(socketName).path
		// sun_path is 104 bytes on Darwin; need room for the trailing NUL.
		guard path.utf8.count < 104 else { return nil }
		return path
	}

	/// Bind + listen as the singleton server. Returns the listening fd, or nil if
	/// another live server already owns the socket (lost the spawn race) or bind
	/// failed. A stale socket file (previous helper crashed) is detected by an
	/// unconnectable address and unlinked before rebinding.
	public static func serverBind(path: String) -> Int32? {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return nil }
		setNoSigpipe(fd)

		if !bindPath(fd, path) {
			if errno == EADDRINUSE {
				// Someone is bound. Live server, or a stale socket file?
				if let probe = clientConnect(path: path) {
					close(probe)
					close(fd)
					return nil  // live server already running
				}
				unlink(path)  // stale; reclaim it
				if !bindPath(fd, path) {
					close(fd)
					return nil
				}
			} else {
				close(fd)
				return nil
			}
		}
		guard listen(fd, 16) == 0 else {
			close(fd)
			return nil
		}
		return fd
	}

	/// Accept the next client connection, or nil on error.
	public static func acceptConn(_ serverFd: Int32) -> Int32? {
		let c = accept(serverFd, nil, nil)
		guard c >= 0 else { return nil }
		setNoSigpipe(c)
		return c
	}

	/// Connect to the singleton server, or nil if nobody is listening.
	public static func clientConnect(path: String) -> Int32? {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return nil }
		setNoSigpipe(fd)
		if connectPath(fd, path) { return fd }
		close(fd)
		return nil
	}

	private static func setNoSigpipe(_ fd: Int32) {
		var on: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
	}

	private static func bindPath(_ fd: Int32, _ path: String) -> Bool {
		withSockaddrUn(path) { ptr, len in bind(fd, ptr, len) == 0 } ?? false
	}

	private static func connectPath(_ fd: Int32, _ path: String) -> Bool {
		withSockaddrUn(path) { ptr, len in connect(fd, ptr, len) == 0 } ?? false
	}

	/// Build a `sockaddr_un` for `path` and run `body` with it. Returns nil if the
	/// path doesn't fit in sun_path.
	private static func withSockaddrUn<T>(
		_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
	) -> T? {
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		let bytes = Array(path.utf8)
		let cap = MemoryLayout.size(ofValue: addr.sun_path)
		guard bytes.count < cap else { return nil }
		withUnsafeMutablePointer(to: &addr.sun_path) { raw in
			raw.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
				for i in 0..<bytes.count { dst[i] = bytes[i] }
				dst[bytes.count] = 0
			}
		}
		let len = socklen_t(MemoryLayout<sockaddr_un>.size)
		return withUnsafePointer(to: &addr) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
		}
	}
}
