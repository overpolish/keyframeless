/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import AudioToolbox
import Foundation

/// Registers Final Cut Pro's bundled audio units (Compressor, Channel EQ,
/// Limiter, Match EQ, etc.) into our process so `AudioComponentFindNext`
/// and `AVAudioUnit.instantiate` can see them.
///
/// FCP ships its DSP suite as a private framework (`EDEL.framework`) rather
/// than discoverable `.component` bundles, and registers them via a C++
/// entry point inside that framework at launch. We do the same: locate FCP,
/// `dlopen` the framework, and call `CEDELPlugin::RegisterComponents()`.
/// Requires `com.apple.security.cs.disable-library-validation` because the
/// framework is signed by Apple's FCP team, not ours.
enum FCPAudioUnitLoader {

	private static let lock = NSLock()
	private static var attempted = false
	private static var didLoad = false

	/// Lazy, idempotent. Safe to call from any thread. Returns true if FCP's
	/// AUs are (now or already) available in this process.
	@discardableResult
	static func ensureLoaded() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		if attempted { return didLoad }
		attempted = true
		didLoad = load()
		return didLoad
	}

	private static func load() -> Bool {
		guard
			let fcpURL = NSWorkspace.shared.urlForApplication(
				withBundleIdentifier: "com.apple.FinalCut")
		else {
			print("[FCPAudioUnitLoader] Final Cut Pro not installed")
			return false
		}
		let frameworksDir = fcpURL.appendingPathComponent("Contents/Frameworks")
		let edel = frameworksDir.appendingPathComponent("EDEL.framework/EDEL")
		guard FileManager.default.fileExists(atPath: edel.path) else {
			print("[FCPAudioUnitLoader] EDEL.framework missing at \(edel.path)")
			return false
		}

		// dyld resolves @rpath dependencies (~10 MA*.framework dylibs) via
		// DYLD_FRAMEWORK_PATH for the upcoming dlopen.
		setenv("DYLD_FRAMEWORK_PATH", frameworksDir.path, 1)

		guard let handle = dlopen(edel.path, RTLD_NOW | RTLD_GLOBAL) else {
			let err = dlerror().map { String(cString: $0) } ?? "unknown"
			print("[FCPAudioUnitLoader] dlopen failed: \(err)")
			return false
		}
		guard let symbol = dlsym(handle, "_ZN11CEDELPlugin18RegisterComponentsEv") else {
			print("[FCPAudioUnitLoader] RegisterComponents symbol not found")
			return false
		}
		typealias RegisterFn = @convention(c) (OpaquePointer?) -> Void
		let fn = unsafeBitCast(symbol, to: RegisterFn.self)
		fn(nil)
		return true
	}
}
